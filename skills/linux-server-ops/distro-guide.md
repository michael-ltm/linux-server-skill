# Distro-Specific Guide

Reference for OS detection and package manager commands across all major Linux distributions.

---

## OS Detection

```bash
# Primary method
. /etc/os-release && echo "$ID $VERSION_ID"

# Fallback methods
cat /etc/redhat-release 2>/dev/null    # CentOS/RHEL
cat /etc/alpine-release 2>/dev/null    # Alpine
uname -a                                # Last resort
```

Normalize `$ID` to one of: `ubuntu` | `debian` | `centos` | `rhel` | `fedora` | `alpine` | `arch`

---

## Ubuntu / Debian

```bash
# Update & install
apt-get update -y && apt-get upgrade -y
apt-get install -y <packages>

# Core bootstrap packages
apt-get install -y \
  nginx certbot python3-certbot-nginx \
  curl wget git jq htop ufw fail2ban \
  logrotate unzip software-properties-common \
  build-essential

# Enable service
systemctl enable --now <service>

# Node.js (via NodeSource, pick version)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Java
apt-get install -y default-jdk         # OpenJDK latest
apt-get install -y openjdk-17-jdk      # specific version

# Python
apt-get install -y python3 python3-pip python3-venv

# PHP (8.x via ondrej/php PPA on Ubuntu)
add-apt-repository ppa:ondrej/php -y
apt-get update -y
apt-get install -y php8.2 php8.2-fpm php8.2-mysql php8.2-xml php8.2-mbstring php8.2-curl php8.2-zip

# Check package info
apt-cache show <package>
dpkg -l | grep <package>
```

**Notes:**
- Ubuntu 20.04+: use `apt` instead of `apt-get` interactively, but `apt-get` in scripts
- Debian 11 (Bullseye) / 12 (Bookworm): certbot available via `apt`; older versions may need `snap`
- `www-data` is the default Nginx/PHP-FPM user

---

## CentOS / RHEL

```bash
# CentOS 7 (yum, EOL - migrate if possible)
yum update -y
yum install -y epel-release
yum install -y nginx certbot python3-certbot-nginx \
  curl wget git jq htop firewalld fail2ban \
  unzip gcc make

# CentOS Stream 8/9 / RHEL 8/9 (dnf preferred)
dnf update -y
dnf install -y epel-release
dnf install -y nginx certbot python3-certbot-nginx \
  curl wget git jq htop firewalld fail2ban \
  unzip gcc make

# Enable EPEL (required for many packages on RHEL)
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Node.js (NodeSource)
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
dnf install -y nodejs

# Java
dnf install -y java-17-openjdk java-17-openjdk-devel

# Python 3
dnf install -y python3 python3-pip python3-devel

# PHP
dnf install -y php php-fpm php-mysqlnd php-xml php-mbstring php-json php-curl

# Firewall (firewalld, NOT ufw)
systemctl enable --now firewalld
firewall-cmd --permanent --add-service={http,https,ssh}
firewall-cmd --reload

# SELinux considerations
# Allow Nginx to proxy
setsebool -P httpd_can_network_connect 1
# Allow Nginx to serve /var/www
chcon -R -t httpd_sys_content_t /var/www/<name>/
```

**Notes:**
- CentOS 7 is EOL; recommend migrating to Rocky Linux or AlmaLinux
- RHEL/CentOS: Nginx user is `nginx`, not `www-data`
- SELinux is enabled by default — may block Nginx proxying; use `setsebool` above
- No `sites-available/sites-enabled` pattern; use `/etc/nginx/conf.d/*.conf`

```bash
# RHEL/CentOS Nginx config location
/etc/nginx/conf.d/<name>.conf    # (NOT sites-available)
nginx -t && systemctl reload nginx
```

---

## Rocky Linux / AlmaLinux (CentOS Replacements)

Treat identically to CentOS/RHEL 8/9 with `dnf`. OS ID will be `rocky` or `almalinux`.

```bash
dnf install -y epel-release && dnf update -y
# All commands same as CentOS/RHEL 8/9
```

---

## Fedora

```bash
dnf update -y
dnf install -y nginx certbot python3-certbot-nginx \
  curl wget git jq htop firewalld fail2ban unzip gcc make

# Node.js
dnf install -y nodejs npm    # or use NodeSource for specific version

# Java
dnf install -y java-17-openjdk

# PHP
dnf install -y php php-fpm

# Same firewalld usage as CentOS/RHEL
```

---

## Alpine Linux

Commonly used in Docker/containers or minimal VPS setups.

```bash
apk update && apk upgrade
apk add --no-cache \
  nginx certbot certbot-nginx \
  curl wget git jq htop openrc \
  bash shadow

# Node.js
apk add --no-cache nodejs npm

# Java
apk add --no-cache openjdk17

# Python
apk add --no-cache python3 py3-pip

# PHP
apk add --no-cache php82 php82-fpm php82-pdo php82-json php82-mbstring

# Service management (OpenRC, not systemd)
rc-update add nginx default
rc-service nginx start
rc-service nginx restart

# Nginx config: /etc/nginx/http.d/<name>.conf  (Alpine uses http.d/)
# No sites-available/enabled — use /etc/nginx/http.d/
```

**Notes:**
- Alpine uses OpenRC, not systemd — replace `systemctl` with `rc-service`
- Package names often differ: `php82` instead of `php8.2`
- Default shell is `ash`, not `bash` — scripts should use `#!/bin/sh`

---

## Arch Linux / Manjaro

```bash
pacman -Syu --noconfirm
pacman -S --noconfirm \
  nginx certbot certbot-nginx \
  curl wget git jq htop ufw fail2ban \
  unzip base-devel

# Node.js
pacman -S --noconfirm nodejs npm

# Java
pacman -S --noconfirm jdk17-openjdk

# Python
pacman -S --noconfirm python python-pip

# PHP
pacman -S --noconfirm php php-fpm

# AUR packages (use yay if available)
yay -S --noconfirm <aur-package>
```

---

## Nginx Config Path by Distro

| Distro | Sites Config | Reload Command |
|--------|-------------|---------------|
| Ubuntu/Debian | `/etc/nginx/sites-available/` + symlink to `sites-enabled/` | `systemctl reload nginx` |
| CentOS/RHEL/Fedora | `/etc/nginx/conf.d/*.conf` | `systemctl reload nginx` |
| Alpine | `/etc/nginx/http.d/*.conf` | `rc-service nginx reload` |
| Arch | `/etc/nginx/sites-available/` (manual) or `/etc/nginx/conf.d/` | `systemctl reload nginx` |

### Nginx vhost activation helper

```bash
# Ubuntu/Debian
ln -sf /etc/nginx/sites-available/<name> /etc/nginx/sites-enabled/<name>
nginx -t && systemctl reload nginx

# CentOS/RHEL (just put file in conf.d/)
nginx -t && systemctl reload nginx

# Alpine
nginx -t && rc-service nginx reload
```

---

## Nginx User by Distro

| Distro | Nginx User | PHP-FPM User |
|--------|-----------|-------------|
| Ubuntu/Debian | `www-data` | `www-data` |
| CentOS/RHEL | `nginx` | `apache` or `nginx` |
| Alpine | `nginx` | `nobody` or `www-data` |
| Arch | `http` | `http` |

Always set file ownership to match:

```bash
# Ubuntu/Debian
chown -R www-data:www-data /var/www/<name>
# CentOS/RHEL
chown -R nginx:nginx /var/www/<name>
```

---

## PHP-FPM Socket Path by Distro

| Distro | Socket Path |
|--------|------------|
| Ubuntu 22.04 | `/run/php/php8.2-fpm.sock` |
| Debian 12 | `/run/php/php8.2-fpm.sock` |
| CentOS/RHEL 8 | `/run/php-fpm/www.sock` |
| Alpine | `/run/php-fpm82/php-fpm82.sock` |

---

## Common Compatibility Notes

- **Certbot**: On older Debian/Ubuntu, install via `snap` if `apt` version is outdated:
  ```bash
  snap install --classic certbot && ln -sf /snap/bin/certbot /usr/bin/certbot
  ```
- **systemd availability**: Alpine and some minimal containers use OpenRC or no init system — check with `ps -p 1 -o comm=`
- **SELinux**: Active on RHEL/CentOS/Fedora by default — always run `setsebool -P httpd_can_network_connect 1` when using Nginx as proxy
- **AppArmor**: Active on Ubuntu — usually not an issue for web serving, but check `/var/log/kern.log` if getting permission errors
