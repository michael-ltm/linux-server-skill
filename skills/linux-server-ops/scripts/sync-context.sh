#!/bin/bash
# sync-context.sh — Pull server state to local workspace context files
# Run LOCALLY (not on server). Requires SSH access.
#
# Supports:
#   - Key-based auth (recommended): uses private key file
#   - Password-based auth: uses sshpass (prompts at runtime, never stored)
#     Set SSH_PASSWORD env var for non-interactive use
#
# Usage:
#   bash sync-context.sh                    # sync default server
#   bash sync-context.sh prod-web           # sync specific server by ID
#   bash sync-context.sh --all              # sync all servers
#   bash sync-context.sh --add              # interactive: add a new server
#   bash sync-context.sh --list             # list all configured servers
#   bash sync-context.sh --show [id]        # show snapshot details
#   bash sync-context.sh --help             # help
#
# Context files (relative to workspace root):
#   .server/servers.json              ← SSH configs (NOT in git)
#   .server/snapshots/<id>.json       ← Server state snapshots

set -euo pipefail

SERVERS_FILE=".server/servers.json"
SNAPSHOTS_DIR=".server/snapshots"
SKILL_DIR="$HOME/.cursor/skills/linux-server-ops"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1" >&2; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }

# mask_ip: partially redact an IPv4 address for display (last two octets)
#   81.70.98.137 → 81.70.*.*
mask_ip() {
  printf '%s' "$1" | sed 's/\([0-9]*\.[0-9]*\)\.[0-9]*\.[0-9]*/\1.*.*/'
}

# mask_key: never reveal any part of the key path
mask_key() {
  printf '[key configured]'
}

# Runtime password (never stored in files)
_SSH_PASSWORD=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_jq() {
  if ! command -v jq &>/dev/null; then
    fail "jq is required."
    echo "  macOS:  brew install jq"
    echo "  Linux:  apt-get install -y jq  OR  dnf install -y jq"
    exit 1
  fi
}

# Check sshpass is installed (needed for password auth)
require_sshpass() {
  if ! command -v sshpass &>/dev/null; then
    echo ""
    warn "sshpass is not installed (required for password-based SSH auth)"
    echo ""
    echo "  Install:"
    echo "    macOS:   brew install hudochenkov/sshpass/sshpass"
    echo "    Ubuntu:  sudo apt-get install -y sshpass"
    echo "    CentOS:  sudo yum install -y sshpass"
    echo ""
    read -rp "Auto-install sshpass now? [Y/n]: " yn
    if [[ ! "$yn" =~ ^[Nn]$ ]]; then
      if command -v brew &>/dev/null; then
        brew install hudochenkov/sshpass/sshpass || { fail "brew install failed"; exit 1; }
      elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y sshpass || { fail "apt-get install failed"; exit 1; }
      elif command -v yum &>/dev/null; then
        sudo yum install -y sshpass || { fail "yum install failed"; exit 1; }
      else
        fail "Cannot auto-install — please install sshpass manually"
        exit 1
      fi
      ok "sshpass installed"
    else
      fail "sshpass is required for password auth. Aborting."
      exit 1
    fi
  fi
}

resolve_path() {
  echo "${1/#\~/$HOME}"
}

# ─── SSH abstraction (key or password) ────────────────────────────────────────
# Usage: _ssh <auth_type> <host> <port> <user> <key_or_empty> <command>
_ssh() {
  local auth_type="$1" host="$2" port="$3" user="$4" key="$5"
  shift 5
  local cmd="$*"

  local base_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=15"

  case "$auth_type" in
    key)
      key=$(resolve_path "$key")
      ssh -i "$key" -p "$port" $base_opts -o BatchMode=yes "$user@$host" "$cmd"
      ;;
    password)
      local pass="$_SSH_PASSWORD"
      if [ -z "$pass" ]; then
        # Try env var first
        pass="${SSH_PASSWORD:-}"
      fi
      if [ -z "$pass" ]; then
        echo -ne "${YELLOW}Password for $user@$host: ${NC}"
        read -rs pass
        echo ""
        _SSH_PASSWORD="$pass"   # cache for this session
      fi
      sshpass -p "$pass" ssh -p "$port" $base_opts \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$user@$host" "$cmd"
      ;;
    *)
      fail "Unknown auth_type: $auth_type (expected: key | password)"
      exit 1
      ;;
  esac
}

# Usage: _scp <auth_type> <port> <key_or_empty> <src> <dest>
_scp() {
  local auth_type="$1" port="$2" key="$3" src="$4" dest="$5"

  local base_opts="-o StrictHostKeyChecking=no"

  case "$auth_type" in
    key)
      key=$(resolve_path "$key")
      scp -i "$key" -P "$port" $base_opts "$src" "$dest"
      ;;
    password)
      local pass="${_SSH_PASSWORD:-${SSH_PASSWORD:-}}"
      if [ -z "$pass" ]; then
        echo -ne "${YELLOW}Password: ${NC}"
        read -rs pass
        echo ""
        _SSH_PASSWORD="$pass"
      fi
      sshpass -p "$pass" scp -P "$port" $base_opts \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$src" "$dest"
      ;;
  esac
}

# ─── Initialize servers.json ──────────────────────────────────────────────────
init_servers_file() {
  if [ ! -f "$SERVERS_FILE" ]; then
    mkdir -p .server
    cat > "$SERVERS_FILE" << 'EOF'
{
  "_note": "SSH configs for managed servers. DO NOT commit this file (contains credentials).",
  "default": "",
  "servers": {}
}
EOF
    ok "Created $SERVERS_FILE"
  fi

  mkdir -p "$SNAPSHOTS_DIR"

  # Suggest adding to .gitignore
  if [ -d ".git" ] && ! grep -q "\.server/servers\.json" .gitignore 2>/dev/null; then
    warn ".server/servers.json not in .gitignore"
    echo "  Run: echo '.server/servers.json' >> .gitignore"
    echo "       echo '.server/snapshots/' >> .gitignore"
  fi
}

# ─── CMD: --list ──────────────────────────────────────────────────────────────
cmd_list() {
  if [ ! -f "$SERVERS_FILE" ]; then
    warn "No servers configured. Run: bash sync-context.sh --add"
    return
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Configured Servers${NC}"
  echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"

  local default_id count
  default_id=$(jq -r '.default // ""' "$SERVERS_FILE")
  count=$(jq '.servers | length' "$SERVERS_FILE")

  if [ "$count" -eq 0 ]; then
    echo "  (no servers configured)"
  else
    jq -r '.servers | to_entries[] |
      [.key,
       .value.host,
       (.value.port|tostring),
       .value.user,
       (.value.auth_type // "key"),
       (.value.label // "")]
      | @tsv' "$SERVERS_FILE" | while IFS=$'\t' read -r id host port user auth label; do
      local auth_icon=""
      [ "$auth" = "password" ] && auth_icon="${YELLOW}[pwd]${NC}" || auth_icon="${GREEN}[key]${NC}"
      local default_mark=""
      [ "$id" = "$default_id" ] && default_mark=" ${GREEN}← default${NC}"
      # Display masked IP in terminal output
      echo -e "  ${BOLD}$id${NC}  $(mask_ip "$host"):$port  $user  $auth_icon  ${CYAN}$label${NC}$default_mark"

      if [ -f "$SNAPSHOTS_DIR/$id.json" ]; then
        local synced_at os
        synced_at=$(jq -r '._synced_at // "unknown"' "$SNAPSHOTS_DIR/$id.json" 2>/dev/null || echo "unknown")
        os=$(jq -r '.meta.os // ""' "$SNAPSHOTS_DIR/$id.json" 2>/dev/null || echo "")
        echo -e "    ${BLUE}snapshot: $synced_at  $os${NC}"
      fi
    done
  fi
  echo ""
}

# ─── CMD: --add (interactive) ─────────────────────────────────────────────────
cmd_add_interactive() {
  echo ""
  echo -e "${BOLD}Add a New Server${NC}"
  echo "─────────────────────────────────"

  read -rp "Server ID (e.g. prod-web, staging): " server_id
  [ -z "$server_id" ] && { fail "Server ID cannot be empty"; exit 1; }

  read -rp "Host (IP or hostname): " host
  [ -z "$host" ] && { fail "Host cannot be empty"; exit 1; }

  read -rp "SSH Port [22]: " port
  port="${port:-22}"

  read -rp "SSH User [root]: " user
  user="${user:-root}"

  # Auth type selection
  echo ""
  echo "  Auth type:"
  echo "  1) Private key file  (recommended)"
  echo "  2) Password          (uses sshpass)"
  echo ""
  read -rp "Choose [1/2, default 1]: " auth_choice
  auth_choice="${auth_choice:-1}"

  local auth_type key_path=""
  case "$auth_choice" in
    2|p|password|pwd)
      auth_type="password"
      require_sshpass
      echo ""
      warn "Password will be asked at runtime — never stored in servers.json"
      ;;
    *)
      auth_type="key"
      read -rp "Private Key Path [~/.ssh/id_ed25519]: " key_path
      key_path="${key_path:-~/.ssh/id_ed25519}"

      # Verify key file exists
      local resolved_key
      resolved_key=$(resolve_path "$key_path")
      if [ ! -f "$resolved_key" ]; then
        warn "Key file not found: $resolved_key"
        warn "Make sure the path is correct before syncing"
      else
        # Check permissions
        local key_perms
        key_perms=$(stat -f "%OLp" "$resolved_key" 2>/dev/null || stat -c "%a" "$resolved_key" 2>/dev/null || echo "???")
        if [ "$key_perms" != "600" ] && [ "$key_perms" != "400" ]; then
          warn "Key file permissions are $key_perms — SSH requires 600 or 400"
          read -rp "  Fix permissions now? [Y/n]: " fix_perm
          if [[ ! "$fix_perm" =~ ^[Nn]$ ]]; then
            chmod 600 "$resolved_key"
            ok "Permissions fixed: chmod 600 $resolved_key"
          fi
        fi
      fi
      ;;
  esac

  read -rp "Label (description, e.g. 'Production Web'): " label
  read -rp "Tags (comma-separated, e.g. production,web): " tags_raw
  local tags_json
  tags_json=$(echo "$tags_raw" | tr ',' '\n' | sed '/^$/d' | jq -R '.' | jq -s '.')

  # Save to servers.json
  _save_server "$server_id" "$host" "$port" "$user" "$auth_type" "$key_path" "$label" "$tags_json"

  echo ""
  read -rp "Sync server state now? [Y/n]: " sync_now
  if [[ ! "$sync_now" =~ ^[Nn]$ ]]; then
    cmd_sync "$server_id"
  fi
}

# ─── Save server to servers.json ──────────────────────────────────────────────
_save_server() {
  local server_id="$1" host="$2" port="$3" user="$4" auth_type="$5" key_path="$6"
  local label="${7:-}" tags="${8:-[]}"

  init_servers_file

  if jq -e ".servers[\"$server_id\"]" "$SERVERS_FILE" &>/dev/null 2>&1; then
    warn "Server '$server_id' already exists — updating"
  fi

  local tmp current_default
  tmp=$(mktemp)
  current_default=$(jq -r '.default // ""' "$SERVERS_FILE")

  # Build server object (key_path only stored for key auth)
  if [ "$auth_type" = "key" ]; then
    jq --arg id "$server_id" \
       --arg host "$host" \
       --argjson port "${port:-22}" \
       --arg user "$user" \
       --arg auth_type "$auth_type" \
       --arg key "$key_path" \
       --arg label "$label" \
       --argjson tags "$tags" \
       --arg snapshot ".server/snapshots/$server_id.json" \
       '.servers[$id] = {
         label: $label,
         host: $host,
         port: $port,
         user: $user,
         auth_type: $auth_type,
         key_path: $key,
         tags: $tags,
         snapshot: $snapshot,
         added_at: (now | todate)
       }' "$SERVERS_FILE" > "$tmp"
  else
    # Password auth — no key stored
    jq --arg id "$server_id" \
       --arg host "$host" \
       --argjson port "${port:-22}" \
       --arg user "$user" \
       --arg auth_type "$auth_type" \
       --arg label "$label" \
       --argjson tags "$tags" \
       --arg snapshot ".server/snapshots/$server_id.json" \
       '.servers[$id] = {
         label: $label,
         host: $host,
         port: $port,
         user: $user,
         auth_type: $auth_type,
         tags: $tags,
         snapshot: $snapshot,
         added_at: (now | todate)
       }' "$SERVERS_FILE" > "$tmp"
  fi

  # Set as default if first server
  if [ -z "$current_default" ]; then
    jq --arg id "$server_id" '.default = $id' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
  fi

  mv "$tmp" "$SERVERS_FILE"
  ok "Server '$server_id' saved  [auth: $auth_type]"

  if [ "$auth_type" = "key" ]; then
    echo -e "  ${BLUE}Key: $key_path${NC}"
  else
    echo -e "  ${YELLOW}Password will be prompted at sync time${NC}"
    echo -e "  ${YELLOW}Or set: export SSH_PASSWORD='your-password'${NC}"
  fi
}

# ─── CMD: sync ────────────────────────────────────────────────────────────────
cmd_sync() {
  local server_id="${1:-}"

  if [ -z "$server_id" ]; then
    server_id=$(jq -r '.default // ""' "$SERVERS_FILE" 2>/dev/null || echo "")
    if [ -z "$server_id" ]; then
      fail "No default server set and no server ID provided"
      cmd_list
      exit 1
    fi
    info "Using default server: $server_id"
  fi

  if ! jq -e ".servers[\"$server_id\"]" "$SERVERS_FILE" &>/dev/null; then
    fail "Server '$server_id' not found in $SERVERS_FILE"
    cmd_list
    exit 1
  fi

  local host port user auth_type key_path
  host=$(jq -r ".servers[\"$server_id\"].host" "$SERVERS_FILE")
  port=$(jq -r ".servers[\"$server_id\"].port" "$SERVERS_FILE")
  user=$(jq -r ".servers[\"$server_id\"].user" "$SERVERS_FILE")
  auth_type=$(jq -r ".servers[\"$server_id\"].auth_type // \"key\"" "$SERVERS_FILE")
  key_path=$(jq -r ".servers[\"$server_id\"].key_path // \"\"" "$SERVERS_FILE")

  # Pre-checks per auth type
  if [ "$auth_type" = "key" ]; then
    local resolved_key
    resolved_key=$(resolve_path "$key_path")
    if [ ! -f "$resolved_key" ]; then
      fail "Private key not found: $resolved_key"
      echo "  Update with: bash sync-context.sh --edit $server_id"
      exit 1
    fi
  else
    require_sshpass
    # Pre-prompt password if not set
    if [ -z "${_SSH_PASSWORD:-}" ] && [ -z "${SSH_PASSWORD:-}" ]; then
      echo -ne "${YELLOW}SSH Password for $user@$host: ${NC}"
      read -rs _SSH_PASSWORD
      echo ""
    fi
  fi

  echo ""
  local auth_label=""
  [ "$auth_type" = "key" ] && auth_label="key: $(mask_key "$key_path")" || auth_label="password auth"
  info "Syncing: $server_id ($user@$(mask_ip "$host"):$port) [$auth_label]"

  # ── Test connection ──────────────────────────────────────────────────────────
  info "Testing SSH connection..."
  if ! _ssh "$auth_type" "$host" "$port" "$user" "$key_path" 'echo ok' &>/dev/null; then
    fail "SSH connection failed"
    if [ "$auth_type" = "key" ]; then
      echo "  Check: host, port, user, key file path and permissions"
      echo "  Key:   $(mask_key "$key_path")  |  Host: $(mask_ip "$host"):$port"
    else
      echo "  Check: host, port, user, password"
      echo "  Host:  $(mask_ip "$host"):$port  |  User: $user"
      _SSH_PASSWORD=""  # clear cached password so user can re-enter
    fi
    exit 1
  fi
  ok "SSH connection successful"

  # ── Upload scripts if missing ────────────────────────────────────────────────
  info "Ensuring management scripts are on server..."

  local scripts_to_upload=()
  for script in generate-index.sh service-registry.sh service-control.sh; do
    local remote_check
    remote_check=$(_ssh "$auth_type" "$host" "$port" "$user" "$key_path" \
      "[ -f /opt/server-tools/$script ] && echo exists || echo missing" 2>/dev/null || echo "missing")
    if echo "$remote_check" | grep -q "missing"; then
      scripts_to_upload+=("$script")
    fi
  done

  if [ ${#scripts_to_upload[@]} -gt 0 ]; then
    info "Uploading: ${scripts_to_upload[*]}"
    for script in "${scripts_to_upload[@]}"; do
      local local_script="$SKILL_DIR/scripts/$script"
      # Fall back to workspace path
      [ -f "$local_script" ] || local_script="$(pwd)/scripts/$script"
      [ -f "$local_script" ] || { warn "Script not found locally: $script — skip"; continue; }

      _scp "$auth_type" "$port" "$key_path" "$local_script" "$user@$host:/tmp/$script"
      _ssh "$auth_type" "$host" "$port" "$user" "$key_path" \
        "sudo mkdir -p /opt/server-tools && sudo mv /tmp/$script /opt/server-tools/ && sudo chmod +x /opt/server-tools/$script"
      ok "Uploaded: $script"
    done
  else
    ok "All management scripts already present"
  fi

  # ── Run generate-index.sh ────────────────────────────────────────────────────
  info "Scanning server (this may take ~15 seconds)..."
  local snapshot
  snapshot=$(_ssh "$auth_type" "$host" "$port" "$user" "$key_path" \
    'sudo bash /opt/server-tools/generate-index.sh --print' 2>/dev/null || echo "")

  if [ -z "$snapshot" ] || ! echo "$snapshot" | jq . &>/dev/null; then
    fail "Failed to get valid JSON from server"
    [ -n "$snapshot" ] && echo "  Raw output: ${snapshot:0:300}"
    echo ""
    echo "  Possible causes:"
    echo "  - generate-index.sh needs sudo access"
    echo "  - jq not installed on server (run: check-system.sh)"
    echo "  - Network timeout"
    exit 1
  fi

  # ── Enrich snapshot with connection meta ─────────────────────────────────────
  local enriched_snapshot
  enriched_snapshot=$(echo "$snapshot" | jq \
    --arg server_id "$server_id" \
    --arg host "$host" \
    --argjson port "${port:-22}" \
    --arg user "$user" \
    --arg auth_type "$auth_type" \
    --arg key_path "$key_path" \
    --arg synced_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {
      _server_id: $server_id,
      _connection: {
        host: $host,
        port: $port,
        user: $user,
        auth_type: $auth_type,
        key_path: (if $key_path != "" then $key_path else null end)
      },
      _synced_at: $synced_at
    }')

  # ── Save snapshot ─────────────────────────────────────────────────────────────
  mkdir -p "$SNAPSHOTS_DIR"
  echo "$enriched_snapshot" > "$SNAPSHOTS_DIR/$server_id.json"
  ok "Snapshot saved: $SNAPSHOTS_DIR/$server_id.json"

  # Update last_synced in servers.json
  local tmp
  tmp=$(mktemp)
  jq --arg id "$server_id" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.servers[$id].last_synced = $ts' "$SERVERS_FILE" > "$tmp"
  mv "$tmp" "$SERVERS_FILE"

  # ── Print summary ─────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}${CYAN}Snapshot Summary: $server_id${NC}"
  echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
  echo "$enriched_snapshot" | jq -r '"  Host:        \(.meta.hostname) [\(._server_id)]"'
  echo "$enriched_snapshot" | jq -r '"  OS:          \(.meta.os)"'
  echo "$enriched_snapshot" | jq -r '"  Resources:   CPU \(.meta.resources.cpu_cores) cores | RAM \(.meta.resources.ram) | Disk \(.meta.resources.disk.used)/\(.meta.resources.disk.total) (\(.meta.resources.disk.pct))"'
  echo ""
  echo "$enriched_snapshot" | jq -r '"  Websites:    \(.websites | length)"'
  echo "$enriched_snapshot" | jq -r '"  Services:    \(.services | length)"'
  echo "$enriched_snapshot" | jq -r '"  Databases:   \(.databases | length) engines"'
  echo "$enriched_snapshot" | jq -r '"  SSL Certs:   \(.ssl_certs | length)"'
  echo "$enriched_snapshot" | jq -r '"  Docker:      \(if .docker.installed then (.docker.containers | length | tostring) + " running containers" else "not installed" end)"'
  echo "$enriched_snapshot" | jq -r '"  Open Ports:  \([.open_ports[]?.port | tostring] | join(", "))"'
  echo ""

  # SSL expiry warnings
  local expiring
  expiring=$(echo "$enriched_snapshot" | \
    jq -r '.ssl_certs[]? | select(.days_remaining < 30) | "  ⚠  \(.name): expires in \(.days_remaining) days"' \
    2>/dev/null || true)
  if [ -n "$expiring" ]; then
    echo -e "${YELLOW}SSL Expiry Warnings:${NC}"
    echo "$expiring"
    echo ""
  fi
}

# ─── CMD: --all ───────────────────────────────────────────────────────────────
cmd_sync_all() {
  if [ ! -f "$SERVERS_FILE" ]; then
    fail "No servers configured."
    exit 1
  fi

  local servers
  servers=$(jq -r '.servers | keys[]' "$SERVERS_FILE" 2>/dev/null || echo "")

  if [ -z "$servers" ]; then
    warn "No servers in $SERVERS_FILE"
    return
  fi

  local failed=0
  while IFS= read -r server_id; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cmd_sync "$server_id" || { fail "Failed to sync $server_id"; ((failed++)) || true; }
  done <<< "$servers"

  echo ""
  if [ "$failed" -eq 0 ]; then
    ok "All servers synced successfully"
  else
    warn "$failed server(s) failed to sync"
  fi
}

# ─── CMD: show snapshot ───────────────────────────────────────────────────────
cmd_show() {
  local server_id="${1:-$(jq -r '.default // ""' "$SERVERS_FILE" 2>/dev/null)}"
  local snapshot_file="$SNAPSHOTS_DIR/$server_id.json"

  if [ ! -f "$snapshot_file" ]; then
    fail "No snapshot for '$server_id'. Run: bash sync-context.sh $server_id"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Server Snapshot: $server_id${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"

  # Mask IP in display: show hostname + masked IP
  jq -r '"  \(.meta.hostname) (\(.meta.public_ip | split(".") | .[0:2] | join(".") + ".*.*"))  |  \(.meta.os)  |  up: \(.meta.uptime)"' "$snapshot_file"
  jq -r '"  Auth: \(._connection.auth_type)  |  User: \(._connection.user)  |  Synced: \(._synced_at)"' "$snapshot_file"
  echo ""

  echo -e "${BOLD}Websites ($(jq '.websites | length' "$snapshot_file")):${NC}"
  jq -r '.websites[] | "  \(.name)  →  \(.domain // "no-domain")  [\(if .ssl then "SSL✓" else "no-ssl" end)]  \(.root // "")"' \
    "$snapshot_file" 2>/dev/null || echo "  (none)"

  echo ""
  echo -e "${BOLD}Services ($(jq '.services | length' "$snapshot_file")):${NC}"
  jq -r '.services[] | "  \(.name)  [\(.type)]  \(.status // "?")  port:\(.port // "-")  \(.root // "")"' \
    "$snapshot_file" 2>/dev/null || echo "  (none)"

  echo ""
  echo -e "${BOLD}Databases ($(jq '.databases | length' "$snapshot_file")):${NC}"
  jq -r '.databases[] | "  \(.engine) \(.version)  [\(.status)]  port:\(.port)  [\(.databases // [] | join(", "))]"' \
    "$snapshot_file" 2>/dev/null || echo "  (none)"

  echo ""
  echo -e "${BOLD}Docker:${NC}"
  jq -r 'if .docker.installed then "  v\(.docker.version) [\(.docker.status)] — \(.docker.containers | length) containers, \(.docker.compose_projects | length) compose projects" else "  not installed" end' \
    "$snapshot_file"
  jq -r '.docker.containers[]? | "    • \(.name)  [\(.image)]  \(.status)"' "$snapshot_file" 2>/dev/null

  echo ""
  echo -e "${BOLD}SSL Certs:${NC}"
  jq -r '.ssl_certs[] | "  \(.name)  expires: \(.expires)  (\(.days_remaining) days)"' \
    "$snapshot_file" 2>/dev/null || echo "  (none)"

  echo ""
  echo -e "${BOLD}Open Ports:${NC}"
  jq -r '[.open_ports[]? | "\(.port)(\(.process // "?"))"] | join("  ")' "$snapshot_file" 2>/dev/null | sed 's/^/  /'

  echo ""
}

# ─── CMD: help ────────────────────────────────────────────────────────────────
cmd_help() {
  cat << 'HELP'

sync-context.sh — Local workspace server context manager

Supports both key-based and password-based SSH authentication.

Usage:
  bash sync-context.sh [server-id]         Sync specific server (or default)
  bash sync-context.sh --all               Sync all configured servers
  bash sync-context.sh --add               Interactive: add a new server
  bash sync-context.sh --list              List all configured servers
  bash sync-context.sh --show [server-id]  Show snapshot details
  bash sync-context.sh --help              This help

Authentication:
  Key-based (recommended):
    - Prompted for private key path during --add
    - Key path stored in servers.json

  Password-based:
    - Password is NEVER stored in servers.json
    - Prompted at sync time (or set SSH_PASSWORD env var)
    - Requires sshpass (auto-installed if missing)

  # Set password via env var for non-interactive/CI use:
  SSH_PASSWORD='mypassword' bash sync-context.sh prod-web

Context files (in workspace):
  .server/servers.json              SSH configs (ADD TO .gitignore)
  .server/snapshots/<id>.json       Server state snapshots

Quick start:
  1. bash sync-context.sh --add     # add your first server
  2. bash sync-context.sh           # sync server state
  3. bash sync-context.sh --show    # review snapshot

HELP
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  require_jq
  init_servers_file

  local cmd="${1:-sync}"
  shift || true

  case "$cmd" in
    --add)       cmd_add_interactive ;;
    --list)      cmd_list ;;
    --all)       cmd_sync_all ;;
    --show)      cmd_show "${1:-}" ;;
    --help|-h)   cmd_help ;;
    --*)
      fail "Unknown option: $cmd"
      cmd_help
      exit 1
      ;;
    *)
      cmd_sync "$cmd"
      ;;
  esac
}

main "$@"
