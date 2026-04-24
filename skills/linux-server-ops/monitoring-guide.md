# Monitoring Guide

System and service monitoring setup for Linux servers.

---

## Quick Status Dashboard

Run this on any server for an instant health overview:

```bash
echo "========== SYSTEM =========="
uptime && free -h && df -h /
echo "========== PROCESSES ======="
ps aux --sort=-%cpu | head -10
echo "========== NETWORK =========="
ss -tlnp
echo "========== NGINX ============"
systemctl is-active nginx && nginx -t 2>&1
echo "========== PM2 =============="
pm2 status 2>/dev/null || echo "PM2 not running"
echo "========== SYSTEMD SERVICES ="
systemctl list-units --type=service --state=running --no-pager | grep -v systemd
echo "========== SSL CERTS ========"
certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:"
echo "========== ERRORS (24h) ====="
journalctl -p err --since "24h ago" --no-pager -n 20
```

---

## Service Health Checks

### Nginx

```bash
# Status
systemctl status nginx --no-pager
nginx -t                           # config test
curl -I http://localhost           # HTTP response

# Access / error logs
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/<name>-error.log

# Request rate per domain
awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
# Top IPs by request count
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
# 5xx errors in last 1000 requests
tail -1000 /var/log/nginx/access.log | awk '$9 ~ /^5/'
```

### Node.js (PM2)

```bash
pm2 status                         # all apps
pm2 info <name>                    # detailed info
pm2 logs <name> --lines 100        # recent logs
pm2 logs <name> --err --lines 50   # errors only
pm2 monit                          # live dashboard (interactive)
pm2 describe <name>                # full metadata

# Metrics
pm2 reset <name>                   # reset restart counter
pm2 flush <name>                   # clear logs

# Memory / CPU over time
pm2 logs <name> | grep -E "memory|cpu"
```

### Systemd Services (Java / Python)

```bash
systemctl status <name> --no-pager -l
journalctl -u <name> -f --no-pager          # follow logs
journalctl -u <name> --since "1h ago" --no-pager
journalctl -u <name> -p err --no-pager       # errors only

# Restart count
systemctl show <name> --property=NRestarts
# Last failure
systemctl show <name> --property=Result
```

### PHP-FPM

```bash
systemctl status php8.2-fpm --no-pager
# FPM status page (if configured)
curl http://127.0.0.1/php-fpm-status 2>/dev/null
# Slow requests log
tail -f /var/log/php8.2-fpm.log
```

---

## Resource Monitoring

### Real-time

```bash
htop                               # interactive CPU/memory/process view
iotop                              # disk I/O per process
nethogs                            # network usage per process
watch -n 2 'free -h && df -h /'   # memory + disk every 2s
```

### CPU & Memory Snapshots

```bash
# CPU usage summary
mpstat 1 5 2>/dev/null || vmstat 1 5

# Memory details
free -h
cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree"

# Top memory-consuming processes
ps aux --sort=-%mem | head -10

# OOM killer events
dmesg | grep -i "oom\|killed process" | tail -20
journalctl -k | grep -i "oom" | tail -20
```

### Disk

```bash
df -h                              # disk usage all mounts
df -h /                            # root partition
du -sh /var/www/*                  # web app sizes
du -sh /var/log/*                  # log sizes
du -sh /opt/*                      # opt dir sizes

# Find large files
find /var/log -name "*.log" -size +100M -ls 2>/dev/null
find /var/www -name "*.log" -size +50M -ls 2>/dev/null

# Disk I/O stats
iostat -xz 1 5 2>/dev/null || vmstat -d
```

### Network

```bash
ss -tlnp                           # listening ports
ss -s                              # socket summary
netstat -an | grep ESTABLISHED | wc -l   # active connections

# Bandwidth (if iftop/nload installed)
iftop -n 2>/dev/null
nload 2>/dev/null

# Install network tools
apt-get install -y iftop nload nethogs sysstat 2>/dev/null
```

---

## Log Management

### Logrotate Setup

Ensure `/etc/logrotate.d/apps` exists for app logs:

```bash
cat > /etc/logrotate.d/apps << 'LOGROTATE'
/var/log/apps/*/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        pm2 reloadLogs 2>/dev/null || true
    endscript
}

/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen 2>/dev/null || true
    endscript
}
LOGROTATE

# Test logrotate config
logrotate --debug /etc/logrotate.d/apps
```

### Clean up old logs manually

```bash
# Logs older than 30 days
find /var/log/apps -name "*.log*" -mtime +30 -delete
# Journald space usage
journalctl --disk-usage
journalctl --vacuum-size=500M    # keep only 500MB of journald logs
journalctl --vacuum-time=30d     # keep only last 30 days
```

---

## SSL Certificate Monitoring

```bash
# List all certs with expiry
certbot certificates

# Days until expiry for a domain
echo | openssl s_client -connect <domain>:443 -servername <domain> 2>/dev/null \
  | openssl x509 -noout -enddate

# Check all certs will renew (dry run)
certbot renew --dry-run

# Cert expiry check script (put in cron)
cat > /opt/server-tools/check-ssl.sh << 'SCRIPT'
#!/bin/bash
WARN_DAYS=30
for domain in $(certbot certificates 2>/dev/null | grep "Domains:" | awk '{print $2}'); do
  expiry=$(echo | openssl s_client -connect $domain:443 -servername $domain 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$expiry" ]; then
    days_left=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))
    echo "$domain: expires in $days_left days ($expiry)"
    if [ "$days_left" -lt "$WARN_DAYS" ]; then
      echo "WARNING: $domain cert expires in $days_left days!"
    fi
  fi
done
SCRIPT
chmod +x /opt/server-tools/check-ssl.sh
```

---

## Uptime & Process Auto-Restart

### PM2 auto-restart (Node.js)

PM2 restarts automatically on crash. Configure max restarts and memory:

```javascript
// ecosystem.config.js
{
  max_restarts: 10,
  min_uptime: "5s",         // don't count restart if dies within 5s
  max_memory_restart: "512M",
  restart_delay: 3000       // wait 3s before restart
}
```

### Systemd auto-restart (Java/Python)

Already set in the service unit with:

```ini
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=5           # max 5 restarts in 60s
```

### Watchdog cron (simple uptime check)

```bash
cat > /opt/server-tools/watchdog.sh << 'SCRIPT'
#!/bin/bash
# Simple watchdog — check and restart dead services
LOG="/var/log/watchdog.log"
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

check_nginx() {
  if ! systemctl is-active --quiet nginx; then
    echo "$(timestamp) nginx DOWN - restarting" >> $LOG
    systemctl restart nginx
  fi
}

check_pm2() {
  if ! pm2 status 2>/dev/null | grep -q "online"; then
    echo "$(timestamp) PM2 apps check failed" >> $LOG
    pm2 resurrect
  fi
}

check_service() {
  local name=$1
  if ! systemctl is-active --quiet $name; then
    echo "$(timestamp) $name DOWN - restarting" >> $LOG
    systemctl restart $name
  fi
}

check_nginx
check_pm2
# Add your services:
# check_service my-java-app
# check_service my-python-app
SCRIPT
chmod +x /opt/server-tools/watchdog.sh

# Run every 5 minutes
echo "*/5 * * * * root bash /opt/server-tools/watchdog.sh" > /etc/cron.d/watchdog
```

---

## Lightweight Monitoring Stack (Optional)

For production environments, install one of these:

### Option A: Netdata (real-time, beautiful UI)

```bash
curl https://my-netdata.io/kickstart.sh > /tmp/netdata-install.sh
bash /tmp/netdata-install.sh --non-interactive
# Access at http://<server-ip>:19999
# Secure with Nginx basic auth if public-facing
```

### Option B: Prometheus + Grafana

```bash
# Install Node Exporter (system metrics)
wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*linux-amd64.tar.gz -O /tmp/node_exporter.tar.gz
tar -xzf /tmp/node_exporter.tar.gz -C /tmp/
cp /tmp/node_exporter-*/node_exporter /usr/local/bin/
# Create systemd unit for node_exporter (binds to 9100)

# Prometheus and Grafana best installed via Docker:
# See deploy-guide.md Docker section
```

### Option C: Uptime Kuma (self-hosted uptime monitor)

```bash
# Run via Docker
docker run -d --restart=unless-stopped \
  -p 3001:3001 \
  -v /opt/uptime-kuma:/app/data \
  --name uptime-kuma \
  louislam/uptime-kuma:1
# Access at http://<server-ip>:3001
```

---

## Alerting

### Email alerts via cron (simple)

```bash
# Install mailutils
apt-get install -y mailutils 2>/dev/null || dnf install -y mailx 2>/dev/null

# High CPU alert (>90% for 5 min)
cat > /opt/server-tools/alert-cpu.sh << 'SCRIPT'
#!/bin/bash
THRESHOLD=90
EMAIL="admin@yourdomain.com"
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print 100-$8}' | cut -d. -f1)
if [ "$CPU" -gt "$THRESHOLD" ]; then
  echo "CPU at ${CPU}% on $(hostname) at $(date)" | \
    mail -s "ALERT: High CPU on $(hostname)" $EMAIL
fi
SCRIPT

# Disk full alert (>85%)
cat > /opt/server-tools/alert-disk.sh << 'SCRIPT'
#!/bin/bash
THRESHOLD=85
EMAIL="admin@yourdomain.com"
df -h | grep -vE "^Filesystem|tmpfs|udev" | awk '{print $5 " " $6}' | while read output; do
  usage=$(echo $output | awk '{print $1}' | cut -d% -f1)
  partition=$(echo $output | awk '{print $2}')
  if [ "$usage" -gt "$THRESHOLD" ]; then
    echo "Disk $partition at ${usage}% on $(hostname)" | \
      mail -s "ALERT: Disk full on $(hostname)" $EMAIL
  fi
done
SCRIPT
chmod +x /opt/server-tools/alert-*.sh

# Add to cron
echo "*/10 * * * * root bash /opt/server-tools/alert-cpu.sh" >> /etc/cron.d/alerts
echo "0 * * * * root bash /opt/server-tools/alert-disk.sh" >> /etc/cron.d/alerts
```

---

## Common Issues & Diagnosis

| Problem | Commands |
|---------|----------|
| High memory | `free -h`, `ps aux --sort=-%mem \| head -10` |
| High CPU | `top`, `ps aux --sort=-%cpu \| head -10` |
| Disk full | `df -h`, `du -sh /var/log/* /var/www/*` |
| App not responding | `curl -v http://localhost:<port>`, check service status |
| Nginx 502 | backend service down; `pm2 status` / `systemctl status <name>` |
| SSL expired | `certbot renew`, check `certbot.timer` |
| OOM kills | `dmesg \| grep -i oom`, increase server RAM or reduce app memory |
| Many TIME_WAIT | `ss -s`, tune `net.ipv4.tcp_fin_timeout` in `/etc/sysctl.conf` |
