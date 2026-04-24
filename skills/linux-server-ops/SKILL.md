---
name: linux-server-ops
description: Manage, deploy, and monitor Linux servers via SSH. Like a BaoTa/1Panel but AI-driven. Covers websites, Node.js/Java/Python/Go/PHP services, MySQL/PostgreSQL/Redis databases, Docker containers and Compose stacks, SSL certificates (auto-issue + auto-renew), domain binding, Nginx management, WAF (ModSecurity+OWASP), cron jobs, firewall, log management, file operations, user management, system monitoring, and backups. All services auto-start on boot. Maintains a server-side index and local workspace snapshots for instant session resumption. Use when the user asks to deploy a website or service, manage a Linux server, set up SSL, configure databases, manage Docker, check service status, restart a service, monitor resources, or resume work on a previously configured server.
---

# Linux Server Operations

---

## ⚠ SENSITIVE DATA — MANDATORY OUTPUT RULES

**These rules apply to EVERY response. No exceptions.**

### Never display these in chat output:
| Sensitive field | Where it appears | Instead, say… |
|---|---|---|
| Server IP / hostname | snapshot `meta.public_ip`, `_connection.host` | Use server ID only: `james` |
| SSH private key path | `_connection.key_path`, `servers.json` | `"configured key"` |
| SSH private key content | Any `-----BEGIN ... KEY-----` | Never display under any circumstance |
| SSH password | Runtime only, never stored | `"password auth configured"` |
| `.env` file values | Any `KEY=value` line | List key names only: `KEY=***` |
| Database passwords | `DB_PASS=`, `MYSQL_PASSWORD=`, etc. | `DB_PASS=***` |
| API keys / tokens / secrets | `*_KEY=`, `*_SECRET=`, `*_TOKEN=` | `API_KEY=***` |
| JWT / signing secrets | `JWT_SECRET=`, `SECRET_KEY=` | `JWT_SECRET=***` |

### When constructing SSH commands for explanations:
```
# ✗ Never write this in chat:
ssh -i /Users/ming/Downloads/aaa.pem root@81.70.98.137 '...'

# ✓ Write this instead (use placeholders, run the actual command silently via tool):
# [james] Running: ...
```

### When reading config or .env files:
```
# ✓ Show structure, mask values:
DB_HOST=db.example.com      # ← show (not secret)
DB_USER=myapp               # ← show (not secret)
DB_PASS=***                 # ← MASK
API_KEY=***                 # ← MASK
```

### Checklist before every response:
- [ ] No raw IP address shown (use server ID)
- [ ] No key file paths shown
- [ ] No password / secret / token values shown
- [ ] SSH command examples use `<key>` and `<host>` placeholders

---

## Session Start — Read Context First

**Before doing anything**, check if a local context file exists in the workspace:

```
.server/
├── servers.json          ← SSH configs for all managed servers
└── snapshots/
    └── <server-id>.json  ← Latest server state snapshot
```

```bash
# Check for context files (run locally)
ls .server/servers.json 2>/dev/null && echo "Context found" || echo "No context — need SSH details"
```

**If context exists** → Read `.server/servers.json` and the relevant `.server/snapshots/<id>.json`.
You now know: all servers, their IPs, SSH keys, every deployed service, database, Docker container, domain, and SSL status. Skip discovery questions.

**If no context** → Ask the user for SSH details and run bootstrap (Step 1).

**After any significant changes** → Remind user to sync: `bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh`

---

## What You Need From the User (First Time)

- `host`: server IP or hostname
- `port`: SSH port (default 22)
- `user`: SSH user (ubuntu, root, ec2-user, etc.)
- `key_path`: path to private key, e.g. `~/.ssh/my_server_key`
- `server_id`: short name for this server, e.g. `prod-web`
- `label` (optional): human description, e.g. "Production Web Server"

After collecting, create `.server/servers.json` in the workspace — see Local Context File section below.

---

## SSH Command Pattern

```bash
# All server commands use this pattern:
ssh -i <key_path> -p <port> <user>@<host> '<command>'

# Multi-line commands:
ssh -i <key_path> -p <port> <user>@<host> 'bash -s' << 'EOF'
# commands here
EOF

# Upload file:
scp -i <key_path> -P <port> <local_file> <user>@<host>:<remote_path>

# Upload directory:
rsync -avz -e "ssh -i <key_path> -p <port>" <local_dir>/ <user>@<host>:<remote_dir>/

# Download file to local:
scp -i <key_path> -P <port> <user>@<host>:<remote_file> <local_path>
```

---

## SSH Connection Failures — VPN / Proxy Interference

> **Core principle**: The server may only be reachable *through* the local proxy/VPN. SSH must go via the proxy when one is active — never blindly bypass it. Auto-detect the proxy state first, then build the SSH command accordingly.

### Why SSH fails even when proxy is running

| Scenario | What happens | Fix |
|---|---|---|
| Clash/V2Ray in **System Proxy** mode | Only HTTP/HTTPS are proxied. SSH (TCP port 22) is **not** automatically routed. | Add `ProxyCommand` using `nc -X 5 -x` to push SSH through SOCKS5 |
| Clash/V2Ray in **TUN** mode | All TCP is routed through VPN — SSH should work; failure usually means DNS or routing loop | Use IP directly; ensure TUN default route is healthy |
| Proxy process running but **not fully started** | Port not yet listening | Wait and retry |
| No proxy / VPN active | Direct connection is the only option | Connect directly |

### Auto-detect proxy state (run before every SSH attempt)

```bash
# ── Detect active SOCKS5 / HTTP proxy ────────────────────────────────────
# Returns: "socks5://127.0.0.1:<port>"  or  "http://127.0.0.1:<port>"  or  ""
detect_proxy() {
  # ── Priority 1: explicit env vars ────────────────────────────────────
  local p="${ALL_PROXY:-${all_proxy:-${SOCKS5_PROXY:-${socks5_proxy:-${HTTPS_PROXY:-${https_proxy:-}}}}}}"
  [ -n "$p" ] && echo "$p" && return

  # ── Priority 2: macOS system proxy (networksetup) ────────────────────
  # Try every active network interface
  local ifaces
  ifaces=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
  while IFS= read -r iface; do
    [ -z "$iface" ] && continue
    # SOCKS proxy
    local socks_info
    socks_info=$(networksetup -getsocksfirewallproxy "$iface" 2>/dev/null)
    if echo "$socks_info" | grep -q "^Enabled: Yes"; then
      local sh sp
      sh=$(echo "$socks_info" | awk '/^Server:/{print $2}')
      sp=$(echo "$socks_info" | awk '/^Port:/{print $2}')
      echo "socks5://${sh}:${sp}" && return
    fi
    # HTTP proxy (some tools set HTTP proxy instead of SOCKS)
    local http_info
    http_info=$(networksetup -getwebproxy "$iface" 2>/dev/null)
    if echo "$http_info" | grep -q "^Enabled: Yes"; then
      local hh hp
      hh=$(echo "$http_info" | awk '/^Server:/{print $2}')
      hp=$(echo "$http_info" | awk '/^Port:/{print $2}')
      echo "http://${hh}:${hp}" && return
    fi
  done <<< "$ifaces"

  # ── Priority 3: read port from running process configs ───────────────
  # Clash Verge — read mixed-port / socks-port from active profile
  local clash_port
  clash_port=$(
    # Try Clash Verge config locations
    for cfg in \
      "$HOME/.config/clash-verge/profiles"/*.yaml \
      "$HOME/.config/clash/config.yaml" \
      "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles"/*.yaml \
      "$HOME/Library/Preferences/com.metacubex.ClashX-Pro/config.yaml"; do
      [ -f "$cfg" ] || continue
      # mixed-port (handles both SOCKS5 and HTTP)
      grep -E '^mixed-port:' "$cfg" 2>/dev/null | awk '{print $2}' | head -1
    done | head -1
  )
  [ -n "$clash_port" ] && nc -z -w1 127.0.0.1 "$clash_port" 2>/dev/null \
    && echo "socks5://127.0.0.1:${clash_port}" && return

  # V2Ray / Xray — read inbound port from config.json
  local v2ray_port
  v2ray_port=$(
    for cfg in \
      "$HOME/.config/v2ray/config.json" \
      "$HOME/.config/xray/config.json" \
      "/usr/local/etc/v2ray/config.json" \
      "/usr/local/etc/xray/config.json"; do
      [ -f "$cfg" ] || continue
      # Look for socks inbound port
      python3 -c "
import json,sys
d=json.load(open('$cfg'))
for ib in d.get('inbounds',[]):
    if ib.get('protocol') in ('socks','http'):
        print(ib.get('port',''))
        break
" 2>/dev/null | head -1
    done | head -1
  )
  [ -n "$v2ray_port" ] && nc -z -w1 127.0.0.1 "$v2ray_port" 2>/dev/null \
    && echo "socks5://127.0.0.1:${v2ray_port}" && return

  # sing-box — read inbound listen port
  local singbox_port
  singbox_port=$(
    for cfg in \
      "$HOME/.config/sing-box/config.json" \
      "/usr/local/etc/sing-box/config.json"; do
      [ -f "$cfg" ] || continue
      python3 -c "
import json,sys
d=json.load(open('$cfg'))
for ib in d.get('inbounds',[]):
    if ib.get('type') in ('socks','mixed','http'):
        print(ib.get('listen_port',''))
        break
" 2>/dev/null | head -1
    done | head -1
  )
  [ -n "$singbox_port" ] && nc -z -w1 127.0.0.1 "$singbox_port" 2>/dev/null \
    && echo "socks5://127.0.0.1:${singbox_port}" && return

  # ── Priority 4: port scan — all known + common custom ports ─────────
  # Covers: Clash(7890,7891,7897), mixed-port variants, V2Ray(10808,10809),
  #         sing-box(1080,2080), Shadowsocks(1086,1087),
  #         Surge(6152,6153), Proxifier(8888), custom(8080,8118,9090,1089)
  for port in \
    7890 7891 7892 7893 7894 7895 7896 7897 7898 7899 \
    1080 1081 1082 1083 1084 1085 1086 1087 1088 1089 \
    10808 10809 10810 10811 \
    2080 2081 \
    6152 6153 \
    8080 8118 8888 9090 \
    20170 20171 20172; do
    nc -z -w1 127.0.0.1 "$port" 2>/dev/null \
      && echo "socks5://127.0.0.1:${port}" && return
  done

  echo ""  # no proxy detected
}

# ── Detect TUN mode (all-traffic VPN) ────────────────────────────────────
is_tun_active() {
  # utun0-2 are macOS built-ins; utun3+ or tun* usually signal VPN/TUN mode
  # Also check for common VPN tun interface names (wireguard, openvpn, etc.)
  ifconfig 2>/dev/null | grep -qE '^(utun[3-9]|utun[1-9][0-9]+|tun[0-9]|wg[0-9]|ipsec[0-9])'
}
```

### Build SSH command based on detected state

```bash
# ── Usage ─────────────────────────────────────────────────────────────────
# PROXY=$(detect_proxy)
# ssh $(ssh_proxy_args "$PROXY") -i <key> -p <port> <user>@<host> '<cmd>'

ssh_proxy_args() {
  local proxy="$1"   # e.g. socks5://127.0.0.1:7890  or empty

  if [ -n "$proxy" ]; then
    # Extract host:port from socks5://host:port or http://host:port
    local addr="${proxy#*://}"
    local ph="${addr%:*}"
    local pp="${addr##*:}"
    # nc -X 5 = SOCKS5, -x = proxy address
    echo "-o ProxyCommand='nc -X 5 -x ${ph}:${pp} %h %p' -o ConnectTimeout=15"
  elif is_tun_active; then
    # TUN routes everything — plain SSH, longer timeout for VPN latency
    echo "-o ConnectTimeout=20"
  else
    # No proxy, no TUN — direct connection
    echo "-o ConnectTimeout=10"
  fi
}
```

### Full retry wrapper — use this for EVERY SSH call

When any SSH command fails, **automatically run this sequence** before giving up:

```bash
ssh_auto() {
  # Args: same as ssh  (key, port, user@host, command are already expanded by caller)
  local ssh_base_args="$@"

  # ── Attempt 1: detect proxy & connect ────────────────────────────────
  local PROXY
  PROXY=$(detect_proxy)

  if [ -n "$PROXY" ]; then
    echo "[ssh-auto] Proxy detected: $PROXY — routing SSH through proxy"
    local addr="${PROXY#*://}"; local ph="${addr%:*}"; local pp="${addr##*:}"
    ssh -o "ProxyCommand=nc -X 5 -x ${ph}:${pp} %h %p" \
        -o ConnectTimeout=15 $ssh_base_args
  elif is_tun_active; then
    echo "[ssh-auto] TUN mode detected — connecting directly (all traffic via VPN)"
    ssh -o ConnectTimeout=20 $ssh_base_args
  else
    echo "[ssh-auto] No proxy/VPN — direct connection"
    ssh -o ConnectTimeout=10 $ssh_base_args
  fi

  local rc=$?

  # ── Attempt 2: if failed and proxy was detected, try TUN fallback ─────
  if [ $rc -ne 0 ] && [ -n "$PROXY" ] && is_tun_active; then
    echo "[ssh-auto] Proxy attempt failed; TUN is also active — retrying without ProxyCommand"
    ssh -o ProxyCommand=none -o ConnectTimeout=20 $ssh_base_args
    rc=$?
  fi

  # ── Attempt 3: if still failed and no proxy, re-run full detection ───
  # (proxy may have started after first detect_proxy call)
  if [ $rc -ne 0 ] && [ -z "$PROXY" ]; then
    echo "[ssh-auto] Direct failed; re-probing for any proxy..."
    PROXY=$(detect_proxy)
    if [ -n "$PROXY" ]; then
      local addr="${PROXY#*://}"; local ph="${addr%:*}"; local pp="${addr##*:}"
      echo "[ssh-auto] Found proxy $PROXY — retrying"
      ssh -o "ProxyCommand=nc -X 5 -x ${ph}:${pp} %h %p" \
          -o ConnectTimeout=15 $ssh_base_args
      rc=$?
    fi
  fi

  return $rc
}
```

### Decision tree

```
SSH connection attempt
│
├─ detect_proxy() returns non-empty?
│   └─ YES → SSH with ProxyCommand "nc -X 5 -x <proxy_host:port> %h %p"
│             (SOCKS5 proxies the TCP connection — SSH traffic goes through VPN)
│
├─ is_tun_active() = true?
│   └─ YES → Plain SSH (TUN already routes all TCP through VPN)
│             If it fails: DNS issue? → pass server IP, not hostname
│
└─ Neither proxy nor TUN
    └─ Plain direct SSH
       If it fails: check firewall, server down, wrong port
```

### Common proxy ports (auto-scanned by `detect_proxy`)

| Tool | SOCKS5 port(s) | HTTP port(s) | Notes |
|---|---|---|---|
| **Clash Verge** | 7890, 7891, 7897 | 7890 | `mixed-port` handles both; 7897 is common custom |
| **Clash Meta / ClashX Pro** | 7890, 7892 | 7890 | same `mixed-port` key in config |
| **V2Ray / Xray** | 10808 | 10809 | configurable in `inbounds[].port` |
| **sing-box** | 1080, 2080 | 1080 | `type: mixed` or `type: socks` |
| **Shadowsocks (macOS client)** | 1086 | 1087 | |
| **Surge** | 6153 | 6152 | |
| **Proxifier** | 8888 | — | SOCKS5 only |
| **Privoxy / tinyproxy** | — | 8118 | HTTP only |
| **OpenWrt / custom** | 1080–1089 | 8080 | varies |
| **WireGuard** | — | — | TUN mode, no local proxy port |
| **OpenVPN** | — | — | TUN mode (`tun0`), no local proxy port |

> **Custom port?** `detect_proxy` scans `7890–7899`, `1080–1089`, `10808–10811`, `2080–2081`, `6152–6153`, `8080`, `8118`, `8888`, `9090`, `20170–20172` — covers virtually all real-world setups. If your tool uses a completely non-standard port, set `ALL_PROXY=socks5://127.0.0.1:<port>` in your shell profile and `detect_proxy` will pick it up via Priority 1.

### Troubleshooting checklist

```bash
# ── What proxy tool is running? ──────────────────────────────────────────
pgrep -fl "clash\|v2ray\|xray\|sing-box\|shadowsocks\|surge\|proxifier"

# ── What port is it listening on? ───────────────────────────────────────
# Scan all common ports in one shot:
for p in 7890 7891 7892 7897 1080 1086 10808 2080 6152 6153 8080 8118 8888 9090; do
  nc -z -w1 127.0.0.1 $p 2>/dev/null && echo "LISTENING: $p"
done

# Or use lsof to see what the proxy process is actually listening on:
lsof -nP -iTCP -sTCP:LISTEN | grep -iE "clash|v2ray|xray|sing|shadow|surge"

# ── macOS system proxy settings ─────────────────────────────────────────
networksetup -getsocksfirewallproxy Wi-Fi
networksetup -getwebproxy Wi-Fi

# ── Env var proxy ────────────────────────────────────────────────────────
env | grep -iE 'proxy|socks'

# ── TUN interfaces ───────────────────────────────────────────────────────
ifconfig | grep -E '^utun|^tun|^wg'

# ── Test SSH manually with a specific proxy port ────────────────────────
ssh -o "ProxyCommand=nc -X 5 -x 127.0.0.1:7890 %h %p" \
    -o ConnectTimeout=10 -i <key> -p <port> <user>@<host> 'echo OK'
# Change 7890 to whatever port is LISTENING above

# ── If you know your custom port, export it so detect_proxy finds it ────
export ALL_PROXY=socks5://127.0.0.1:<your_custom_port>
```

---

## Step 1: Detect System

```bash
ssh -i <key> user@host 'bash -s' << 'EOF'
echo "=OS=" && cat /etc/os-release 2>/dev/null | grep -E "^ID=|^VERSION_ID="
echo "=ARCH=" && uname -m
echo "=INIT=" && ps -p 1 -o comm= 2>/dev/null
echo "=RAM=" && free -h | awk '/^Mem:/{print $2}'
echo "=DISK=" && df -h / | awk 'NR==2{print $2, $5}'
echo "=IP=" && curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
echo "=INSTALLED="
for t in nginx certbot mysql psql redis-cli docker node java python3 php pm2 git jq; do
  command -v $t &>/dev/null && echo "$t:$(command -v $t)" || echo "$t:missing"
done
EOF
```

Determine distro → see [distro-guide.md](distro-guide.md) for package manager mappings.

---

## Step 2: Bootstrap Server (First Time)

Upload and run the init script:

```bash
scp -i <key> ~/.cursor/skills/linux-server-ops/scripts/check-system.sh user@host:/tmp/
scp -i <key> ~/.cursor/skills/linux-server-ops/scripts/service-registry.sh user@host:/tmp/
scp -i <key> ~/.cursor/skills/linux-server-ops/scripts/generate-index.sh user@host:/tmp/
ssh -i <key> user@host 'bash /tmp/check-system.sh && \
  mkdir -p /opt/server-tools && \
  mv /tmp/service-registry.sh /tmp/generate-index.sh /opt/server-tools/ && \
  chmod +x /opt/server-tools/*.sh'
```

This installs: `nginx`, `certbot`, `fail2ban`, `ufw`/`firewalld`, `jq`, `htop`, `logrotate`, creates standard directories, and initializes the server index.

---

## Step 3: Server Index (Memory on Server)

The server maintains `/etc/server-index.json` — the single source of truth for everything on the server. Think of it as the server's own "panel database."

```jsonc
{
  "meta": {
    "hostname": "web-01",
    "public_ip": "1.2.3.4",
    "os": "Ubuntu 22.04",
    "updated": "2024-01-15T10:30:00Z"
  },
  "websites": [
    {
      "name": "my-blog",
      "domain": "blog.example.com",
      "type": "static",
      "root": "/var/www/my-blog",
      "nginx_conf": "/etc/nginx/sites-available/my-blog",
      "ssl": true,
      "ssl_cert": "/etc/letsencrypt/live/blog.example.com/fullchain.pem",
      "ssl_expires": "2024-04-15",
      "git_repo": "https://github.com/user/blog"
    }
  ],
  "services": [
    {
      "name": "my-api",
      "type": "nodejs",
      "domain": "api.example.com",
      "root": "/var/www/my-api",
      "port": 3000,
      "process_manager": "pm2",
      "env_file": "/var/www/my-api/.env",
      "log_dir": "/var/log/apps/my-api",
      "deployed_at": "2024-01-10T08:00:00Z"
    }
  ],
  "databases": [
    {
      "engine": "mysql",
      "version": "8.0",
      "socket": "/var/run/mysqld/mysqld.sock",
      "port": 3306,
      "databases": ["wp_myblog", "myapp_prod"],
      "data_dir": "/var/lib/mysql"
    },
    {
      "engine": "redis",
      "port": 6379,
      "config": "/etc/redis/redis.conf"
    }
  ],
  "docker": {
    "compose_projects": [
      {
        "name": "monitoring",
        "dir": "/opt/docker-apps/monitoring",
        "compose_file": "/opt/docker-apps/monitoring/docker-compose.yml",
        "services": ["grafana", "prometheus", "node-exporter"]
      }
    ]
  },
  "cron_jobs": [
    { "schedule": "0 3 * * *", "command": "bash /opt/server-tools/backup.sh", "user": "root" }
  ],
  "firewall": {
    "engine": "ufw",
    "open_ports": [22, 80, 443]
  }
}
```

**Manage the index:**

```bash
# Regenerate full index from live server state
ssh -i <key> user@host 'bash /opt/server-tools/generate-index.sh'

# List everything
ssh -i <key> user@host 'bash /opt/server-tools/service-registry.sh list'

# Health check all services
ssh -i <key> user@host 'bash /opt/server-tools/service-registry.sh health'

# Add/update a service entry
ssh -i <key> user@host 'bash /opt/server-tools/service-registry.sh set <name> "{...}"'
```

---

## Local Context File (Memory in Workspace)

Create `.server/servers.json` in the workspace root. This lets any new session instantly know about all servers without asking.

```json
{
  "_note": "SSH configs for managed servers. key_path supports ~ expansion.",
  "default": "prod-web",
  "servers": {
    "prod-web": {
      "label": "Production Web Server",
      "host": "1.2.3.4",
      "port": 22,
      "user": "ubuntu",
      "key_path": "~/.ssh/prod_key",
      "tags": ["production", "web"],
      "snapshot": ".server/snapshots/prod-web.json"
    },
    "staging": {
      "label": "Staging Server",
      "host": "1.2.3.5",
      "port": 22,
      "user": "ubuntu",
      "key_path": "~/.ssh/staging_key",
      "tags": ["staging"],
      "snapshot": ".server/snapshots/staging.json"
    }
  }
}
```

**IMPORTANT**: Add `.server/servers.json` to `.gitignore` (contains server IPs + key paths). The snapshots directory is safe to commit if you redact sensitive values.

```bash
echo ".server/servers.json" >> .gitignore
echo ".server/snapshots/" >> .gitignore   # optional
```

**Sync server state to local snapshot:**

```bash
# Pull full server state into .server/snapshots/<server-id>.json
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh prod-web
```

The sync script reads `.server/servers.json`, connects to the server, runs `generate-index.sh`, and saves output to `.server/snapshots/<server-id>.json`.

---

## Step 4: Deploy a Service

See [deploy-guide.md](deploy-guide.md) for complete per-type workflows.

### Service Type Quick Reference

| Type    | Process Manager | App Root                  | Default Port | Auto-Start |
|---------|----------------|--------------------------|-------------|------------|
| Static  | nginx           | /var/www/\<name\>          | 80/443      | `systemctl enable nginx` |
| Node.js | pm2             | /var/www/\<name\>          | as defined  | `pm2 startup` + `pm2 save` |
| Java    | systemd         | /opt/java-apps/\<name\>    | 8080        | `systemctl enable <name>` |
| Python  | systemd+gunicorn| /opt/python-apps/\<name\>  | 8000        | `systemctl enable <name>` |
| Go      | systemd         | /opt/go-apps/\<name\>      | 8080        | `systemctl enable <name>` |
| PHP     | php-fpm + nginx | /var/www/\<name\>          | 80/443      | `systemctl enable php<v>-fpm` |
| Docker  | docker compose  | /opt/docker-apps/\<name\>  | as mapped   | `restart: unless-stopped` |

### Standard Directories

```
/var/www/<name>/              ← Static, Node.js, PHP
/opt/java-apps/<name>/        ← Java JARs
/opt/python-apps/<name>/      ← Python venvs + apps
/opt/docker-apps/<name>/      ← Docker Compose projects
/etc/nginx/sites-available/   ← Nginx vhost configs
/etc/nginx/sites-enabled/     ← Active vhosts (symlinks)
/etc/systemd/system/          ← Systemd units
/var/log/apps/<name>/         ← App logs
/opt/server-tools/            ← Management scripts + index
/var/backups/                 ← Backups
```

---

## Step 5: Domain + SSL

```bash
# Issue cert (DNS must point to server IP first)
ssh -i <key> user@host "certbot --nginx \
  -d <domain> -d www.<domain> \
  --non-interactive --agree-tos \
  --email <admin-email> --redirect"

# Test auto-renewal
ssh -i <key> user@host 'certbot renew --dry-run'

# List all certs + expiry
ssh -i <key> user@host 'certbot certificates'

# Force renew
ssh -i <key> user@host 'certbot renew --cert-name <domain> --force-renewal'
```

---

## Step 6: Database Operations

See [deploy-guide.md](deploy-guide.md) → Database Setup section.

```bash
# MySQL: create DB + user
ssh -i <key> user@host "mysql -u root -p<pass> -e \"
  CREATE DATABASE IF NOT EXISTS <dbname> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '<dbuser>'@'localhost' IDENTIFIED BY '<password>';
  GRANT ALL PRIVILEGES ON <dbname>.* TO '<dbuser>'@'localhost'; FLUSH PRIVILEGES;\""

# PostgreSQL: create DB + user
ssh -i <key> user@host "sudo -u postgres psql -c \"
  CREATE USER <dbuser> WITH ENCRYPTED PASSWORD '<password>';
  CREATE DATABASE <dbname> OWNER <dbuser>;\""

# Redis: check status
ssh -i <key> user@host 'redis-cli ping'

# List MySQL databases
ssh -i <key> user@host 'mysql -u root -p<pass> -e "SHOW DATABASES;"'
```

---

## Step 7: Docker Management

See [deploy-guide.md](deploy-guide.md) → Docker section for full workflows.

```bash
# List running containers
ssh -i <key> user@host 'docker ps'

# Compose project status
ssh -i <key> user@host "cd /opt/docker-apps/<name> && docker compose ps"

# Pull + restart (update)
ssh -i <key> user@host "cd /opt/docker-apps/<name> && docker compose pull && docker compose up -d"

# View logs
ssh -i <key> user@host "docker compose -f /opt/docker-apps/<name>/docker-compose.yml logs -f --tail=100"

# Cleanup
ssh -i <key> user@host 'docker system prune -f'
```

---

## Step 7.5: Service Control (Status / Start / Stop / Restart)

Use `service-control.sh` — it auto-detects the service type (PM2 / systemd / Docker Compose / Nginx) and runs the right command.

```bash
# ── Status ──────────────────────────────────────────────────────────────────
# All services at a glance (status + boot auto-start flag)
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh status'

# One specific service
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh status <name>'

# ── Start / Stop / Restart / Reload ─────────────────────────────────────────
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh start   <name>'
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh stop    <name>'
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh restart <name>'
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh reload  <name>'  # zero-downtime

# ── Auto-Start on Boot ───────────────────────────────────────────────────────
# Check all services have boot auto-start configured
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh boot-check'
# Fix all: enable auto-start for every detected service
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh boot-fix'
# Enable one service
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh enable <name>'

# ── Logs ────────────────────────────────────────────────────────────────────
ssh -i <key> user@host 'bash /opt/server-tools/service-control.sh logs <name> 200'
```

**How reload vs restart works per type:**

| Type | `reload` | `restart` |
|------|---------|----------|
| PM2 (Node.js) | Graceful cluster reload — 0 downtime | Hard restart, brief gap |
| systemd (Java/Python/Go) | SIGHUP (if app supports it), else falls back to restart | Full process restart |
| Nginx | Config reload — 0 downtime | Full restart |
| Docker Compose | Falls back to restart | Recreate containers |

**Install `service-control.sh` on server (first time):**

```bash
scp -i <key> ~/.cursor/skills/linux-server-ops/scripts/service-control.sh user@host:/tmp/
ssh -i <key> user@host 'sudo mv /tmp/service-control.sh /opt/server-tools/ && sudo chmod +x /opt/server-tools/service-control.sh'
```

---

## Step 8: Monitor & Maintain

See [monitoring-guide.md](monitoring-guide.md) for full setup.

```bash
# Quick health snapshot
ssh -i <key> user@host 'bash /opt/server-tools/service-registry.sh health'

# System resources
ssh -i <key> user@host 'uptime && free -h && df -h /'

# All running services
ssh -i <key> user@host 'pm2 status 2>/dev/null; systemctl list-units --type=service --state=running --no-pager | tail -20'

# Recent errors
ssh -i <key> user@host 'journalctl -p err --since "1h ago" --no-pager -n 30'
```

---

## Common Operations

| Task | Command Pattern |
|------|----------------|
| Locate a service | Read snapshot or: `ssh ... 'jq .services /etc/server-index.json'` |
| Restart Node app | `ssh ... 'pm2 reload <name>'` |
| Restart systemd app | `ssh ... 'systemctl restart <name>'` |
| Update deployed app | `ssh ... 'cd <root> && git pull && <restart>'` |
| Check Nginx config | `ssh ... 'nginx -t'` |
| Renew all SSL | `ssh ... 'certbot renew'` |
| View app logs | `ssh ... 'tail -f /var/log/apps/<name>/app.log'` |
| Backup now | `ssh ... 'bash /opt/server-tools/backup.sh'` |
| Sync local context | `bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh <server-id>` |

---

## WAF & Firewall

See [waf-guide.md](waf-guide.md) for full details.

```bash
# Quick WAF status check
ssh -i <key> user@host 'bash -s' << 'EOF'
echo "Nginx: $(systemctl is-active nginx)"
echo "fail2ban: $(systemctl is-active fail2ban)"
echo "UFW: $(ufw status 2>/dev/null | head -1)"
echo "ModSecurity: $(nginx -T 2>/dev/null | grep -c modsecurity) directives"
echo "Banned IPs: $(fail2ban-client status 2>/dev/null | grep -c "Currently banned" || echo 0)"
echo "Top attackers (last 500 reqs):"
tail -500 /var/log/nginx/access.log 2>/dev/null | awk '$9~/^[45]/{print $1}' | sort | uniq -c | sort -rn | head -5
EOF

# Block attacker IP immediately
ssh -i <key> user@host "bash /opt/server-tools/ip-manager.sh block <IP>"

# Show attack summary
ssh -i <key> user@host 'bash /opt/server-tools/attack-monitor.sh'
```

Key WAF layers: Nginx rate limiting → Security headers → ModSecurity + OWASP CRS → fail2ban jails → UFW/firewalld → iptables

---

## Log Management

See [log-guide.md](log-guide.md) for full details.

```bash
# Real-time error stream (all services)
ssh -i <key> user@host 'bash /opt/server-tools/error-summary.sh'

# Tail specific service log
ssh -i <key> user@host 'bash /opt/server-tools/show-logs.sh <name> 100 ERROR'

# Nginx top IPs / status codes
ssh -i <key> user@host "awk '{print \$1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10"
ssh -i <key> user@host "awk '{print \$9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn"

# Check disk used by logs
ssh -i <key> user@host 'du -sh /var/log/nginx/ /var/log/apps/ && journalctl --disk-usage'
```

---

## File Operations

See [file-ops-guide.md](file-ops-guide.md) for full details.

```bash
# Browse directory
ssh -i <key> user@host 'ls -lah /var/www/<name>/'
ssh -i <key> user@host 'du -sh /var/www/* | sort -h'

# Upload files
rsync -avz --progress -e "ssh -i <key> -p <port>" ./dist/ user@host:/var/www/<name>/

# Download files
rsync -avz -e "ssh -i <key> -p <port>" user@host:/var/log/apps/<name>/ ./local-logs/

# Edit file on server
ssh -i <key> user@host 'nano /var/www/<name>/.env'

# Fix permissions (web standard)
ssh -i <key> user@host "find /var/www/<name> -type d -exec chmod 755 {} \; && find /var/www/<name> -type f -exec chmod 644 {} \; && chmod 600 /var/www/<name>/.env"

# Search in files
ssh -i <key> user@host 'grep -r "ERROR" /var/log/apps/<name>/ | tail -20'
```

---

## User Management

See [user-management-guide.md](user-management-guide.md) for full details.

```bash
# List all non-system users
ssh -i <key> user@host "awk -F: '\$3 >= 1000 && \$3 < 65534 {print \$1, \$3, \$6}' /etc/passwd"

# Create deploy user with SSH key
ssh -i <key> user@host 'bash -s' << 'EOF'
useradd -m -s /bin/bash deploy
mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
echo "<public-key>" > /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
EOF

# Add SSH key for existing user
ssh -i <key> user@host "echo '<new-public-key>' >> /home/<username>/.ssh/authorized_keys"

# Create SFTP-only user for a website
ssh -i <key> user@host 'bash -s' << 'EOF'
# See user-management-guide.md → SFTP Accounts section
EOF

# Check who is logged in
ssh -i <key> user@host 'w && last | head -10'
```

---

## Scheduled Tasks (Cron)

```bash
# View all cron jobs on server
ssh -i <key> user@host 'bash /opt/server-tools/service-registry.sh cron'

# Add a cron job
ssh -i <key> user@host "echo '0 3 * * * root bash /opt/server-tools/backup.sh >> /var/log/backup.log 2>&1' > /etc/cron.d/daily-backup"

# Add to user crontab
ssh -i <key> user@host 'crontab -e'
# Non-interactive:
ssh -i <key> user@host '(crontab -l 2>/dev/null; echo "*/5 * * * * bash /opt/server-tools/watchdog.sh") | crontab -'

# Remove a cron job
ssh -i <key> user@host 'rm /etc/cron.d/<job-name>'

# Test a cron script manually
ssh -i <key> user@host 'bash /opt/server-tools/backup.sh && cat /var/log/backup.log | tail -20'

# Systemd timer (modern alternative to cron)
ssh -i <key> user@host 'systemctl list-timers --no-pager'
```

---

## Network & Bandwidth

```bash
# Open ports + which process
ssh -i <key> user@host 'ss -tlnp'

# Active connections count
ssh -i <key> user@host 'ss -s && ss -tn state established | wc -l'

# Bandwidth usage (if vnstat installed)
ssh -i <key> user@host 'vnstat 2>/dev/null || apt-get install -y vnstat && vnstat'

# Live bandwidth (nload)
ssh -i <key> user@host 'nload -u M 2>/dev/null || (apt-get install -y nload && nload -u M)'

# Network interfaces + IPs
ssh -i <key> user@host 'ip addr show && ip route show'

# DNS resolution test
ssh -i <key> user@host 'dig +short <domain> && curl -I --max-time 5 https://<domain>'
```

---

## Security Checklist

See [security-guide.md](security-guide.md) and [waf-guide.md](waf-guide.md) for full details.

- [ ] SSH: key-only auth, no root login, `sshd -t && systemctl reload sshd`
- [ ] Firewall: only 22/80/443 open — `ufw status` or `firewall-cmd --list-all`
- [ ] fail2ban: sshd + nginx jails enabled
- [ ] ModSecurity + OWASP CRS installed and active
- [ ] Nginx rate limiting configured
- [ ] Security headers in `/etc/nginx/conf.d/security.conf`
- [ ] `.env` files: `chmod 600`, never in git
- [ ] `/etc/server-index.json`: `chmod 600 && chown root:root`
- [ ] Regular updates: `unattended-upgrades` or `dnf-automatic` enabled
- [ ] SFTP chroot configured for web-only users
- [ ] `attack-monitor.sh` and `ip-manager.sh` deployed to `/opt/server-tools/`

---

## Additional Resources

| Guide | Contents |
|-------|---------|
| [distro-guide.md](distro-guide.md) | Per-distro package commands, Nginx paths, PHP-FPM sockets |
| [deploy-guide.md](deploy-guide.md) | Static, Node.js, Java, Python, PHP, Docker, Database deployments |
| [waf-guide.md](waf-guide.md) | ModSecurity, OWASP CRS, rate limiting, IP blocking, DDoS mitigation |
| [monitoring-guide.md](monitoring-guide.md) | Metrics, alerting, Netdata, uptime monitoring, watchdog |
| [log-guide.md](log-guide.md) | Log viewing, searching, rotation, GoAccess, Loki/Promtail |
| [file-ops-guide.md](file-ops-guide.md) | File browse, edit, permissions, compress, transfer, search |
| [security-guide.md](security-guide.md) | SSH hardening, auditd, intrusion detection, kernel tuning, backups |
| [user-management-guide.md](user-management-guide.md) | Users, sudo, SSH keys, SFTP chroot, session auditing |
| [scripts/check-system.sh](scripts/check-system.sh) | Bootstrap a new server from scratch |
| [scripts/generate-index.sh](scripts/generate-index.sh) | Full server scan → `/etc/server-index.json` |
| [scripts/service-registry.sh](scripts/service-registry.sh) | Manage server index + health/db/docker/cron commands |
| [scripts/service-control.sh](scripts/service-control.sh) | Unified start/stop/restart/reload/enable/boot-check for all service types |
| [scripts/sync-context.sh](scripts/sync-context.sh) | Sync server state to local `.server/snapshots/` |
