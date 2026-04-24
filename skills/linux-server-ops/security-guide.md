# Security Guide

Server hardening, access control, and security best practices.

---

## SSH Hardening

### Key-based authentication (mandatory)

```bash
# 1. On your LOCAL machine — generate key pair if you don't have one
ssh-keygen -t ed25519 -C "server-admin" -f ~/.ssh/server_key

# 2. Copy public key to server
ssh-copy-id -i ~/.ssh/server_key.pub user@<host>
# OR manually:
ssh user@host 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
cat ~/.ssh/server_key.pub | ssh user@host 'cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'

# 3. Test key auth BEFORE disabling password auth
ssh -i ~/.ssh/server_key user@<host> 'echo "Key auth works"'
```

### Harden `/etc/ssh/sshd_config`

```bash
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Disable root login
PermitRootLogin no

# Disable password authentication (key only)
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# Disable empty passwords
PermitEmptyPasswords no

# Only allow specific users (add your username)
# AllowUsers deploy ubuntu ec2-user

# Protocol and ciphers
Protocol 2
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Session settings
ClientAliveInterval 300
ClientAliveCountMax 3
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5

# Disable unused features
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no

# Log level
LogLevel VERBOSE
EOF

# Validate config before reloading
sshd -t && systemctl reload sshd
```

### Change SSH port (optional, reduces noise)

```bash
echo "Port 2222" >> /etc/ssh/sshd_config.d/99-hardening.conf
# Update firewall FIRST before reloading SSH
ufw allow 2222/tcp
ufw delete allow 22/tcp   # remove old rule
sshd -t && systemctl reload sshd
```

---

## Firewall Configuration

### UFW (Ubuntu/Debian)

```bash
# Reset to defaults
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow required services
ufw allow ssh         # port 22 (or custom port)
ufw allow 80/tcp      # HTTP
ufw allow 443/tcp     # HTTPS

# Rate limit SSH (blocks brute force)
ufw limit ssh

# Enable
ufw --force enable
ufw status verbose

# Block specific IP
ufw deny from <malicious-ip>
# Allow specific IP for admin access
ufw allow from <your-office-ip> to any port 22
```

### firewalld (CentOS/RHEL/Fedora)

```bash
systemctl enable --now firewalld

# Default zone
firewall-cmd --set-default-zone=public

# Allow services
firewall-cmd --permanent --add-service={ssh,http,https}
firewall-cmd --permanent --remove-service=cockpit 2>/dev/null

# Rate limit SSH (rich rule)
firewall-cmd --permanent --add-rich-rule='rule service name="ssh" limit value="5/min" accept'

# Block IP
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<ip>" reject'

# Apply
firewall-cmd --reload
firewall-cmd --list-all
```

---

## Fail2ban Setup

Automatically ban IPs with too many failed login attempts.

```bash
# Install
apt-get install -y fail2ban   # Ubuntu/Debian
dnf install -y fail2ban        # CentOS/RHEL

# Local config (never edit jail.conf directly)
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# Ban for 1 hour
bantime  = 3600
# Detection window: 10 minutes
findtime = 600
# Max retries before ban
maxretry = 5
# Ignore localhost and your own IP
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 86400   # 24 hours for SSH

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s
maxretry = 2
EOF

systemctl enable --now fail2ban

# Check status
fail2ban-client status
fail2ban-client status sshd

# Unban an IP manually
fail2ban-client set sshd unbanip <ip>

# View banned IPs
fail2ban-client status sshd | grep "Banned IP"
```

---

## System Updates

```bash
# Ubuntu/Debian — enable unattended security updates
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";   // set true to auto-reboot for kernel updates
EOF

# CentOS/RHEL — enable automatic security updates
dnf install -y dnf-automatic
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
sed -i 's/upgrade_type = default/upgrade_type = security/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer
```

---

## File Permissions & Ownership

```bash
# Web files
chown -R www-data:www-data /var/www/          # Ubuntu/Debian
chown -R nginx:nginx /var/www/                 # CentOS/RHEL
find /var/www -type d -exec chmod 755 {} \;
find /var/www -type f -exec chmod 644 {} \;

# Sensitive files (env files, configs)
chmod 600 /var/www/*/.env
chmod 600 /opt/*/. env
chmod 600 /opt/server-tools/service-registry.sh

# Service registry (readable by root only)
chmod 600 /etc/server-registry.json
chown root:root /etc/server-registry.json

# SSH keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/id_*

# Systemd unit files
chmod 644 /etc/systemd/system/*.service

# Check for world-writable files (security audit)
find /var/www -perm -002 -type f -ls 2>/dev/null
find /etc -perm -002 -type f -ls 2>/dev/null
```

---

## Nginx Security Headers

Add to your Nginx server block (or in `http` block for global):

```nginx
# In /etc/nginx/conf.d/security-headers.conf (global)
add_header X-Frame-Options SAMEORIGIN always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

# After SSL is set up, add HSTS (DO NOT add before SSL works):
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

# Hide Nginx version
server_tokens off;

# Content Security Policy (customize per app)
# add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';" always;
```

```nginx
# Rate limiting (add to http block)
limit_req_zone $binary_remote_addr zone=api:10m rate=30r/m;
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
limit_conn_zone $binary_remote_addr zone=conn_limit_per_ip:10m;

# Apply to sensitive routes in server block:
location /api/ {
    limit_req zone=api burst=10 nodelay;
    limit_conn conn_limit_per_ip 10;
    proxy_pass http://backend;
}
location /login {
    limit_req zone=login burst=3 nodelay;
    proxy_pass http://backend;
}
```

---

## Secrets Management

### Environment variables (never in git)

```bash
# Store .env files with restricted permissions
chmod 600 /var/www/<name>/.env
chown <service-user>:<service-user> /var/www/<name>/.env

# Verify .env is in .gitignore
echo ".env" >> /var/www/<name>/.gitignore
grep ".env" /var/www/<name>/.gitignore
```

### Secrets audit

```bash
# Check for accidentally committed secrets (run on server after clone)
grep -rE "(password|secret|api_key|token|AWS_SECRET)\s*=\s*['\"][^'\"]{8,}" \
  /var/www/<name>/ --include="*.env*" --include="*.conf" -l 2>/dev/null

# Check git history for secrets (local)
git log --all --full-history -- "*.env" 2>/dev/null
```

---

## Intrusion Detection

### Check for unauthorized SSH logins

```bash
# Recent successful logins
last | head -20
# Failed login attempts
lastb | head -20
# Currently logged in
who -a
# Unauthorized SSH access attempts
grep "Failed password\|Invalid user\|authentication failure" /var/log/auth.log | tail -20
grep "Failed password\|Invalid user" /var/log/secure | tail -20   # RHEL/CentOS
```

### Rootkit check

```bash
# Install and run rkhunter
apt-get install -y rkhunter 2>/dev/null || dnf install -y rkhunter 2>/dev/null
rkhunter --update
rkhunter --check --skip-keypress

# Or chkrootkit
apt-get install -y chkrootkit 2>/dev/null
chkrootkit
```

### File integrity check

```bash
# Install aide
apt-get install -y aide 2>/dev/null || dnf install -y aide 2>/dev/null
aideinit          # initialize database (first run, takes time)
aide --check      # compare against database
```

---

## Security Audit Checklist

Run after server setup and periodically:

```bash
# Open ports
ss -tlnp

# World-writable files in /var/www and /etc
find /var/www /etc -perm -002 -type f -ls 2>/dev/null

# SUID/SGID binaries (review any unexpected)
find / -perm /6000 -type f -ls 2>/dev/null | grep -v proc

# Users with sudo
grep -v "^#" /etc/sudoers | grep -v "^$"
getent group sudo wheel | tr ':' '\n'

# Listening services
ss -tlnp | awk '{print $4, $6}'

# Failed logins last 24h
journalctl _SYSTEMD_UNIT=sshd.service --since "24h ago" | grep -c "Failed"

# Cron jobs (check for suspicious entries)
for user in $(cut -f1 -d: /etc/passwd); do crontab -u $user -l 2>/dev/null | grep -v "^#\|^$" && echo "  ↑ cron for $user"; done
cat /etc/cron.d/* 2>/dev/null
ls -la /etc/cron.{daily,weekly,monthly,hourly}/ 2>/dev/null
```

---

## Backup Strategy

```bash
# Simple daily backup script
cat > /opt/server-tools/backup.sh << 'SCRIPT'
#!/bin/bash
BACKUP_DIR="/var/backups/apps"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
mkdir -p $BACKUP_DIR

# Backup web apps
tar -czf "$BACKUP_DIR/www-$DATE.tar.gz" /var/www/ 2>/dev/null

# Backup service registry
cp /etc/server-registry.json "$BACKUP_DIR/registry-$DATE.json"

# Backup Nginx configs
tar -czf "$BACKUP_DIR/nginx-$DATE.tar.gz" /etc/nginx/ 2>/dev/null

# Backup systemd units
tar -czf "$BACKUP_DIR/systemd-$DATE.tar.gz" /etc/systemd/system/*.service 2>/dev/null

# Backup databases
# mysqldump -u root -p<password> --all-databases > "$BACKUP_DIR/mysql-$DATE.sql"
# pg_dumpall -U postgres > "$BACKUP_DIR/postgres-$DATE.sql"

# Remove old backups
find $BACKUP_DIR -mtime +$KEEP_DAYS -delete

echo "Backup completed: $BACKUP_DIR/*-$DATE.*"
SCRIPT
chmod 700 /opt/server-tools/backup.sh

# Run daily at 3am
echo "0 3 * * * root bash /opt/server-tools/backup.sh >> /var/log/backup.log 2>&1" \
  > /etc/cron.d/daily-backup
```

---

## Quick Security Hardening Script

Run once on a new server after SSH access is confirmed:

```bash
# Must run as root
if [ "$EUID" -ne 0 ]; then echo "Run as root"; exit 1; fi

# 1. Update system
apt-get update -y && apt-get upgrade -y 2>/dev/null \
  || dnf upgrade -y 2>/dev/null

# 2. Install security tools
apt-get install -y fail2ban ufw unattended-upgrades 2>/dev/null \
  || dnf install -y fail2ban firewalld dnf-automatic 2>/dev/null

# 3. Enable fail2ban
systemctl enable --now fail2ban

# 4. Configure firewall
if command -v ufw >/dev/null; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
elif command -v firewall-cmd >/dev/null; then
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service={ssh,http,https}
  firewall-cmd --reload
fi

# 5. Secure shared memory
echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab

# 6. Kernel hardening (sysctl)
cat >> /etc/sysctl.d/99-security.conf << 'EOF'
# Protect from SYN flood
net.ipv4.tcp_syncookies = 1
# Disable IP forwarding (unless this is a router)
net.ipv4.ip_forward = 0
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
EOF
sysctl --system

echo "Security hardening complete."
```
