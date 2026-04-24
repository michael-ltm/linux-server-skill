# File Operations Guide

File manager operations via SSH: browse, edit, permissions, compress/extract, search, and transfer files.

---

## Browse & Navigate

```bash
# List with details (size, permissions, date)
ls -lah /var/www/
ls -lahR /var/www/<name>/    # recursive

# Tree view (install if missing: apt-get install -y tree)
tree -L 3 /var/www/
tree -L 2 /opt/

# Disk usage per directory (sorted)
du -sh /var/www/* | sort -h
du -sh /opt/* | sort -h
du -sh /var/log/* | sort -h

# Find large files
find /var/www -type f -size +10M -exec ls -lh {} \; 2>/dev/null
find / -type f -size +100M -exec ls -lh {} \; 2>/dev/null | grep -v proc

# Find recently modified files
find /var/www/<name> -type f -mtime -1 -ls 2>/dev/null   # last 24h
find /etc -type f -newer /etc/passwd -ls 2>/dev/null     # modified since passwd

# Find files by name pattern
find /var/www -name "*.log" -type f 2>/dev/null
find /opt -name "*.jar" -type f 2>/dev/null
find / -name ".env" -type f 2>/dev/null | grep -v proc   # locate all .env files
```

---

## Read & Edit Files

```bash
# View file contents
cat /var/www/<name>/.env
head -50 /var/log/nginx/error.log
tail -100 /var/log/nginx/access.log
tail -f /var/log/apps/<name>/app.log   # follow live

# View with line numbers
cat -n /etc/nginx/sites-available/<name>
grep -n "server_name" /etc/nginx/sites-available/<name>

# Edit file on server (nano is safest remote editor)
nano /etc/nginx/sites-available/<name>
# vim if preferred
vim /var/www/<name>/.env

# In-place edit without interactive editor (sed)
# Replace a value in .env
sed -i 's/^PORT=.*/PORT=4000/' /var/www/<name>/.env
# Append a line
echo "NEW_VAR=value" >> /var/www/<name>/.env
# Insert after a specific line
sed -i '/^DATABASE_URL=/a REDIS_URL=redis://localhost:6379' /var/www/<name>/.env
# Delete a line matching pattern
sed -i '/^DEBUG=true/d' /var/www/<name>/.env

# Safe in-place edit: always make a backup first
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
```

---

## Permissions & Ownership

```bash
# View permissions
ls -la /var/www/<name>/
stat /var/www/<name>/index.html

# Set ownership (user:group)
chown www-data:www-data /var/www/<name>/           # Ubuntu/Debian Nginx user
chown nginx:nginx /var/www/<name>/                  # CentOS/RHEL Nginx user
chown -R www-data:www-data /var/www/<name>/         # recursive

# Set permissions
chmod 755 /var/www/<name>/                          # rwxr-xr-x (dir: traversable)
chmod 644 /var/www/<name>/index.html                # rw-r--r-- (file: readable)
chmod 600 /var/www/<name>/.env                      # rw------- (secret: owner only)
chmod 700 /opt/server-tools/                        # rwx------ (scripts: owner only)

# Bulk set (directories = 755, files = 644 — standard web pattern)
find /var/www/<name> -type d -exec chmod 755 {} \;
find /var/www/<name> -type f -exec chmod 644 {} \;
# But keep .env and key files restricted
chmod 600 /var/www/<name>/.env
chmod 600 /var/www/<name>/storage/oauth-*.key 2>/dev/null

# Laravel specific permissions
chown -R www-data:www-data /var/www/<name>
chmod -R 755 /var/www/<name>
chmod -R 775 /var/www/<name>/storage
chmod -R 775 /var/www/<name>/bootstrap/cache

# Find files with dangerous permissions
find /var/www -perm -777 -type f -ls 2>/dev/null    # world-writable files
find /var/www -perm -002 -type f -ls 2>/dev/null    # world-writable
find /var/www -name "*.php" -perm /111 -ls 2>/dev/null  # executable PHP (suspicious)

# Set immutable flag (prevent accidental modification)
chattr +i /etc/server-index.json                    # make immutable
chattr -i /etc/server-index.json                    # remove immutable flag
lsattr /etc/server-index.json                       # check flag
```

---

## Copy, Move, Delete

```bash
# Copy
cp /var/www/<name>/file.txt /tmp/file.txt.bak
cp -r /var/www/<name>/ /var/www/<name>-backup/
cp -p /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak   # preserve timestamps

# Move/rename
mv /var/www/old-name/ /var/www/new-name/
mv /tmp/newfile.txt /var/www/<name>/newfile.txt

# Delete
rm /var/www/<name>/old-file.txt
rm -rf /var/www/<name>/node_modules/    # careful: no confirmation
# Safer delete (move to trash)
mkdir -p /tmp/deleted-$(date +%Y%m%d)
mv /var/www/<name>/suspicious-file.txt /tmp/deleted-$(date +%Y%m%d)/

# Secure delete (overwrite before deleting — for secrets)
shred -u /tmp/sensitive-file.txt        # overwrite + delete
```

---

## Compress & Archive

```bash
# ── tar.gz ─────────────────────────────────────────────────────────
# Create archive
tar -czf /tmp/<name>-backup.tar.gz /var/www/<name>/
# Create with date stamp
tar -czf "/var/backups/<name>-$(date +%Y%m%d_%H%M%S).tar.gz" /var/www/<name>/
# Extract to current dir
tar -xzf /tmp/<name>-backup.tar.gz
# Extract to specific dir
tar -xzf /tmp/<name>-backup.tar.gz -C /var/www/
# List contents without extracting
tar -tzf /tmp/<name>-backup.tar.gz | head -30
# Extract single file
tar -xzf archive.tar.gz ./path/to/specific/file

# ── zip ────────────────────────────────────────────────────────────
apt-get install -y zip unzip 2>/dev/null || dnf install -y zip unzip 2>/dev/null
# Create zip
zip -r /tmp/<name>.zip /var/www/<name>/
# Extract
unzip /tmp/<name>.zip -d /var/www/
# List contents
unzip -l /tmp/<name>.zip | head -30
# Extract single file
unzip archive.zip specific/file.txt

# ── gzip single file ───────────────────────────────────────────────
gzip /var/log/apps/<name>/app.log       # compress (replaces original)
gunzip /var/log/apps/<name>/app.log.gz  # decompress

# ── bzip2 ──────────────────────────────────────────────────────────
tar -cjf archive.tar.bz2 /path/        # slower but better compression
tar -xjf archive.tar.bz2

# ── Compress + stream directly to remote (no temp file) ───────────
tar -czf - /var/www/<name>/ | ssh user@remote "cat > /backup/<name>.tar.gz"
```

---

## File Transfer (Local ↔ Server)

```bash
# ── Upload: local → server ─────────────────────────────────────────
# Single file
scp -i <key> -P <port> /local/path/file.txt user@host:/remote/path/
# Directory
scp -i <key> -P <port> -r /local/dir/ user@host:/remote/dir/
# rsync (incremental, resume-able — preferred for large transfers)
rsync -avz --progress -e "ssh -i <key> -p <port>" \
  /local/dir/ user@host:/remote/dir/
# rsync with delete (mirror: removes files on server not in local)
rsync -avz --delete -e "ssh -i <key> -p <port>" \
  /local/dist/ user@host:/var/www/<name>/

# ── Download: server → local ───────────────────────────────────────
# Single file
scp -i <key> -P <port> user@host:/remote/path/file.txt /local/path/
# Directory
rsync -avz --progress -e "ssh -i <key> -p <port>" \
  user@host:/remote/dir/ /local/dir/
# Download backup
scp -i <key> -P <port> user@host:/var/backups/latest.tar.gz ~/Downloads/

# ── Download server logs for local analysis ────────────────────────
rsync -avz -e "ssh -i <key> -p <port>" \
  user@host:/var/log/nginx/ ./logs/nginx/
rsync -avz -e "ssh -i <key> -p <port>" \
  user@host:/var/log/apps/<name>/ ./logs/<name>/

# ── SFTP interactive session ───────────────────────────────────────
sftp -i <key> -P <port> user@host
# SFTP commands:
#   ls, cd, pwd, get file, put file, mget *.log, mput *.js, mkdir dir, rm file, exit
```

---

## Search in Files

```bash
# Search text in files (grep)
grep -r "ERROR" /var/log/apps/<name>/         # recursive text search
grep -rn "database_url" /var/www/<name>/       # with line numbers
grep -rl "password" /etc/ 2>/dev/null          # files containing "password"
grep -i "exception\|error\|fatal" /var/log/apps/<name>/app.log | tail -50

# ripgrep (faster, install: apt-get install -y ripgrep)
rg "ERROR" /var/log/apps/
rg -l "api_key" /var/www/<name>/    # list files only

# Search + replace across multiple files
grep -rl "old-domain.com" /etc/nginx/ | xargs sed -i 's/old-domain.com/new-domain.com/g'

# Find + grep combo
find /var/www -name "*.php" -exec grep -l "eval(" {} \;   # find PHP files with eval()
find /var/www -name "*.php" -newer /tmp/reference -ls      # recently changed PHP files
```

---

## Create Files & Directories

```bash
# Create directory tree
mkdir -p /var/www/<name>/public/assets/images
mkdir -p /var/log/apps/<name>

# Create file with content (heredoc)
cat > /etc/nginx/sites-available/<name> << 'EOF'
server {
    listen 80;
    server_name example.com;
    root /var/www/<name>;
}
EOF

# Create empty file / update timestamp
touch /var/www/<name>/index.html

# Create symlink
ln -sf /etc/nginx/sites-available/<name> /etc/nginx/sites-enabled/
ln -sf /opt/server-tools/service-registry.sh /usr/local/bin/registry

# Verify symlink
ls -la /etc/nginx/sites-enabled/<name>
readlink -f /etc/nginx/sites-enabled/<name>   # show real path
```

---

## File Integrity & Checksums

```bash
# Generate checksum (verify file integrity after transfer)
md5sum /tmp/myapp.jar                      # MD5
sha256sum /tmp/myapp.jar                   # SHA256 (preferred)
sha256sum /var/www/<name>/*.js > checksums.txt

# Verify against checksum file
sha256sum -c checksums.txt

# Compare two directories
diff -rq /var/www/<name>/ /var/www/<name>-backup/ 2>/dev/null

# Check if a file was modified vs git
cd /var/www/<name> && git status
git diff HEAD -- config/settings.py
```

---

## Useful File Locations Quick Reference

| What | Path |
|------|------|
| Nginx global config | `/etc/nginx/nginx.conf` |
| Nginx vhost configs | `/etc/nginx/sites-available/<name>` |
| Nginx error log | `/var/log/nginx/error.log` |
| App log directory | `/var/log/apps/<name>/` |
| Server index | `/etc/server-index.json` |
| Service registry | `/etc/server-registry.json` |
| SSL certificates | `/etc/letsencrypt/live/<domain>/` |
| Systemd units | `/etc/systemd/system/<name>.service` |
| Cron jobs | `/etc/cron.d/` and `crontab -l` |
| Fail2ban config | `/etc/fail2ban/jail.local` |
| SSH config | `/etc/ssh/sshd_config.d/` |
| Web files | `/var/www/<name>/` |
| Java apps | `/opt/java-apps/<name>/` |
| Python apps | `/opt/python-apps/<name>/` |
| Docker compose | `/opt/docker-apps/<name>/docker-compose.yml` |
| Environment files | `/var/www/<name>/.env` |
| Backups | `/var/backups/` |
| Server tools | `/opt/server-tools/` |
