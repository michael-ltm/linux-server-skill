# User Management Guide

Linux users, groups, sudo permissions, SSH key management, SFTP accounts, and session auditing.

---

## User Overview

```bash
# List all non-system users (UID >= 1000)
awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3, $6, $7}' /etc/passwd

# List all users with their last login
lastlog | grep -v "Never\|^Username"

# Currently logged-in users
who -a
w                              # with what they're doing
last | head -20                # login history

# User details
id <username>                  # uid, gid, groups
groups <username>              # group memberships
```

---

## Create & Manage Users

### Create a user

```bash
# Standard login user (with home dir)
useradd -m -s /bin/bash -c "Deploy User" <username>
# Set password
passwd <username>
# OR: set password non-interactively
echo "<username>:<password>" | chpasswd

# Create user and add to groups in one command
useradd -m -s /bin/bash -G sudo,www-data -c "Admin User" <username>
passwd <username>

# Create system user (for running services, no login)
useradd -r -s /bin/false -d /opt/myapp -c "MyApp Service" <svcuser>
# OR: with specific UID (for consistent Docker/Kubernetes mapping)
useradd -r -u 1500 -s /bin/false <svcuser>
```

### Modify a user

```bash
# Add to group (supplement existing groups)
usermod -aG sudo <username>       # add to sudo group
usermod -aG www-data <username>   # add to web group
usermod -aG docker <username>     # add to docker group

# Change default shell
usermod -s /bin/bash <username>
usermod -s /usr/bin/zsh <username>
# Disable login (set shell to nologin)
usermod -s /usr/sbin/nologin <username>

# Change home directory
usermod -d /new/home -m <username>   # -m: move files

# Lock/unlock account
passwd -l <username>    # lock (prepend ! to password hash)
passwd -u <username>    # unlock
# Check lock status
passwd -S <username>
```

### Delete a user

```bash
# Remove user + home directory
userdel -r <username>
# Remove user but keep home dir
userdel <username>
# Kill all processes for user first
pkill -u <username>
```

---

## Groups

```bash
# List all groups
cat /etc/group | sort
# Create group
groupadd webteam
# Add user to group
usermod -aG webteam <username>
# Remove user from group
gpasswd -d <username> webteam
# Delete group
groupdel webteam
# Change group ownership of directory
chgrp -R webteam /var/www/shared/
chmod -R g+rw /var/www/shared/
```

---

## Sudo Management

```bash
# Grant full sudo access (Ubuntu/Debian: sudo group; RHEL: wheel group)
usermod -aG sudo <username>      # Ubuntu/Debian
usermod -aG wheel <username>     # CentOS/RHEL/Fedora

# Fine-grained sudo rules (safer than full sudo)
cat >> /etc/sudoers.d/<username> << 'EOF'
# Allow user to restart specific services only
<username> ALL=(ALL) NOPASSWD: /bin/systemctl restart myapp, /bin/systemctl reload nginx
# Allow running deploy scripts
<username> ALL=(ALL) NOPASSWD: /opt/server-tools/deploy.sh
# Allow Nginx management only
<username> ALL=(ALL) NOPASSWD: /bin/systemctl reload nginx, /bin/systemctl restart nginx, /usr/sbin/nginx -t
EOF
chmod 440 /etc/sudoers.d/<username>

# Validate sudoers syntax (MUST check before saving)
visudo -c -f /etc/sudoers.d/<username>

# List sudo rules for a user
sudo -l -U <username>

# Remove sudo access
deluser <username> sudo      # Ubuntu/Debian
gpasswd -d <username> wheel  # CentOS/RHEL
rm /etc/sudoers.d/<username>
```

---

## SSH Key Management

### Add SSH public key for a user

```bash
# Create .ssh dir with correct permissions
su - <username> -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
# Add public key
echo "<paste-public-key-here>" >> /home/<username>/.ssh/authorized_keys
chown <username>:<username> /home/<username>/.ssh/authorized_keys
chmod 600 /home/<username>/.ssh/authorized_keys

# Verify
cat /home/<username>/.ssh/authorized_keys
```

### Generate SSH key pair on server (for outbound connections)

```bash
# As specific user
su - <username> -c 'ssh-keygen -t ed25519 -C "server-deploy-key" -f ~/.ssh/deploy_key -N ""'
# View public key (to add to GitHub/GitLab)
cat /home/<username>/.ssh/deploy_key.pub
```

### Manage multiple keys

```bash
# List authorized keys for a user
cat /home/<username>/.ssh/authorized_keys
# Remove a specific key (by comment or content match)
sed -i '/deploy-key-old/d' /home/<username>/.ssh/authorized_keys
# Disable a key (comment it out)
sed -i 's/^ssh-ed25519 AAAA.*/# DISABLED &/' /home/<username>/.ssh/authorized_keys

# Rotate all keys: replace with new key
cat > /home/<username>/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAA... new-key-2024
EOF
chmod 600 /home/<username>/.ssh/authorized_keys
```

### SSH config file (for outbound connections from server)

```bash
cat > /home/<username>/.ssh/config << 'EOF'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/deploy_key
    StrictHostKeyChecking no

Host staging
    HostName 192.168.1.200
    Port 22
    User ubuntu
    IdentityFile ~/.ssh/staging_key

Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ConnectTimeout 15
EOF
chmod 600 /home/<username>/.ssh/config
chown <username>:<username> /home/<username>/.ssh/config
```

---

## SFTP Accounts (for web access only)

Create isolated SFTP users who can only access their web directory, no shell login.

### Setup SFTP chroot jail

```bash
# Add SFTP-only group
groupadd sftpusers

# Configure SSH for SFTP chroot (add to /etc/ssh/sshd_config)
cat >> /etc/ssh/sshd_config << 'EOF'

# SFTP chroot configuration
Match Group sftpusers
    ChrootDirectory /var/www/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF

sshd -t && systemctl reload sshd
```

### Create SFTP user for a website

```bash
SITE_NAME="myblog"
SFTP_USER="sftp_myblog"
SFTP_PASS="$(openssl rand -base64 16)"

# The chroot dir MUST be owned by root
mkdir -p /var/www/$SFTP_USER
chown root:root /var/www/$SFTP_USER
chmod 755 /var/www/$SFTP_USER

# Create the actual web dir inside chroot
mkdir -p /var/www/$SFTP_USER/html
chown $SFTP_USER:$SFTP_USER /var/www/$SFTP_USER/html

# Create user
useradd -m -d /var/www/$SFTP_USER -s /usr/sbin/nologin -G sftpusers $SFTP_USER
echo "$SFTP_USER:$SFTP_PASS" | chpasswd

echo "SFTP User: $SFTP_USER"
echo "Password:  $SFTP_PASS"
echo "Path:      /html (inside chroot = /var/www/$SFTP_USER/html)"

# Test: sftp sftp_myblog@<server>
# Connect: sftp -P 22 sftp_myblog@<server>  → cd html → put index.html
```

### List all SFTP users

```bash
grep sftpusers /etc/group | cut -d: -f4 | tr ',' '\n' | while read user; do
  echo "User: $user | Home: $(getent passwd $user | cut -d: -f6) | Status: $(passwd -S $user | awk '{print $2}')"
done
```

---

## Session Management & Auditing

```bash
# Who is currently logged in and what they're doing
w
who

# Full login history (including IPs)
last -n 30
last -F | head -20    # with full timestamps

# Failed login attempts
lastb | head -20
# Failed logins count per IP
lastb 2>/dev/null | awk '{print $3}' | sort | uniq -c | sort -rn | head -10

# Audit user actions (if auditd installed)
apt-get install -y auditd 2>/dev/null || dnf install -y audit 2>/dev/null
systemctl enable --now auditd

# Watch file access by user
auditctl -w /etc/passwd -p wa -k user-changes
auditctl -w /var/www -p wxa -k web-changes   # watch web dir

# View audit log
ausearch -k user-changes | tail -30
ausearch -k web-changes --start recent | tail -30
ausearch -ua <username> | tail -30             # all activity by user

# Kill a user session
pkill -u <username>                            # kill all their processes
kill -9 $(pgrep -u <username>)
# Disconnect SSH session (find PID from 'who')
kill -HUP <sshd-pid>
```

---

## Password Policies

```bash
# Install libpam-pwquality for password strength enforcement
apt-get install -y libpam-pwquality 2>/dev/null || dnf install -y libpwquality 2>/dev/null

# Configure minimum password quality
cat > /etc/security/pwquality.conf << 'EOF'
minlen = 12          # minimum length
minclass = 3         # require 3 of: upper, lower, digits, special
maxrepeat = 3        # max repeated chars
dcredit = -1         # require at least 1 digit
ucredit = -1         # require at least 1 uppercase
lcredit = -1         # require at least 1 lowercase
ocredit = -1         # require at least 1 special char
EOF

# Set password expiry
chage -M 90 <username>    # password expires in 90 days
chage -l <username>       # view expiry info for user
# Force password change on next login
chage -d 0 <username>

# Global password aging defaults
cat >> /etc/login.defs << 'EOF'
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14
EOF
```

---

## Deploy User Best Practice

Create a dedicated deploy user for CI/CD and deployments:

```bash
# Create deploy user
useradd -m -s /bin/bash -c "CI/CD Deploy" deploy
# Add SSH key (your CI system's public key)
mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
echo "<ci-system-public-key>" > /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

# Grant only what deploy needs
cat > /etc/sudoers.d/deploy << 'EOF'
deploy ALL=(ALL) NOPASSWD: /bin/systemctl reload nginx
deploy ALL=(ALL) NOPASSWD: /bin/systemctl restart myapp
deploy ALL=(ALL) NOPASSWD: /usr/bin/pm2 reload all
deploy ALL=(ALL) NOPASSWD: /opt/server-tools/deploy.sh
EOF
chmod 440 /etc/sudoers.d/deploy

# Give deploy ownership of web directories
chown -R deploy:www-data /var/www/
chmod -R 775 /var/www/

echo "Deploy user ready. SSH: ssh deploy@<host>"
```

---

## Network & Process Per-User

```bash
# What ports/connections does a specific user own?
ss -tlnp | grep <username>
# OR by process: first find PIDs
pgrep -u <username>
ss -tlnp | grep -E "$(pgrep -u <username> | tr '\n' '|' | sed 's/|$//')"

# Kill user's processes gracefully then force
pkill -u <username> -TERM
sleep 3
pkill -u <username> -KILL

# Resource usage by user
ps aux | awk 'NR==1 || $1=="<username>"'
top -u <username>    # interactive
```
