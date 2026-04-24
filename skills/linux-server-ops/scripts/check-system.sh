#!/bin/bash
# check-system.sh — Server bootstrap script
# Upload to server and run as root: bash /tmp/check-system.sh
# Detects distro and installs all required core dependencies.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (or with sudo)"
    exit 1
  fi
}

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID,,}"
    DISTRO_VERSION="${VERSION_ID:-0}"
  elif [ -f /etc/redhat-release ]; then
    DISTRO_ID="centos"
    DISTRO_VERSION="7"
  else
    DISTRO_ID=$(uname -s | tr '[:upper:]' '[:lower:]')
    DISTRO_VERSION="unknown"
  fi

  case "$DISTRO_ID" in
    ubuntu|debian|raspbian) PKG_MANAGER="apt" ;;
    centos|rhel|rocky|almalinux)
      if command -v dnf &>/dev/null; then PKG_MANAGER="dnf"
      else PKG_MANAGER="yum"; fi
      ;;
    fedora) PKG_MANAGER="dnf" ;;
    alpine) PKG_MANAGER="apk" ;;
    arch|manjaro) PKG_MANAGER="pacman" ;;
    *)
      warn "Unknown distro: $DISTRO_ID — attempting apt-get"
      PKG_MANAGER="apt"
      ;;
  esac

  # Detect init system
  if ps -p 1 -o comm= 2>/dev/null | grep -q systemd; then
    INIT="systemd"
  elif command -v rc-service &>/dev/null; then
    INIT="openrc"
  else
    INIT="other"
  fi

  # Detect Nginx user
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian) NGINX_USER="www-data" ;;
    arch) NGINX_USER="http" ;;
    *) NGINX_USER="nginx" ;;
  esac

  info "Distro:       $DISTRO_ID $DISTRO_VERSION"
  info "Pkg Manager:  $PKG_MANAGER"
  info "Init System:  $INIT"
  info "Nginx User:   $NGINX_USER"
}

install_packages() {
  local packages=("$@")
  info "Installing: ${packages[*]}"
  case "$PKG_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    pacman)
      pacman -S --noconfirm "${packages[@]}"
      ;;
  esac
}

enable_service() {
  local service=$1
  case "$INIT" in
    systemd) systemctl enable --now "$service" 2>/dev/null && log "Service enabled: $service" || warn "Could not enable $service" ;;
    openrc)  rc-update add "$service" default 2>/dev/null; rc-service "$service" start 2>/dev/null || warn "Could not start $service" ;;
    *) warn "Unknown init system — start $service manually" ;;
  esac
}

# ─── Step 1: Update package index ────────────────────────────────────────────
update_packages() {
  info "Updating package index..."
  case "$PKG_MANAGER" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    dnf)    dnf makecache -y ;;
    yum)    yum makecache -y ;;
    apk)    apk update ;;
    pacman) pacman -Sy ;;
  esac
  log "Package index updated"
}

# ─── Step 2: Install EPEL (CentOS/RHEL) ──────────────────────────────────────
install_epel() {
  if [[ "$DISTRO_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
    if ! rpm -q epel-release &>/dev/null; then
      info "Installing EPEL repository..."
      case "$PKG_MANAGER" in
        dnf) dnf install -y epel-release ;;
        yum) yum install -y epel-release ;;
      esac
      log "EPEL installed"
    else
      log "EPEL already installed"
    fi
  fi
}

# ─── Step 3: Install core tools ──────────────────────────────────────────────
install_core_tools() {
  info "Installing core tools..."
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian)
      install_packages curl wget git jq htop unzip logrotate ca-certificates gnupg lsb-release
      ;;
    centos|rhel|rocky|almalinux|fedora)
      install_packages curl wget git jq htop unzip logrotate ca-certificates
      ;;
    alpine)
      install_packages curl wget git jq htop unzip logrotate bash shadow
      ;;
    arch|manjaro)
      install_packages curl wget git jq htop unzip logrotate
      ;;
  esac
  log "Core tools installed"
}

# ─── Step 4: Install Nginx ────────────────────────────────────────────────────
install_nginx() {
  if command -v nginx &>/dev/null; then
    log "Nginx already installed: $(nginx -v 2>&1)"
    return
  fi
  info "Installing Nginx..."
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian) install_packages nginx ;;
    centos|rhel|rocky|almalinux|fedora) install_packages nginx ;;
    alpine) install_packages nginx ;;
    arch|manjaro) install_packages nginx ;;
  esac
  enable_service nginx

  # Create required directories
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/log/nginx

  # Add include for sites-enabled if not present (RHEL/CentOS don't have this by default)
  if ! grep -q "sites-enabled" /etc/nginx/nginx.conf 2>/dev/null; then
    if grep -q "http {" /etc/nginx/nginx.conf 2>/dev/null; then
      sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi
  fi

  # Remove default page if it exists
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && log "Nginx installed and configured" || warn "Nginx config test failed — check /etc/nginx/nginx.conf"
}

# ─── Step 5: Install Certbot ──────────────────────────────────────────────────
install_certbot() {
  if command -v certbot &>/dev/null; then
    log "Certbot already installed: $(certbot --version 2>&1)"
    return
  fi
  info "Installing Certbot..."
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian)
      install_packages certbot python3-certbot-nginx
      ;;
    centos|rhel|rocky|almalinux|fedora)
      install_packages certbot python3-certbot-nginx
      ;;
    alpine)
      install_packages certbot certbot-nginx
      ;;
    arch|manjaro)
      install_packages certbot certbot-nginx
      ;;
    *)
      # Fallback: snap
      if command -v snap &>/dev/null; then
        snap install --classic certbot
        ln -sf /snap/bin/certbot /usr/bin/certbot
      else
        warn "Could not install certbot automatically — install manually"
        return
      fi
      ;;
  esac

  # Verify auto-renewal timer or cron
  if systemctl list-timers | grep -q certbot 2>/dev/null; then
    log "Certbot auto-renewal timer active"
  else
    # Add cron fallback
    if ! crontab -l 2>/dev/null | grep -q certbot; then
      (crontab -l 2>/dev/null; echo "0 0,12 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx 2>/dev/null || true'") | crontab -
      log "Certbot renewal cron added"
    fi
  fi
  log "Certbot installed"
}

# ─── Step 6: Install Fail2ban ─────────────────────────────────────────────────
install_fail2ban() {
  if command -v fail2ban-client &>/dev/null; then
    log "fail2ban already installed"
    return
  fi
  info "Installing fail2ban..."
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian) install_packages fail2ban ;;
    centos|rhel|rocky|almalinux|fedora) install_packages fail2ban ;;
    alpine) install_packages fail2ban ;;
    arch|manjaro) install_packages fail2ban ;;
  esac

  # Basic jail config
  if [ ! -f /etc/fail2ban/jail.local ]; then
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
maxretry = 3
bantime  = 86400
EOF
  fi
  enable_service fail2ban
  log "fail2ban installed and enabled"
}

# ─── Step 7: Install Firewall ─────────────────────────────────────────────────
install_firewall() {
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian)
      if ! command -v ufw &>/dev/null; then
        install_packages ufw
      fi
      if ! ufw status | grep -q "Status: active"; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw limit ssh
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw --force enable
        log "UFW firewall configured and enabled"
      else
        log "UFW already active"
      fi
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if ! command -v firewall-cmd &>/dev/null; then
        install_packages firewalld
      fi
      enable_service firewalld
      firewall-cmd --permanent --add-service={ssh,http,https} 2>/dev/null
      firewall-cmd --reload 2>/dev/null
      log "firewalld configured"
      ;;
    *)
      warn "Firewall setup: configure manually for $DISTRO_ID"
      ;;
  esac
}

# ─── Step 8: Create directories ───────────────────────────────────────────────
create_directories() {
  info "Creating standard directories..."
  mkdir -p \
    /var/www \
    /opt/java-apps \
    /opt/python-apps \
    /opt/docker-apps \
    /var/log/apps \
    /opt/server-tools

  chmod 755 /var/www /opt/java-apps /opt/python-apps /opt/docker-apps
  chmod 750 /opt/server-tools
  log "Standard directories created"
}

# ─── Step 9: Install service registry script ─────────────────────────────────
install_registry() {
  if [ ! -f /opt/server-tools/service-registry.sh ]; then
    warn "service-registry.sh not found in /opt/server-tools/"
    warn "Upload it: scp scripts/service-registry.sh user@host:/opt/server-tools/"
  else
    chmod +x /opt/server-tools/service-registry.sh
    log "service-registry.sh found and made executable"
  fi

  # Initialize registry if missing
  if [ ! -f /etc/server-registry.json ]; then
    cat > /etc/server-registry.json << EOF
{
  "host": "$(hostname -f 2>/dev/null || hostname)",
  "server_ip": "$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')",
  "distro": "$DISTRO_ID $DISTRO_VERSION",
  "initialized": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {}
}
EOF
    chmod 600 /etc/server-registry.json
    log "Service registry initialized at /etc/server-registry.json"
  else
    log "Service registry already exists"
  fi
}

# ─── Step 10: System info report ─────────────────────────────────────────────
print_report() {
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Server Bootstrap Complete"
  echo "════════════════════════════════════════════════════"
  echo "  Hostname:    $(hostname -f 2>/dev/null || hostname)"
  echo "  IP:          $(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  echo "  Distro:      $DISTRO_ID $DISTRO_VERSION"
  echo "  Nginx:       $(nginx -v 2>&1 | grep -o 'nginx/[0-9.]*' || echo 'not installed')"
  echo "  Certbot:     $(certbot --version 2>&1 | grep -o '[0-9.]*' | head -1 || echo 'not installed')"
  echo "  Fail2ban:    $(fail2ban-client --version 2>&1 | grep -o '[0-9.]*' | head -1 || echo 'not installed')"
  echo "  Firewall:    $(ufw status 2>/dev/null | head -1 || firewall-cmd --state 2>/dev/null || echo 'unknown')"
  echo "  Registry:    /etc/server-registry.json"
  echo "  Tools dir:   /opt/server-tools/"
  echo "════════════════════════════════════════════════════"
  echo ""
  echo "Next steps:"
  echo "  1. Upload service-registry.sh to /opt/server-tools/"
  echo "  2. Harden SSH: edit /etc/ssh/sshd_config (see security-guide.md)"
  echo "  3. Deploy your first service (see SKILL.md Step 4)"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "  Linux Server Bootstrap — check-system.sh"
  echo "═══════════════════════════════════════════════════"
  require_root
  detect_distro
  update_packages
  install_epel
  install_core_tools
  install_nginx
  install_certbot
  install_fail2ban
  install_firewall
  create_directories
  install_registry
  print_report
}

main "$@"
