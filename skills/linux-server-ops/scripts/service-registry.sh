#!/bin/bash
# service-registry.sh — Server service registry manager
# Install on server at: /opt/server-tools/service-registry.sh
# Usage:
#   bash service-registry.sh list
#   bash service-registry.sh get <name>
#   bash service-registry.sh set <name> '<json-object>'
#   bash service-registry.sh remove <name>
#   bash service-registry.sh health
#   bash service-registry.sh summary
#   bash service-registry.sh update-field <name> <field> <value>

set -euo pipefail

REGISTRY="/etc/server-registry.json"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }

# ─── Ensure registry exists ──────────────────────────────────────────────────
init_registry() {
  if [ ! -f "$REGISTRY" ]; then
    cat > "$REGISTRY" << EOF
{
  "host": "$(hostname -f 2>/dev/null || hostname)",
  "server_ip": "$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')",
  "initialized": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {}
}
EOF
    chmod 600 "$REGISTRY"
    info "Registry initialized: $REGISTRY"
  fi
}

# ─── Require jq ──────────────────────────────────────────────────────────────
require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "jq is required. Install: apt-get install -y jq  OR  dnf install -y jq"
    exit 1
  fi
}

# ─── Update timestamp ────────────────────────────────────────────────────────
touch_registry() {
  local tmp
  tmp=$(mktemp)
  jq ".updated = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$REGISTRY" > "$tmp"
  mv "$tmp" "$REGISTRY"
  chmod 600 "$REGISTRY"
}

# ─── CMD: list ───────────────────────────────────────────────────────────────
cmd_list() {
  local count
  count=$(jq '.services | length' "$REGISTRY")
  echo ""
  echo -e "${BOLD}${CYAN}Server Registry — $(jq -r '.host' "$REGISTRY") ($(jq -r '.server_ip // "?"' "$REGISTRY"))${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
  printf "%-20s %-10s %-30s %-6s %s\n" "NAME" "TYPE" "DOMAIN" "PORT" "ROOT"
  echo "──────────────────────────────────────────────────────────────────────"

  if [ "$count" -eq 0 ]; then
    echo "  (no services registered)"
  else
    jq -r '.services | to_entries[] | [.key, .value.type//"?", .value.domain//"—", (.value.port|tostring)//"—", .value.root//"?"] | @tsv' \
      "$REGISTRY" | while IFS=$'\t' read -r name type domain port root; do
      printf "%-20s %-10s %-30s %-6s %s\n" "$name" "$type" "$domain" "$port" "$root"
    done
  fi
  echo ""
  echo -e "  Total: ${BOLD}$count${NC} service(s) | Last updated: $(jq -r '.updated' "$REGISTRY")"
  echo ""
}

# ─── CMD: get ────────────────────────────────────────────────────────────────
cmd_get() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: $0 get <service-name>"
    exit 1
  fi

  local entry
  entry=$(jq ".services[\"$name\"]" "$REGISTRY")

  if [ "$entry" = "null" ]; then
    fail "Service '$name' not found in registry"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Service: $name${NC}"
  echo -e "${CYAN}────────────────────────────────────────${NC}"
  echo "$entry" | jq '.'
  echo ""
}

# ─── CMD: set ────────────────────────────────────────────────────────────────
cmd_set() {
  local name="${1:-}"
  local json="${2:-}"

  if [ -z "$name" ] || [ -z "$json" ]; then
    echo "Usage: $0 set <name> '<json-object>'"
    echo "Example:"
    echo "  $0 set my-api '{\"type\":\"nodejs\",\"domain\":\"api.example.com\",\"root\":\"/var/www/my-api\",\"port\":3000}'"
    exit 1
  fi

  # Validate JSON
  if ! echo "$json" | jq . &>/dev/null; then
    fail "Invalid JSON provided"
    exit 1
  fi

  # Merge with defaults
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local existing
  existing=$(jq ".services[\"$name\"] // {}" "$REGISTRY")
  if [ "$existing" = "{}" ]; then
    # New service — add deployed_at
    json=$(echo "$json" | jq ". + {\"deployed_at\": \"$timestamp\"}")
    info "Adding new service: $name"
  else
    info "Updating existing service: $name"
  fi

  # Ensure log_dir is set
  json=$(echo "$json" | jq ". + {\"updated_at\": \"$timestamp\"}")
  if ! echo "$json" | jq -e '.log_dir' &>/dev/null; then
    json=$(echo "$json" | jq ". + {\"log_dir\": \"/var/log/apps/$name\"}")
  fi

  local tmp
  tmp=$(mktemp)
  jq ".services[\"$name\"] = ($existing * $json)" "$REGISTRY" > "$tmp"
  touch_registry
  mv "$tmp" "$REGISTRY"
  chmod 600 "$REGISTRY"

  ok "Registry updated for '$name'"
  echo ""
  jq ".services[\"$name\"]" "$REGISTRY"
  echo ""
}

# ─── CMD: update-field ───────────────────────────────────────────────────────
cmd_update_field() {
  local name="${1:-}" field="${2:-}" value="${3:-}"

  if [ -z "$name" ] || [ -z "$field" ] || [ -z "$value" ]; then
    echo "Usage: $0 update-field <name> <field> <value>"
    echo "Example: $0 update-field my-api ssl_expires 2025-04-15"
    exit 1
  fi

  if jq -e ".services[\"$name\"]" "$REGISTRY" &>/dev/null; then
    local tmp
    tmp=$(mktemp)
    # Try to parse as JSON first (for booleans/numbers), fallback to string
    if echo "$value" | jq . &>/dev/null 2>&1; then
      jq ".services[\"$name\"].$field = $value" "$REGISTRY" > "$tmp"
    else
      jq ".services[\"$name\"].$field = \"$value\"" "$REGISTRY" > "$tmp"
    fi
    touch_registry
    mv "$tmp" "$REGISTRY"
    chmod 600 "$REGISTRY"
    ok "Updated $name.$field = $value"
  else
    fail "Service '$name' not found"
    exit 1
  fi
}

# ─── CMD: remove ─────────────────────────────────────────────────────────────
cmd_remove() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: $0 remove <service-name>"
    exit 1
  fi

  if ! jq -e ".services[\"$name\"]" "$REGISTRY" &>/dev/null; then
    fail "Service '$name' not found in registry"
    exit 1
  fi

  read -rp "Remove '$name' from registry? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    local tmp
    tmp=$(mktemp)
    jq "del(.services[\"$name\"])" "$REGISTRY" > "$tmp"
    touch_registry
    mv "$tmp" "$REGISTRY"
    chmod 600 "$REGISTRY"
    ok "Removed '$name' from registry"
  else
    info "Cancelled"
  fi
}

# ─── CMD: health ─────────────────────────────────────────────────────────────
cmd_health() {
  echo ""
  echo -e "${BOLD}${CYAN}Service Health Check — $(hostname -f 2>/dev/null || hostname)${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"

  local count
  count=$(jq '.services | length' "$REGISTRY")

  if [ "$count" -eq 0 ]; then
    warn "No services in registry"
    return
  fi

  local all_ok=true

  jq -r '.services | to_entries[] | .key + " " + (.value | @json)' "$REGISTRY" | \
  while IFS=' ' read -r name json_val; do
    local type domain port process_manager ssl ssl_expires
    type=$(echo "$json_val" | jq -r '.type // "unknown"')
    domain=$(echo "$json_val" | jq -r '.domain // ""')
    port=$(echo "$json_val" | jq -r '.port // ""')
    process_manager=$(echo "$json_val" | jq -r '.process_manager // ""')
    ssl=$(echo "$json_val" | jq -r '.ssl // false')
    ssl_expires=$(echo "$json_val" | jq -r '.ssl_expires // ""')

    printf "%-20s [%-8s] " "$name" "$type"

    # Check process status
    local status="unknown"
    case "$process_manager" in
      pm2)
        if pm2 describe "$name" 2>/dev/null | grep -q "online"; then
          status="running"
        else
          status="down"
        fi
        ;;
      nginx)
        if systemctl is-active --quiet nginx 2>/dev/null; then
          status="running"
        else
          status="down"
        fi
        ;;
      *)
        if [ -n "$process_manager" ] && systemctl is-active --quiet "$name" 2>/dev/null; then
          status="running"
        elif [ -n "$port" ]; then
          # Check by port
          if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            status="running"
          else
            status="down"
          fi
        fi
        ;;
    esac

    if [ "$status" = "running" ]; then
      echo -ne "${GREEN}● running${NC} "
    elif [ "$status" = "down" ]; then
      echo -ne "${RED}● DOWN${NC}    "
      all_ok=false
    else
      echo -ne "${YELLOW}? unknown${NC}  "
    fi

    # HTTP check if domain set
    if [ -n "$domain" ]; then
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "https://$domain" 2>/dev/null || \
        curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://$domain" 2>/dev/null || echo "err")
      if [[ "$http_code" =~ ^[23] ]]; then
        echo -ne "${GREEN}HTTP:$http_code${NC} "
      else
        echo -ne "${RED}HTTP:$http_code${NC} "
      fi
    fi

    # SSL expiry check
    if [ "$ssl" = "true" ] && [ -n "$ssl_expires" ]; then
      local days_left
      days_left=$(( ($(date -d "$ssl_expires" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$ssl_expires" +%s 2>/dev/null || echo 0) - $(date +%s)) / 86400 ))
      if [ "$days_left" -gt 30 ]; then
        echo -ne "${GREEN}SSL:${days_left}d${NC}"
      elif [ "$days_left" -gt 0 ]; then
        echo -ne "${YELLOW}SSL:${days_left}d!${NC}"
      else
        echo -ne "${RED}SSL:EXPIRED${NC}"
      fi
    fi

    echo ""
  done

  echo ""

  # System summary
  echo -e "${BLUE}System Resources:${NC}"
  echo "  CPU:    $(top -bn1 | grep 'Cpu(s)' | awk '{print 100-$8"%"}' 2>/dev/null || echo "?")"
  echo "  Memory: $(free -h | awk '/^Mem:/{print $3"/"$2}')"
  echo "  Disk:   $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
  echo "  Nginx:  $(systemctl is-active nginx 2>/dev/null || echo "inactive")"
  echo ""
}

# ─── CMD: db ─────────────────────────────────────────────────────────────────
cmd_db() {
  local action="${1:-status}"
  echo ""
  echo -e "${BOLD}${CYAN}Database Status${NC}"
  echo -e "${CYAN}────────────────────────────────────────${NC}"

  # MySQL / MariaDB
  for svc in mysql mariadb; do
    if command -v $svc &>/dev/null || systemctl status $svc &>/dev/null 2>&1; then
      local status
      status=$(systemctl is-active $svc 2>/dev/null || echo "unknown")
      echo -ne "MySQL/MariaDB: "
      if [ "$status" = "active" ]; then
        echo -e "${GREEN}● $status${NC}"
        $svc -u root -e "SHOW DATABASES;" 2>/dev/null \
          | grep -vE "^Database|information_schema|performance_schema|sys|mysql$" \
          | awk '{print "  db: "$1}' || true
      else
        echo -e "${RED}● $status${NC}"
      fi
      break
    fi
  done

  # PostgreSQL
  if command -v psql &>/dev/null; then
    local pg_status
    pg_status=$(systemctl is-active postgresql 2>/dev/null || echo "unknown")
    echo -ne "PostgreSQL: "
    if [ "$pg_status" = "active" ]; then
      echo -e "${GREEN}● $pg_status${NC}"
      sudo -u postgres psql -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate=false;" 2>/dev/null \
        | awk '{print "  db: "$1}' || true
    else
      echo -e "${RED}● $pg_status${NC}"
    fi
  fi

  # Redis
  if command -v redis-cli &>/dev/null; then
    local redis_status
    redis_status=$(systemctl is-active redis 2>/dev/null \
      || systemctl is-active redis-server 2>/dev/null || echo "unknown")
    echo -ne "Redis: "
    if [ "$redis_status" = "active" ]; then
      local pong
      pong=$(redis-cli ping 2>/dev/null || echo "NO RESPONSE")
      echo -e "${GREEN}● $redis_status${NC} ($pong)"
      local redis_info
      redis_info=$(redis-cli info server 2>/dev/null | grep "redis_version" | cut -d: -f2 | tr -d '\r' || echo "?")
      echo "  version: $redis_info"
    else
      echo -e "${RED}● $redis_status${NC}"
    fi
  fi

  # MongoDB
  if command -v mongosh &>/dev/null || command -v mongo &>/dev/null; then
    local mongo_status
    mongo_status=$(systemctl is-active mongod 2>/dev/null || echo "unknown")
    echo -ne "MongoDB: "
    echo -e "$([ "$mongo_status" = "active" ] && echo "${GREEN}" || echo "${RED}")● $mongo_status${NC}"
  fi

  echo ""
}

# ─── CMD: docker ──────────────────────────────────────────────────────────────
cmd_docker() {
  if ! command -v docker &>/dev/null; then
    warn "Docker not installed"
    return
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Docker Status${NC}"
  echo -e "${CYAN}────────────────────────────────────────${NC}"

  local docker_status
  docker_status=$(systemctl is-active docker 2>/dev/null || echo "unknown")
  echo -e "Docker Engine: $([ "$docker_status" = "active" ] && echo "${GREEN}" || echo "${RED}")● $docker_status${NC} ($(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1))"
  echo ""

  echo -e "${BOLD}Running Containers:${NC}"
  docker ps --format "  {{.Names}}  [{{.Image}}]  {{.Status}}  {{.Ports}}" 2>/dev/null || echo "  (none)"
  echo ""

  # Docker Compose projects
  local compose_dirs=("/opt/docker-apps" "/srv" "/root" "/home")
  local found_any=false
  echo -e "${BOLD}Compose Projects:${NC}"
  for base in "${compose_dirs[@]}"; do
    [ -d "$base" ] || continue
    while IFS= read -r compose_file; do
      local proj_dir proj_name running_count
      proj_dir=$(dirname "$compose_file")
      proj_name=$(basename "$proj_dir")
      running_count=$(docker compose -f "$compose_file" ps -q 2>/dev/null | wc -l || echo 0)
      echo "  $proj_name ($proj_dir) — $running_count container(s) running"
      found_any=true
    done < <(find "$base" -maxdepth 3 -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null)
  done
  $found_any || echo "  (no compose projects found)"

  echo ""
  echo -e "${BOLD}Disk Usage:${NC}"
  docker system df 2>/dev/null | sed 's/^/  /' || true
  echo ""
}

# ─── CMD: cron ────────────────────────────────────────────────────────────────
cmd_cron() {
  echo ""
  echo -e "${BOLD}${CYAN}Scheduled Jobs${NC}"
  echo -e "${CYAN}────────────────────────────────────────${NC}"

  echo -e "${BOLD}System Cron (/etc/cron.d/):${NC}"
  for f in /etc/cron.d/*; do
    [ -f "$f" ] || continue
    echo "  [$f]"
    grep -v "^#\|^$\|^SHELL\|^PATH\|^MAILTO" "$f" 2>/dev/null | sed 's/^/    /' || true
  done

  echo ""
  echo -e "${BOLD}Root Crontab:${NC}"
  crontab -u root -l 2>/dev/null | grep -v "^#\|^$" | sed 's/^/  /' || echo "  (empty)"

  echo ""
  echo -e "${BOLD}Systemd Timers:${NC}"
  systemctl list-timers --no-pager 2>/dev/null | grep -v "^NEXT\|^$\|systemd-" | head -20 | sed 's/^/  /' || true
  echo ""
}

# ─── CMD: summary ────────────────────────────────────────────────────────────
cmd_summary() {
  echo ""
  echo -e "${BOLD}Server Summary: $(jq -r '.host' "$REGISTRY")${NC}"
  echo "IP:           $(jq -r '.server_ip // "unknown"' "$REGISTRY")"
  echo "Initialized:  $(jq -r '.initialized // "unknown"' "$REGISTRY")"
  echo "Registry:     $REGISTRY"
  echo ""

  echo "Services:"
  jq -r '.services | to_entries[] | "  • \(.key) [\(.value.type // "?")] → \(.value.domain // "no-domain") (\(.value.root // "?"))"' \
    "$REGISTRY" 2>/dev/null || echo "  (no services)"
  echo ""

  # Quick DB status
  cmd_db

  # SSL
  echo "SSL Certs (certbot):"
  certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:|Certificate Name:" \
    | sed 's/^/  /' || echo "  (certbot not installed)"

  # Docker quick
  if command -v docker &>/dev/null; then
    echo ""
    echo "Docker Containers:"
    docker ps --format "  • {{.Names}} [{{.Image}}] {{.Status}}" 2>/dev/null || echo "  (none running)"
  fi
  echo ""
}

# ─── CMD: backup ─────────────────────────────────────────────────────────────
cmd_backup() {
  local backup_path="/var/backups/server-registry-$(date +%Y%m%d_%H%M%S).json"
  cp "$REGISTRY" "$backup_path"
  chmod 600 "$backup_path"
  ok "Registry backed up to: $backup_path"
}

# ─── CMD: help ───────────────────────────────────────────────────────────────
cmd_help() {
  cat << 'HELP'

service-registry.sh — Manage server service registry

Usage:
  bash service-registry.sh <command> [args]

Commands:
  list                          List all registered services
  get <name>                    Show details for a service
  set <name> '<json>'           Add or update a service
  update-field <name> <f> <v>   Update a single field
  remove <name>                 Remove a service from registry
  health                        Check health of all services
  summary                       Full server summary (services + DB + Docker)
  db                            Database status (MySQL/PG/Redis/Mongo)
  docker                        Docker containers + compose projects
  cron                          Show all scheduled jobs
  backup                        Backup the registry file
  help                          Show this help

Service JSON fields:
  type            nodejs | static | java | python | php | docker
  domain          Primary domain name
  root            App root directory
  port            Internal port number (null for static)
  process_manager pm2 | systemd | nginx | docker
  nginx_conf      Path to Nginx config
  ssl             true | false
  ssl_cert        Path to SSL cert
  ssl_expires     YYYY-MM-DD
  git_repo        Git repository URL
  env_file        Path to .env file
  log_dir         Application log directory

Registry location: /etc/server-registry.json

HELP
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  require_jq
  init_registry

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    list)         cmd_list ;;
    get)          cmd_get "$@" ;;
    set)          cmd_set "$@" ;;
    update-field) cmd_update_field "$@" ;;
    remove|delete) cmd_remove "$@" ;;
    health)       cmd_health ;;
    summary)      cmd_summary ;;
    backup)       cmd_backup ;;
    db|database)  cmd_db ;;
    docker)       cmd_docker ;;
    cron)         cmd_cron ;;
    help|--help|-h) cmd_help ;;
    *)
      echo "Unknown command: $cmd"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
