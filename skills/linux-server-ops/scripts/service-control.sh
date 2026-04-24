#!/bin/bash
# service-control.sh — Unified service management for all service types
# Install on server at: /opt/server-tools/service-control.sh
#
# Detects service type automatically (PM2 / systemd / docker-compose / nginx)
# and runs the appropriate command.
#
# Usage:
#   bash service-control.sh status [name]          Show status (all or specific)
#   bash service-control.sh start <name>           Start a service
#   bash service-control.sh stop <name>            Stop a service
#   bash service-control.sh restart <name>         Hard restart
#   bash service-control.sh reload <name>          Graceful reload (0 downtime)
#   bash service-control.sh enable <name>          Enable auto-start on boot
#   bash service-control.sh disable <name>         Disable auto-start on boot
#   bash service-control.sh logs <name> [lines]    View logs
#   bash service-control.sh boot-check             Verify all auto-starts
#   bash service-control.sh boot-fix               Enable auto-start for all known services
#   bash service-control.sh help                   Show this help

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
GRAY='\033[0;90m'

ok()    { echo -e "${GREEN}●${NC} $1"; }
fail()  { echo -e "${RED}●${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
info()  { echo -e "${BLUE}→${NC} $1"; }
label() { echo -e "${GRAY}$1${NC}"; }

REGISTRY="/etc/server-index.json"
LEGACY_REGISTRY="/etc/server-registry.json"

# ─── Detect service type ──────────────────────────────────────────────────────
# Returns: pm2 | systemd | docker-compose | nginx | unknown
detect_type() {
  local name="$1"

  # Check PM2
  if command -v pm2 &>/dev/null; then
    if pm2 describe "$name" &>/dev/null 2>&1; then
      echo "pm2"; return
    fi
  fi

  # Check systemd
  if command -v systemctl &>/dev/null; then
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${name}\.service"; then
      echo "systemd"; return
    fi
    if systemctl status "${name}.service" &>/dev/null 2>&1; then
      echo "systemd"; return
    fi
  fi

  # Check Docker Compose project
  for base in /opt/docker-apps /srv /home /root; do
    [ -d "$base/$name" ] || continue
    if [ -f "$base/$name/docker-compose.yml" ] || [ -f "$base/$name/compose.yml" ]; then
      echo "docker-compose"; return
    fi
  done

  # Special names
  case "$name" in
    nginx) echo "nginx"; return ;;
    mysql|mariadb) echo "systemd"; return ;;
    postgresql|postgres) echo "systemd"; return ;;
    redis|redis-server) echo "systemd"; return ;;
    docker) echo "systemd"; return ;;
    php*-fpm|php-fpm) echo "systemd"; return ;;
  esac

  # Check registry for type hint
  if [ -f "$REGISTRY" ]; then
    local reg_type
    reg_type=$(jq -r ".services[] | select(.name == \"$name\") | .process_manager" "$REGISTRY" 2>/dev/null || echo "")
    [ -n "$reg_type" ] && [ "$reg_type" != "null" ] && echo "$reg_type" && return
  fi

  echo "unknown"
}

# ─── Get service status string ────────────────────────────────────────────────
get_status() {
  local name="$1" type="$2"
  case "$type" in
    pm2)
      pm2 describe "$name" 2>/dev/null | grep -m1 "status" | awk '{print $4}' || echo "unknown"
      ;;
    systemd)
      systemctl is-active "${name}.service" 2>/dev/null || echo "inactive"
      ;;
    docker-compose)
      local compose_file
      for base in /opt/docker-apps /srv /home /root; do
        [ -f "$base/$name/docker-compose.yml" ] && compose_file="$base/$name/docker-compose.yml" && break
        [ -f "$base/$name/compose.yml" ] && compose_file="$base/$name/compose.yml" && break
      done
      if [ -n "${compose_file:-}" ]; then
        docker compose -f "$compose_file" ps --quiet 2>/dev/null | wc -l | \
          xargs -I{} sh -c '[ {} -gt 0 ] && echo "running ({} containers)" || echo "stopped"'
      else
        echo "unknown"
      fi
      ;;
    nginx)
      systemctl is-active nginx 2>/dev/null || echo "inactive"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# ─── Get enabled-on-boot status ───────────────────────────────────────────────
get_enabled() {
  local name="$1" type="$2"
  case "$type" in
    pm2)
      # Check if pm2 systemd unit exists and is enabled
      local pm2_unit
      pm2_unit=$(systemctl list-unit-files 2>/dev/null | grep "pm2-" | awk '{print $1}' | head -1)
      if [ -n "$pm2_unit" ]; then
        systemctl is-enabled "$pm2_unit" 2>/dev/null || echo "disabled"
      else
        echo "not-configured"
      fi
      ;;
    systemd|nginx)
      local svc_name="$name"
      [[ "$name" == "nginx" ]] && svc_name="nginx"
      systemctl is-enabled "${svc_name}.service" 2>/dev/null || echo "disabled"
      ;;
    docker-compose)
      # Check restart policy of first container in the project
      local container
      container=$(docker compose -f "/opt/docker-apps/$name/docker-compose.yml" ps -q 2>/dev/null | head -1 || echo "")
      if [ -n "$container" ]; then
        docker inspect "$container" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown"
      else
        echo "unknown"
      fi
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# ─── CMD: status ─────────────────────────────────────────────────────────────
cmd_status() {
  local target="${1:-all}"

  if [ "$target" != "all" ]; then
    # Single service
    local type
    type=$(detect_type "$target")
    local status
    status=$(get_status "$target" "$type")
    local enabled
    enabled=$(get_enabled "$target" "$type")

    echo ""
    echo -e "${BOLD}Service: $target${NC}"
    echo -e "Type:    $type"
    echo -ne "Status:  "
    case "$status" in
      active|online|running*) echo -e "${GREEN}● $status${NC}" ;;
      inactive|stopped|errored) echo -e "${RED}● $status${NC}" ;;
      *) echo -e "${YELLOW}● $status${NC}" ;;
    esac
    echo -ne "Boot:    "
    case "$enabled" in
      enabled|always|unless-stopped) echo -e "${GREEN}✓ $enabled (auto-start on boot)${NC}" ;;
      disabled) echo -e "${RED}✗ disabled (will NOT start on reboot)${NC}" ;;
      not-configured) echo -e "${YELLOW}! PM2 startup not configured${NC}" ;;
      *) echo -e "${YELLOW}? $enabled${NC}" ;;
    esac

    echo ""
    # Extra details per type
    case "$type" in
      pm2)
        pm2 describe "$target" 2>/dev/null | grep -E "name|status|pid|uptime|restarts|memory|cpu" | head -10
        ;;
      systemd)
        systemctl status "$target" --no-pager -l --lines 5 2>/dev/null | tail -10
        ;;
      nginx)
        nginx -t 2>&1 | head -3
        systemctl status nginx --no-pager --lines 3 2>/dev/null
        ;;
    esac
    return
  fi

  # All services overview
  echo ""
  echo -e "${BOLD}${CYAN}Service Status Overview${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
  printf "  %-22s %-12s %-10s %s\n" "SERVICE" "TYPE" "STATUS" "BOOT"
  echo -e "  ${GRAY}──────────────────────────────────────────────────────────────${NC}"

  local any_found=false

  # ── Nginx ──
  if command -v nginx &>/dev/null; then
    local s e
    s=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
    e=$(systemctl is-enabled nginx 2>/dev/null || echo "disabled")
    _print_row "nginx" "nginx" "$s" "$e"
    any_found=true
  fi

  # ── PM2 processes ──
  if command -v pm2 &>/dev/null; then
    local pm2_list
    pm2_list=$(pm2 jlist 2>/dev/null || echo "[]")
    local pm2_unit
    pm2_unit=$(systemctl list-unit-files 2>/dev/null | grep "^pm2-" | awk '{print $1}' | head -1)
    local pm2_boot
    pm2_boot=$([ -n "$pm2_unit" ] && systemctl is-enabled "$pm2_unit" 2>/dev/null || echo "not-configured")

    echo "$pm2_list" | jq -c '.[]' 2>/dev/null | while read -r proc; do
      local pname pstatus
      pname=$(echo "$proc" | jq -r '.name')
      pstatus=$(echo "$proc" | jq -r '.pm2_env.status')
      _print_row "$pname" "pm2" "$pstatus" "$pm2_boot"
      any_found=true
    done
  fi

  # ── Systemd custom services ──
  if command -v systemctl &>/dev/null; then
    while IFS= read -r line; do
      local svc_unit svc_name svc_status svc_enabled
      svc_unit=$(echo "$line" | awk '{print $1}')
      svc_name="${svc_unit%.service}"
      # Skip known system/infrastructure services
      [[ "$svc_name" =~ ^(nginx|mysql|mariadb|postgresql|redis|docker|fail2ban|certbot|ssh|cron|pm2|ufw|firewalld|apt|dpkg|systemd|dbus|network|accounts|bluetooth|cups|gdm|getty|grub|ifup|init|kernel|logrotate|logind|ModemManager|NetworkManager|plymouth|proc|remote|rtkit|selinux|smartd|thermald|wpa|unattended|php) ]] && continue
      svc_status=$(systemctl is-active "$svc_unit" 2>/dev/null || echo "inactive")
      svc_enabled=$(systemctl is-enabled "$svc_unit" 2>/dev/null || echo "disabled")
      _print_row "$svc_name" "systemd" "$svc_status" "$svc_enabled"
      any_found=true
    done < <(systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null \
      | grep "^[a-zA-Z]" | grep -v "^system\|@\." \
      | awk '$2 ~ /^(enabled|disabled)$/ && $1 !~ /@/' \
      | grep -v "^nginx\|^mysql\|^mariadb\|^postgresql\|^redis\|^docker\|^fail2ban\|^ssh\|^cron\|^ufw\|^firewalld\|^apt\|^dpkg\|^systemd\|^dbus\|^network\|^accounts\|^bluetooth\|^cups\|^gdm\|^getty\|^grub\|^kernel\|^logrotate\|^logind\|^ModemManager\|^NetworkManager\|^plymouth\|^remote\|^rtkit\|^selinux\|^smartd\|^thermald\|^wpa\|^unattended\|^php\|^certbot" \
      | awk '{if ($1 !~ /^(proc|init|ifup|swap|mount|tmp|run|dev|boot|home|var|usr|lib|etc|opt|snap|lvm|mdadm|iscsid|multipathd)/) print $0}' \
      | head -30)
  fi

  # ── Docker Compose projects ──
  for base in /opt/docker-apps /srv; do
    [ -d "$base" ] || continue
    for compose_file in "$base"/*/docker-compose.yml "$base"/*/compose.yml; do
      [ -f "$compose_file" ] || continue
      local proj_dir proj_name running
      proj_dir=$(dirname "$compose_file")
      proj_name=$(basename "$proj_dir")
      running=$(docker compose -f "$compose_file" ps -q 2>/dev/null | wc -l || echo 0)
      local c_status="stopped"
      [ "$running" -gt 0 ] && c_status="running ($running)"
      # Get restart policy
      local restart_policy
      restart_policy=$(docker compose -f "$compose_file" ps -q 2>/dev/null | head -1 | \
        xargs -I{} docker inspect {} --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown")
      _print_row "$proj_name" "compose" "$c_status" "${restart_policy:-unknown}"
      any_found=true
    done
  done

  $any_found || echo -e "  ${GRAY}(no services detected)${NC}"

  echo ""
  echo -e "  ${GRAY}Tip: bash service-control.sh status <name>  for details${NC}"
  echo -e "  ${GRAY}     bash service-control.sh boot-check      to verify auto-starts${NC}"
  echo ""
}

_print_row() {
  local name="$1" type="$2" status="$3" boot="$4"
  local status_color boot_color boot_icon

  case "$status" in
    active|online|running*) status_color="${GREEN}" ;;
    inactive|stopped|errored) status_color="${RED}" ;;
    *) status_color="${YELLOW}" ;;
  esac

  case "$boot" in
    enabled|always|unless-stopped)
      boot_color="${GREEN}"; boot_icon="✓" ;;
    disabled|not-configured)
      boot_color="${RED}"; boot_icon="✗" ;;
    *)
      boot_color="${YELLOW}"; boot_icon="?" ;;
  esac

  printf "  %-22s %-12s ${status_color}%-10s${NC} ${boot_color}%s %s${NC}\n" \
    "$name" "$type" "$status" "$boot_icon" "$boot"
}

# ─── CMD: start ──────────────────────────────────────────────────────────────
cmd_start() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Usage: $0 start <name>"; exit 1; }
  local type
  type=$(detect_type "$name")
  info "Starting $name [$type]..."
  case "$type" in
    pm2)         pm2 start "$name" && ok "Started: $name" ;;
    systemd)     systemctl start "$name" && ok "Started: $name" ;;
    nginx)       systemctl start nginx && ok "Started: nginx" ;;
    docker-compose)
      local dir; dir=$(_compose_dir "$name")
      docker compose -f "$dir/docker-compose.yml" up -d && ok "Started: $name"
      ;;
    *)           fail "Unknown service type for '$name'" ;;
  esac
}

# ─── CMD: stop ───────────────────────────────────────────────────────────────
cmd_stop() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Usage: $0 stop <name>"; exit 1; }
  local type
  type=$(detect_type "$name")
  info "Stopping $name [$type]..."
  case "$type" in
    pm2)         pm2 stop "$name" && ok "Stopped: $name" ;;
    systemd)     systemctl stop "$name" && ok "Stopped: $name" ;;
    nginx)       systemctl stop nginx && ok "Stopped: nginx" ;;
    docker-compose)
      local dir; dir=$(_compose_dir "$name")
      docker compose -f "$dir/docker-compose.yml" stop && ok "Stopped: $name"
      ;;
    *)           fail "Unknown service type for '$name'" ;;
  esac
}

# ─── CMD: restart ────────────────────────────────────────────────────────────
cmd_restart() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Usage: $0 restart <name>"; exit 1; }
  local type
  type=$(detect_type "$name")
  info "Restarting $name [$type]..."
  case "$type" in
    pm2)
      pm2 restart "$name" && ok "Restarted: $name"
      pm2 describe "$name" | grep -E "status|uptime|pid" | head -3
      ;;
    systemd)
      systemctl restart "$name"
      sleep 1
      local new_status
      new_status=$(systemctl is-active "$name" 2>/dev/null || echo "failed")
      if [ "$new_status" = "active" ]; then
        ok "Restarted: $name (status: active)"
      else
        fail "Restart may have failed: $name (status: $new_status)"
        systemctl status "$name" --no-pager -l --lines 10
        exit 1
      fi
      ;;
    nginx)
      nginx -t && systemctl restart nginx && ok "Restarted: nginx"
      ;;
    docker-compose)
      local dir; dir=$(_compose_dir "$name")
      docker compose -f "$dir/docker-compose.yml" restart && ok "Restarted: $name"
      ;;
    *)
      fail "Unknown service type for '$name'"
      ;;
  esac
}

# ─── CMD: reload (graceful, zero-downtime) ────────────────────────────────────
cmd_reload() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Usage: $0 reload <name>"; exit 1; }
  local type
  type=$(detect_type "$name")
  info "Reloading $name [$type] (graceful)..."
  case "$type" in
    pm2)
      # PM2 cluster mode: graceful reload (0 downtime)
      pm2 reload "$name" && ok "Reloaded: $name"
      ;;
    systemd)
      # Try reload first (SIGHUP), fall back to restart
      if systemctl reload "$name" 2>/dev/null; then
        ok "Reloaded: $name"
      else
        warn "Service does not support reload, falling back to restart"
        systemctl restart "$name" && ok "Restarted: $name"
      fi
      ;;
    nginx)
      nginx -t && systemctl reload nginx && ok "Reloaded: nginx (config test passed)"
      ;;
    docker-compose)
      warn "Docker Compose does not support graceful reload — use restart instead"
      cmd_restart "$name"
      ;;
    *)
      fail "Unknown service type for '$name'"
      ;;
  esac
}

# ─── CMD: enable (auto-start on boot) ────────────────────────────────────────
cmd_enable() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Usage: $0 enable <name>"; exit 1; }
  local type
  type=$(detect_type "$name")
  info "Enabling auto-start on boot: $name [$type]..."
  case "$type" in
    pm2)
      warn "For PM2, run these commands manually (requires interactive shell):"
      echo "  1. pm2 startup"
      echo "  2. Copy and run the printed command"
      echo "  3. pm2 save"
      ;;
    systemd)
      systemctl enable "$name"
      ok "Auto-start enabled: $name"
      echo "  Verify: systemctl is-enabled $name"
      ;;
    nginx)
      systemctl enable nginx
      ok "Auto-start enabled: nginx"
      ;;
    docker-compose)
      warn "For Docker Compose, add 'restart: unless-stopped' to each service in docker-compose.yml"
      local dir; dir=$(_compose_dir "$name")
      echo "  File: $dir/docker-compose.yml"
      ;;
    *)
      fail "Unknown service type for '$name'"
      ;;
  esac
}

# ─── CMD: disable ────────────────────────────────────────────────────────────
cmd_disable() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Usage: $0 disable <name>"; exit 1; }
  local type
  type=$(detect_type "$name")
  info "Disabling auto-start on boot: $name [$type]..."
  case "$type" in
    pm2)
      pm2 delete "$name" && pm2 save
      warn "Removed from PM2 saved list. Service will not restart on reboot."
      ;;
    systemd)
      systemctl disable "$name"
      ok "Auto-start disabled: $name"
      ;;
    nginx)
      systemctl disable nginx
      warn "Nginx will NOT start on reboot"
      ;;
    *)
      fail "Unknown service type for '$name'"
      ;;
  esac
}

# ─── CMD: logs ───────────────────────────────────────────────────────────────
cmd_logs() {
  local name="${1:-}" lines="${2:-100}"
  [ -z "$name" ] && { echo "Usage: $0 logs <name> [lines]"; exit 1; }
  local type
  type=$(detect_type "$name")
  case "$type" in
    pm2)
      pm2 logs "$name" --lines "$lines" --nostream 2>/dev/null \
        || pm2 logs "$name" --lines "$lines" 2>/dev/null
      ;;
    systemd)
      journalctl -u "$name" --no-pager -n "$lines"
      ;;
    nginx)
      echo "=== Access Log (last $lines) ==="
      tail -"$lines" /var/log/nginx/access.log 2>/dev/null
      echo "=== Error Log (last $lines) ==="
      tail -"$lines" /var/log/nginx/error.log 2>/dev/null
      ;;
    docker-compose)
      local dir; dir=$(_compose_dir "$name")
      docker compose -f "$dir/docker-compose.yml" logs --tail="$lines" 2>/dev/null
      ;;
    *)
      # Try file logs
      for logfile in "/var/log/apps/$name/app.log" "/var/log/apps/$name/out.log"; do
        if [ -f "$logfile" ]; then
          tail -"$lines" "$logfile"
          return
        fi
      done
      fail "Cannot find logs for '$name'"
      ;;
  esac
}

# ─── CMD: boot-check ─────────────────────────────────────────────────────────
cmd_boot_check() {
  echo ""
  echo -e "${BOLD}${CYAN}Boot Auto-Start Verification${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"

  local issues=0

  _check_boot() {
    local name="$1" type="$2" enabled="$3"
    printf "  %-25s [%-12s] " "$name" "$type"
    case "$enabled" in
      enabled|always|unless-stopped)
        echo -e "${GREEN}✓ auto-start on boot${NC}" ;;
      disabled)
        echo -e "${RED}✗ DISABLED — will NOT start on reboot${NC}"
        ((issues++)) || true
        ;;
      not-configured)
        echo -e "${YELLOW}! PM2 startup not configured${NC}"
        ((issues++)) || true
        ;;
      *)
        echo -e "${YELLOW}? $enabled${NC}" ;;
    esac
  }

  # Nginx
  command -v nginx &>/dev/null && \
    _check_boot "nginx" "nginx" "$(systemctl is-enabled nginx 2>/dev/null || echo disabled)"

  # PM2
  if command -v pm2 &>/dev/null; then
    local pm2_unit pm2_boot
    pm2_unit=$(systemctl list-unit-files 2>/dev/null | grep "^pm2-" | awk '{print $1}' | head -1)
    pm2_boot=$([ -n "$pm2_unit" ] && systemctl is-enabled "$pm2_unit" 2>/dev/null || echo "not-configured")
    pm2 jlist 2>/dev/null | jq -r '.[].name' 2>/dev/null | while read -r pname; do
      _check_boot "$pname" "pm2" "$pm2_boot"
    done
  fi

  # Systemd custom services
  if command -v systemctl &>/dev/null; then
    while IFS= read -r unit; do
      local svc_name="${unit%.service}"
      local svc_enabled
      svc_enabled=$(systemctl is-enabled "$unit" 2>/dev/null || echo "disabled")
      _check_boot "$svc_name" "systemd" "$svc_enabled"
    done < <(find /etc/systemd/system -maxdepth 1 -name "*.service" 2>/dev/null \
      | xargs -I{} basename {} \
      | grep -vE "^(nginx|mysql|mariadb|postgresql|redis|docker|fail2ban|ssh|cron|ufw|firewalld|systemd|dbus|network|accounts|bluetooth|cups|gdm|getty|grub|kernel|logrotate|logind|ModemManager|NetworkManager|plymouth|remote|rtkit|selinux|smartd|thermald|wpa|unattended|php|certbot|pm2)" \
      | head -20)
  fi

  # Docker Compose projects
  for base in /opt/docker-apps /srv; do
    [ -d "$base" ] || continue
    for compose_file in "$base"/*/docker-compose.yml "$base"/*/compose.yml; do
      [ -f "$compose_file" ] || continue
      local proj_name
      proj_name=$(basename "$(dirname "$compose_file")")
      # Check first running container's restart policy
      local container restart_policy
      container=$(docker compose -f "$compose_file" ps -q 2>/dev/null | head -1 || echo "")
      if [ -n "$container" ]; then
        restart_policy=$(docker inspect "$container" \
          --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown")
      else
        restart_policy="no-containers-running"
      fi
      _check_boot "$proj_name" "compose" "$restart_policy"
    done
  done

  echo ""
  if [ "$issues" -eq 0 ]; then
    ok "All services are configured for auto-start on boot"
  else
    warn "$issues service(s) are NOT configured for auto-start"
    echo ""
    echo -e "  ${BLUE}Fix with:${NC} bash service-control.sh enable <name>"
    echo -e "  ${BLUE}Fix all: ${NC} bash service-control.sh boot-fix"
  fi
  echo ""
}

# ─── CMD: boot-fix ───────────────────────────────────────────────────────────
cmd_boot_fix() {
  echo ""
  info "Enabling auto-start for all detected services..."

  # Nginx
  if command -v nginx &>/dev/null; then
    systemctl enable nginx 2>/dev/null && ok "nginx: enabled" || warn "nginx: already enabled or failed"
  fi

  # PM2
  if command -v pm2 &>/dev/null; then
    local pm2_unit
    pm2_unit=$(systemctl list-unit-files 2>/dev/null | grep "^pm2-" | awk '{print $1}' | head -1)
    if [ -z "$pm2_unit" ]; then
      warn "PM2 startup not configured. Run: pm2 startup && <run printed command> && pm2 save"
    else
      systemctl enable "$pm2_unit" 2>/dev/null && ok "PM2 ($pm2_unit): enabled"
      pm2 save && ok "PM2 process list saved"
    fi
  fi

  # Systemd custom services
  while IFS= read -r unit; do
    systemctl enable "$unit" 2>/dev/null && ok "${unit%.service}: enabled" || true
  done < <(find /etc/systemd/system -maxdepth 1 -name "*.service" 2>/dev/null \
    | xargs -I{} basename {} \
    | grep -vE "^(nginx|mysql|mariadb|postgresql|redis|docker|fail2ban|ssh|cron|ufw|firewalld|systemd|dbus|network|accounts|bluetooth|cups|gdm|getty|grub|kernel|logrotate|logind|ModemManager|NetworkManager|plymouth|remote|rtkit|selinux|smartd|thermald|wpa|unattended|php|certbot|pm2)" \
    | head -20)

  # Standard infrastructure
  for svc in mysql mariadb postgresql redis fail2ban docker; do
    command -v "$svc" &>/dev/null || systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service" || continue
    systemctl enable "$svc" 2>/dev/null && ok "$svc: enabled" || true
  done

  echo ""
  info "Running boot-check to verify..."
  cmd_boot_check
}

# ─── Helper: find compose dir ─────────────────────────────────────────────────
_compose_dir() {
  local name="$1"
  for base in /opt/docker-apps /srv /home /root; do
    [ -d "$base/$name" ] || continue
    [ -f "$base/$name/docker-compose.yml" ] && echo "$base/$name" && return
    [ -f "$base/$name/compose.yml" ] && echo "$base/$name" && return
  done
  echo "/opt/docker-apps/$name"
}

# ─── CMD: help ───────────────────────────────────────────────────────────────
cmd_help() {
  cat << 'HELP'

service-control.sh — Unified service management (PM2 / systemd / Docker Compose / Nginx)

Usage:
  bash service-control.sh <command> [service-name] [options]

Commands:
  status [name]        Show status of all services, or one specific service
  start <name>         Start a service
  stop <name>          Stop a service
  restart <name>       Hard restart (brief downtime)
  reload <name>        Graceful reload — zero downtime where supported
                         PM2: cluster reload  Nginx: config reload  systemd: SIGHUP
  enable <name>        Enable auto-start on boot
  disable <name>       Disable auto-start on boot
  logs <name> [n]      Show last N lines of logs (default: 100)
  boot-check           Verify all services are enabled for auto-start
  boot-fix             Enable auto-start for all detected services
  help                 Show this help

Auto-detected service types:
  pm2            Node.js processes managed by PM2
  systemd        Java / Python / Go / custom services via systemd units
  docker-compose Services in /opt/docker-apps/<name>/docker-compose.yml
  nginx          Nginx web server

Examples:
  bash service-control.sh status
  bash service-control.sh status my-api
  bash service-control.sh restart my-api
  bash service-control.sh reload nginx
  bash service-control.sh enable my-java-app
  bash service-control.sh boot-check
  bash service-control.sh logs my-api 200

HELP
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-status}"
  shift || true

  case "$cmd" in
    status)      cmd_status "$@" ;;
    start)       cmd_start "$@" ;;
    stop)        cmd_stop "$@" ;;
    restart)     cmd_restart "$@" ;;
    reload)      cmd_reload "$@" ;;
    enable)      cmd_enable "$@" ;;
    disable)     cmd_disable "$@" ;;
    logs)        cmd_logs "$@" ;;
    boot-check)  cmd_boot_check ;;
    boot-fix)    cmd_boot_fix ;;
    help|--help|-h) cmd_help ;;
    *)
      fail "Unknown command: $cmd"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
