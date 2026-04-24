# WAF Guide

Web Application Firewall: ModSecurity, Nginx rate limiting, IP management, bot protection, and custom security rules.

---

## WAF Architecture Overview

```
Internet → Cloudflare/CDN (optional L7 WAF)
              ↓
         Nginx (L7: ModSecurity, rate limiting, geo-blocking)
              ↓
         fail2ban (L4: auto-ban IPs after repeated attacks)
              ↓
         UFW/firewalld (L3/L4: port-level firewall)
              ↓
         App (Node/PHP/Python/Java)
```

---

## Layer 1: Nginx Rate Limiting

Add to `/etc/nginx/nginx.conf` in the `http {}` block:

```nginx
# ── Rate limit zones ──────────────────────────────────────────────
# General API rate limit: 30 req/min per IP
limit_req_zone $binary_remote_addr zone=api:10m rate=30r/m;
# Login/auth endpoints: 5 req/min per IP (brute force protection)
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
# General web: 200 req/min per IP
limit_req_zone $binary_remote_addr zone=web:20m rate=200r/m;
# Connection limit zone
limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;

# Hide Nginx version
server_tokens off;

# Buffer overflow protection
client_body_buffer_size    16k;
client_header_buffer_size  1k;
client_max_body_size       8m;
large_client_header_buffers 4 8k;
```

Apply in specific locations in your server block:

```nginx
server {
    listen 443 ssl;
    server_name example.com;

    # Global connection limit
    limit_conn conn_per_ip 50;

    # General web requests
    limit_req zone=web burst=50 nodelay;

    location /api/ {
        limit_req zone=api burst=10 nodelay;
        limit_req_status 429;
        proxy_pass http://backend;
    }

    location ~ ^/(login|signin|auth|wp-login\.php) {
        limit_req zone=login burst=3 nodelay;
        limit_req_status 429;
        proxy_pass http://backend;
    }

    # Return proper error page on rate limit
    error_page 429 /429.html;
    location = /429.html {
        root /var/www/errors;
        internal;
    }
}
```

Create a 429 error page:

```bash
mkdir -p /var/www/errors
cat > /var/www/errors/429.html << 'EOF'
<!DOCTYPE html>
<html><head><title>Too Many Requests</title></head>
<body><h1>429 - Too Many Requests</h1>
<p>Please slow down and try again later.</p></body></html>
EOF
```

---

## Layer 2: Nginx Security Headers (Global)

Create `/etc/nginx/conf.d/security.conf`:

```nginx
# ── Security headers ─────────────────────────────────────────────
add_header X-Frame-Options              "SAMEORIGIN" always;
add_header X-Content-Type-Options       "nosniff" always;
add_header X-XSS-Protection             "1; mode=block" always;
add_header Referrer-Policy              "strict-origin-when-cross-origin" always;
add_header Permissions-Policy           "geolocation=(), microphone=(), camera=(), payment=()" always;
# HSTS (only after SSL confirmed working — 1 year)
add_header Strict-Transport-Security    "max-age=31536000; includeSubDomains; preload" always;

# ── Content Security Policy (customize per app) ──────────────────
# Uncomment and adjust for your app:
# add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' https://fonts.gstatic.com; connect-src 'self' https://api.example.com; frame-ancestors 'none';" always;

# ── Block common attack vectors ──────────────────────────────────
# Block requests with no User-Agent (bots)
# NOTE: comment this out if you have legitimate API clients without UA
# if ($http_user_agent = "") { return 403; }

# Block common exploit scanners
map $http_user_agent $blocked_ua {
    default         0;
    ~*sqlmap        1;
    ~*nikto         1;
    ~*nmap          1;
    ~*masscan       1;
    ~*zgrab         1;
    ~*nuclei        1;
    ~*python-requests/2\.[0-2]  1;  # old python-requests often used in scripts
}
# Apply in server blocks: if ($blocked_ua) { return 403; }

# ── Geo blocking (requires nginx-extras or GeoIP2 module) ────────
# See geo-blocking section below
```

---

## Layer 3: ModSecurity (Full WAF)

ModSecurity with OWASP Core Rule Set provides protection against:
SQLi, XSS, RCE, path traversal, PHP injection, Java exploits, and more.

### Install ModSecurity + Nginx connector

```bash
# Ubuntu/Debian
apt-get install -y libmodsecurity3 libmodsecurity-dev libnginx-mod-http-modsecurity

# OR: compile nginx with modsecurity (for systems without package)
# See: https://github.com/SpiderLabs/ModSecurity-nginx
```

### Install OWASP Core Rule Set (CRS)

```bash
# Download CRS
mkdir -p /etc/nginx/modsec
cd /etc/nginx/modsec

# Download OWASP CRS
wget https://github.com/coreruleset/coreruleset/archive/refs/tags/v3.3.5.tar.gz -O crs.tar.gz
tar -xzf crs.tar.gz && mv coreruleset-3.3.5 crs && rm crs.tar.gz

# Download recommended ModSecurity config
wget https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended \
  -O /etc/nginx/modsec/modsecurity.conf

# Enable detection mode (change to On for enforcement)
sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf
# Set audit log
sed -i 's|SecAuditLog /var/log/modsec_audit.log|SecAuditLog /var/log/nginx/modsec_audit.log|' \
  /etc/nginx/modsec/modsecurity.conf
```

### Configure CRS

```bash
# Copy example setup
cp /etc/nginx/modsec/crs/crs-setup.conf.example /etc/nginx/modsec/crs/crs-setup.conf

# Main ModSec config file that Nginx will include
cat > /etc/nginx/modsec/main.conf << 'EOF'
Include /etc/nginx/modsec/modsecurity.conf
Include /etc/nginx/modsec/crs/crs-setup.conf
Include /etc/nginx/modsec/crs/rules/*.conf

# Custom exclusions (add rules that cause false positives here)
# SecRuleRemoveById 920350   # example: remove a specific rule
EOF
```

### Enable ModSecurity in Nginx

In each server block (or in `http {}` for global):

```nginx
# In /etc/nginx/nginx.conf http block, or per server block:
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/main.conf;
```

### Add custom local rules

```bash
cat > /etc/nginx/modsec/custom-rules.conf << 'EOF'
# Block specific bad IPs
SecRule REMOTE_ADDR "@ipMatch 1.2.3.4,5.6.7.8" \
  "id:1001,phase:1,deny,status:403,msg:'Blocked IP'"

# Block specific User-Agents
SecRule REQUEST_HEADERS:User-Agent "@rx (sqlmap|nikto|nmap|masscan)" \
  "id:1002,phase:1,deny,status:403,log,msg:'Blocked scanner UA'"

# Protect wp-login.php
SecRule REQUEST_URI "@beginsWith /wp-login.php" \
  "id:1003,phase:1,chain,deny,status:403"
  SecRule REMOTE_ADDR "!@ipMatch 203.0.113.10"   # allow only your IP

# Block path traversal attempts
SecRule REQUEST_URI "@rx (\.\./|\.\.\\)" \
  "id:1004,phase:1,deny,status:400,log,msg:'Path traversal attempt'"
EOF

# Add to main.conf
echo "Include /etc/nginx/modsec/custom-rules.conf" >> /etc/nginx/modsec/main.conf
```

### Check ModSecurity logs

```bash
tail -f /var/log/nginx/modsec_audit.log
# Find blocked requests
grep "BLOCKED\|Access denied" /var/log/nginx/modsec_audit.log | tail -20
# Most blocked rule IDs
grep -oP '(?<=\[id ")[0-9]+' /var/log/nginx/modsec_audit.log | sort | uniq -c | sort -rn | head -10
```

---

## Layer 4: IP Blacklist / Whitelist Management

### Manual IP blocking

```bash
# UFW — block single IP
ufw deny from 1.2.3.4 to any
# Block CIDR range
ufw deny from 1.2.3.0/24 to any
# Allow trusted IP (whitelist — put before deny rules)
ufw allow from 203.0.113.10 to any port 22
# List rules with numbers
ufw status numbered
# Delete rule by number
ufw delete <number>

# Batch block from file (one IP per line)
while read ip; do
  ufw deny from "$ip" &>/dev/null && echo "Blocked: $ip"
done < /opt/server-tools/blocklist.txt
```

### Nginx IP blacklist (faster, no kernel overhead)

```bash
# Create IP blocklist file
cat > /etc/nginx/blocklist.conf << 'EOF'
deny 1.2.3.4;
deny 5.6.7.8;
deny 10.0.0.0/8;   # example CIDR
allow all;
EOF

# Include in server blocks (or http block for global)
# include /etc/nginx/blocklist.conf;

# Append an IP to blocklist
echo "deny 9.10.11.12;" >> /etc/nginx/blocklist.conf
nginx -t && systemctl reload nginx
```

### Script: manage IP block/allow list

```bash
cat > /opt/server-tools/ip-manager.sh << 'SCRIPT'
#!/bin/bash
BLOCKLIST="/etc/nginx/blocklist.conf"
WHITELIST="/etc/nginx/whitelist.conf"
ACTION="$1"
IP="$2"

case "$ACTION" in
  block)
    if grep -q "$IP" "$BLOCKLIST" 2>/dev/null; then
      echo "Already blocked: $IP"
    else
      echo "deny $IP;" >> "$BLOCKLIST"
      nginx -t && systemctl reload nginx && echo "Blocked: $IP"
    fi
    ;;
  unblock)
    sed -i "/deny $IP;/d" "$BLOCKLIST"
    nginx -t && systemctl reload nginx && echo "Unblocked: $IP"
    ;;
  allow)
    echo "allow $IP;" >> "$WHITELIST"
    nginx -t && systemctl reload nginx && echo "Whitelisted: $IP"
    ;;
  list-blocked)
    echo "=== Blocked IPs (Nginx) ===" && cat "$BLOCKLIST" 2>/dev/null
    echo "=== Blocked IPs (UFW) ===" && ufw status | grep "DENY IN"
    echo "=== Banned IPs (fail2ban) ===" && fail2ban-client status 2>/dev/null | grep "Jail list" -A1
    ;;
  top-attackers)
    echo "Top IPs hitting 4xx/5xx:"
    awk '$9 ~ /^[45]/' /var/log/nginx/access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
    ;;
  *)
    echo "Usage: ip-manager.sh block|unblock|allow|list-blocked|top-attackers <IP>"
    ;;
esac
SCRIPT
chmod +x /opt/server-tools/ip-manager.sh
```

---

## Layer 5: fail2ban WAF Integration

Add Nginx jail configs to fail2ban:

```bash
cat >> /etc/fail2ban/jail.local << 'EOF'

# Ban IPs triggering Nginx 4xx too many times (scanner behavior)
[nginx-4xx]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/access.log
filter   = nginx-4xx
maxretry = 20
findtime = 60
bantime  = 3600

# Ban IPs triggering rate limit (429)
[nginx-ratelimit]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
filter   = nginx-ratelimit
maxretry = 10
findtime = 60
bantime  = 7200

# Ban ModSecurity blocked IPs
[nginx-modsec]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/modsec_audit.log
filter   = nginx-modsec
maxretry = 3
findtime = 300
bantime  = 86400   # 24 hours
EOF

# Create filter files
cat > /etc/fail2ban/filter.d/nginx-4xx.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH).*" (4\d\d) \d+
ignoreregex = .* (304|400) .*
EOF

cat > /etc/fail2ban/filter.d/nginx-ratelimit.conf << 'EOF'
[Definition]
failregex = limiting requests, excess:.* by zone .*, client: <HOST>
ignoreregex =
EOF

cat > /etc/fail2ban/filter.d/nginx-modsec.conf << 'EOF'
[Definition]
failregex = \[client <HOST>\] ModSecurity: Access denied
ignoreregex =
EOF

systemctl reload fail2ban
fail2ban-client status
```

---

## Layer 6: Geo-Blocking (Optional)

Block entire countries using MaxMind GeoIP2:

```bash
# Install GeoIP2 module
apt-get install -y libnginx-mod-http-geoip2 2>/dev/null \
  || dnf install -y nginx-mod-http-geoip2 2>/dev/null

# Download MaxMind GeoLite2 (requires free account)
# https://dev.maxmind.com/geoip/geolite2-free-geolocation-data
# Or use db-ip.com free CSV and convert

# Nginx config with geo blocking
cat > /etc/nginx/conf.d/geoip.conf << 'NGINX'
geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
    $geoip2_data_country_code country iso_code;
}

map $geoip2_data_country_code $blocked_country {
    default  0;
    # Block specific countries (add/remove as needed)
    # CN  1;   # China
    # RU  1;   # Russia
    # KP  1;   # North Korea
}
NGINX

# In server block:
# if ($blocked_country) { return 444; }   # 444 = no response (silent drop)
```

---

## Firewall Complete Management

### UFW Advanced Rules

```bash
# Status and full rule list
ufw status verbose
ufw status numbered

# Allow specific app to specific IP only
ufw allow from 203.0.113.10 to any port 3306 proto tcp   # MySQL from trusted IP only
ufw allow from 203.0.113.10 to any port 5432 proto tcp   # PostgreSQL

# Allow port range
ufw allow 8000:8099/tcp

# Deny outgoing to specific host (prevent data exfiltration)
ufw deny out to 1.2.3.4

# Rate limit (built-in: blocks IPs with >6 new connections/30s)
ufw limit ssh
ufw limit 443/tcp

# Logging
ufw logging on
ufw logging medium   # log: invalid, new, blocked
# Log location: /var/log/ufw.log

# Reset everything
ufw --force reset

# Export rules (backup)
cp /etc/ufw/user.rules /var/backups/ufw-rules-$(date +%Y%m%d).rules
```

### firewalld Advanced Rules (CentOS/RHEL)

```bash
# Rich rules for fine-grained control
# Block IP
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="1.2.3.4" reject'
# Rate limit SSH
firewall-cmd --permanent --add-rich-rule='rule service name="ssh" limit value="5/min" accept'
# Allow port from specific IP
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="203.0.113.10" port port="3306" protocol="tcp" accept'

# Zones (firewalld concept)
firewall-cmd --get-active-zones
firewall-cmd --zone=public --list-all

# Direct rules (iptables-style)
firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 -s 1.2.3.4 -j DROP

firewall-cmd --reload
```

### iptables Direct Management

```bash
# View current rules
iptables -L -n -v --line-numbers
iptables -t nat -L -n -v

# Block IP
iptables -I INPUT -s 1.2.3.4 -j DROP
iptables -I INPUT -s 1.2.3.0/24 -j DROP

# Allow only specific countries (with ipset)
ipset create allowed_countries hash:net
ipset add allowed_countries 203.0.113.0/24
iptables -I INPUT -m set --match-set allowed_countries src -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j DROP

# Save/restore
iptables-save > /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4

# Persist across reboots (Ubuntu/Debian)
apt-get install -y iptables-persistent
netfilter-persistent save
```

---

## Attack Detection & Response

### Real-time attack monitor script

```bash
cat > /opt/server-tools/attack-monitor.sh << 'SCRIPT'
#!/bin/bash
echo "=== Top Attacking IPs (last 1000 access log lines) ==="
tail -1000 /var/log/nginx/access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20

echo ""
echo "=== HTTP 4xx/5xx errors ==="
tail -500 /var/log/nginx/access.log | awk '$9 ~ /^[45]/ {print $9, $1, $7}' | sort | uniq -c | sort -rn | head -20

echo ""
echo "=== Fail2ban currently banned IPs ==="
fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g' | \
  while read jail; do
    jail=$(echo $jail | xargs)
    [ -z "$jail" ] && continue
    count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $4}')
    echo "  $jail: $count banned"
    fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list:/  IPs:/'
  done

echo ""
echo "=== Recent SSH failures ==="
grep "Failed password\|Invalid user" /var/log/auth.log 2>/dev/null | tail -10 \
  || journalctl -u sshd --since "1h ago" --no-pager | grep "Failed\|Invalid" | tail -10

echo ""
echo "=== Active connections by IP ==="
ss -tn state established | awk 'NR>1 {print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -10
SCRIPT
chmod +x /opt/server-tools/attack-monitor.sh
```

### Quick emergency block

```bash
# Block a currently attacking IP immediately
ATTACKER_IP="1.2.3.4"
ufw insert 1 deny from $ATTACKER_IP   # UFW (Ubuntu/Debian)
# OR
iptables -I INPUT -s $ATTACKER_IP -j DROP  # direct iptables
# AND block at Nginx level
echo "deny $ATTACKER_IP;" >> /etc/nginx/blocklist.conf
nginx -t && systemctl reload nginx
echo "Blocked $ATTACKER_IP at firewall + Nginx level"
```

### DDoS mitigation (basic)

```bash
# Limit new connections per IP with iptables
iptables -A INPUT -p tcp --syn --dport 80 -m connlimit --connlimit-above 50 -j REJECT
iptables -A INPUT -p tcp --syn --dport 443 -m connlimit --connlimit-above 50 -j REJECT

# SYN flood protection (in /etc/sysctl.d/99-security.conf)
cat >> /etc/sysctl.d/99-ddos.conf << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.core.somaxconn = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
EOF
sysctl --system
```

---

## WAF Checklist

Run after new server setup:

```bash
echo "=== WAF Status Check ===" && \
echo "Nginx: $(systemctl is-active nginx)" && \
echo "fail2ban: $(systemctl is-active fail2ban)" && \
echo "UFW: $(ufw status 2>/dev/null | head -1)" && \
echo "ModSecurity: $(nginx -T 2>/dev/null | grep modsecurity | head -1 || echo 'not configured')" && \
echo "Rate limit zones: $(nginx -T 2>/dev/null | grep -c limit_req_zone) defined" && \
echo "Banned IPs: $(fail2ban-client status 2>/dev/null | grep -oP 'Currently banned:\s+\K\d+' | paste -sd+ | bc 2>/dev/null || echo 0)" && \
echo "Nginx blocklist: $(wc -l < /etc/nginx/blocklist.conf 2>/dev/null || echo 0) entries"
```

- [ ] Rate limiting configured in Nginx
- [ ] Security headers in `/etc/nginx/conf.d/security.conf`
- [ ] ModSecurity installed + OWASP CRS loaded
- [ ] fail2ban jails: sshd, nginx-4xx, nginx-ratelimit, nginx-modsec
- [ ] IP blocklist file in place
- [ ] DDoS sysctl tuning applied
- [ ] `attack-monitor.sh` available at `/opt/server-tools/`
