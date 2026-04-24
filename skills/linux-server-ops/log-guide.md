# Log Management Guide

Viewing, searching, filtering, rotating, and aggregating logs across all services.

---

## Log Locations Quick Reference

| Service | Log Path |
|---------|---------|
| Nginx access | `/var/log/nginx/access.log` |
| Nginx error | `/var/log/nginx/error.log` |
| Per-app Nginx | `/var/log/nginx/<name>-{access,error}.log` |
| PM2 (Node.js) | `/var/log/apps/<name>/out.log` + `err.log` |
| Systemd services | `journalctl -u <name>` |
| PHP-FPM | `/var/log/php8.x-fpm.log` |
| MySQL | `/var/log/mysql/error.log` |
| PostgreSQL | `/var/log/postgresql/postgresql-*.log` |
| Redis | `/var/log/redis/redis-server.log` |
| fail2ban | `/var/log/fail2ban.log` |
| ModSecurity | `/var/log/nginx/modsec_audit.log` |
| SSH/auth | `/var/log/auth.log` (Debian) · `/var/log/secure` (RHEL) |
| Kernel/syslog | `/var/log/syslog` · `/var/log/messages` |
| UFW firewall | `/var/log/ufw.log` |
| App custom | `/var/log/apps/<name>/app.log` |
| Backup | `/var/log/backup.log` |
| Cron | `/var/log/cron.log` · `journalctl -u cron` |

---

## Real-time Log Viewing

```bash
# Follow a single log
tail -f /var/log/nginx/error.log
tail -f /var/log/apps/<name>/app.log
tail -f /var/log/apps/<name>/err.log

# Follow multiple logs simultaneously (requires multitail: apt-get install -y multitail)
multitail /var/log/nginx/error.log /var/log/apps/<name>/err.log

# Follow with grep filter (show only errors)
tail -f /var/log/nginx/access.log | grep " 5[0-9][0-9] "
tail -f /var/log/apps/<name>/app.log | grep -i "error\|exception\|fatal"

# PM2 live logs
pm2 logs <name>                    # all output
pm2 logs <name> --err --lines 100  # errors only
pm2 logs                           # all apps
pm2 flush <name>                   # clear logs (careful)

# systemd journal follow
journalctl -u <name> -f --no-pager
journalctl -u nginx -f --no-pager
# Follow all system logs
journalctl -f --no-pager
```

---

## Searching & Filtering Logs

### By time

```bash
# journalctl time filtering
journalctl -u <name> --since "2024-01-15 10:00:00" --until "2024-01-15 11:00:00"
journalctl -u <name> --since "1h ago" --no-pager
journalctl -u <name> --since "yesterday" --no-pager
journalctl --since "2024-01-15" --until "2024-01-16" --no-pager

# tail/grep by time (Nginx access log format: 15/Jan/2024:10)
grep "15/Jan/2024:10" /var/log/nginx/access.log | tail -100
grep "15/Jan/2024" /var/log/nginx/access.log | wc -l    # request count that day

# Find entries in last N minutes
awk -v d="$(date -d '30 minutes ago' '+%d/%b/%Y:%H:%M')" '$0 > d' \
  /var/log/nginx/access.log | tail -50
```

### By severity

```bash
# journalctl severity levels: emerg(0) alert(1) crit(2) err(3) warning(4) notice(5) info(6) debug(7)
journalctl -p err --since "24h ago" --no-pager        # errors and above
journalctl -p warning --since "1h ago" --no-pager     # warnings and above
journalctl -p err -u nginx --no-pager

# Nginx HTTP status codes
grep " 500 " /var/log/nginx/access.log | tail -20     # 500 errors
grep " 502 \| 503 \| 504 " /var/log/nginx/access.log | tail -20
awk '$9 ~ /^5/' /var/log/nginx/access.log | tail -50  # all 5xx
awk '$9 ~ /^4/' /var/log/nginx/access.log | tail -50  # all 4xx
```

### By keyword

```bash
# Search across all app logs
grep -r "NullPointerException" /var/log/apps/<name>/
grep -r "FATAL\|ERROR\|WARN" /var/log/apps/<name>/ | tail -50
grep -i "database\|connection refused\|timeout" /var/log/apps/<name>/app.log | tail -30

# Case-insensitive multi-pattern
grep -iE "exception|error|fail|critical" /var/log/apps/<name>/app.log | tail -50

# Exclude noisy lines
grep "ERROR" /var/log/apps/<name>/app.log | grep -v "health_check\|ping" | tail -30

# Context around match (3 lines before/after)
grep -C 3 "OutOfMemoryError" /var/log/apps/<name>/app.log | tail -60
```

### Analytics on access logs

```bash
# Top requested URLs
awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# Top IPs
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# HTTP status code distribution
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn

# Slowest requests (requires $request_time in log format)
awk '{print $NF, $7}' /var/log/nginx/access.log | sort -rn | head -20

# Bandwidth per IP (requires $body_bytes_sent)
awk '{bytes[$1]+=$10} END {for(ip in bytes) print bytes[ip], ip}' \
  /var/log/nginx/access.log | sort -rn | head -20

# Requests per minute (traffic pattern)
awk '{print $4}' /var/log/nginx/access.log \
  | cut -d: -f1-3 | sort | uniq -c | tail -60
```

---

## Log Rotation

### Check current logrotate config

```bash
ls /etc/logrotate.d/
cat /etc/logrotate.d/nginx
cat /etc/logrotate.d/apps    # custom app logs

# Test logrotate (dry run)
logrotate -d /etc/logrotate.d/apps
# Force rotation now
logrotate -f /etc/logrotate.d/apps
```

### Configure logrotate for app logs

```bash
cat > /etc/logrotate.d/apps << 'EOF'
/var/log/apps/*/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    dateext
    dateformat -%Y%m%d
    sharedscripts
    postrotate
        # Reload PM2 logs
        su - ubuntu -c 'pm2 reloadLogs' 2>/dev/null || true
        # Signal systemd services
        # systemctl kill -s USR1 myapp.service 2>/dev/null || true
    endscript
}

/var/log/apps/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
```

### Configure logrotate for Nginx

```bash
cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then
            run-parts /etc/logrotate.d/httpd-prerotate; fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1
    endscript
}
EOF
```

---

## Disk Space Management for Logs

```bash
# Check log disk usage
du -sh /var/log/*/ | sort -h
du -sh /var/log/apps/*/ | sort -h
du -sh /var/log/nginx/ /var/log/journal/ 2>/dev/null

# Journald disk usage + cleanup
journalctl --disk-usage
journalctl --vacuum-size=500M    # keep max 500MB
journalctl --vacuum-time=30d     # keep max 30 days
journalctl --vacuum-files=10     # keep max 10 rotated files

# Limit journald size permanently
cat >> /etc/systemd/journald.conf << 'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=30day
MaxFileSec=1week
EOF
systemctl restart systemd-journald

# Find and remove old compressed logs
find /var/log -name "*.gz" -mtime +60 -delete 2>/dev/null
find /var/log/apps -name "*.log.*" -mtime +30 -delete 2>/dev/null

# Truncate (not delete) a currently-open log
> /var/log/apps/<name>/app.log   # empty the file (service keeps writing)
```

---

## Centralized Log Viewing Script

```bash
cat > /opt/server-tools/show-logs.sh << 'SCRIPT'
#!/bin/bash
# show-logs.sh — Unified log viewer for all services
# Usage: bash show-logs.sh [service-name] [lines] [filter]
# Examples:
#   bash show-logs.sh                    # last errors from all services
#   bash show-logs.sh my-api 200         # last 200 lines from my-api
#   bash show-logs.sh my-api 100 ERROR   # filter for ERROR

SERVICE="${1:-all}"
LINES="${2:-100}"
FILTER="${3:-}"
LOG_DIR="/var/log/apps"

print_section() { echo ""; echo "━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

show_service_logs() {
  local name=$1
  print_section "$name"

  # PM2
  if pm2 describe "$name" &>/dev/null 2>&1; then
    echo "[PM2]"
    if [ -n "$FILTER" ]; then
      pm2 logs "$name" --lines "$LINES" --nostream 2>/dev/null | grep -i "$FILTER" | tail -"$LINES"
    else
      pm2 logs "$name" --lines "$LINES" --nostream 2>/dev/null | tail -"$LINES"
    fi
    return
  fi

  # File logs
  for logfile in "$LOG_DIR/$name/app.log" "$LOG_DIR/$name/out.log" "$LOG_DIR/$name/error.log" "$LOG_DIR/$name/err.log"; do
    [ -f "$logfile" ] || continue
    echo "[$(basename $logfile)]"
    if [ -n "$FILTER" ]; then
      tail -"$LINES" "$logfile" | grep -i "$FILTER"
    else
      tail -"$LINES" "$logfile"
    fi
  done

  # Systemd
  if systemctl list-units --type=service --no-pager 2>/dev/null | grep -q "$name"; then
    echo "[systemd]"
    if [ -n "$FILTER" ]; then
      journalctl -u "$name" --no-pager -n "$LINES" | grep -i "$FILTER"
    else
      journalctl -u "$name" --no-pager -n "$LINES"
    fi
  fi
}

if [ "$SERVICE" = "all" ]; then
  print_section "NGINX Errors (last 50)"
  tail -50 /var/log/nginx/error.log | grep -v "^$"

  print_section "System Errors (last 1h)"
  journalctl -p err --since "1h ago" --no-pager -n 50

  # All PM2 services
  pm2 jlist 2>/dev/null | python3 -m json.tool 2>/dev/null | grep '"name"' | \
    awk -F'"' '{print $4}' | while read name; do
    show_service_logs "$name"
  done

  # All app log directories
  for dir in "$LOG_DIR"/*/; do
    name=$(basename "$dir")
    show_service_logs "$name"
  done
else
  show_service_logs "$SERVICE"
fi
SCRIPT
chmod +x /opt/server-tools/show-logs.sh
```

---

## Error Summary Script

```bash
cat > /opt/server-tools/error-summary.sh << 'SCRIPT'
#!/bin/bash
# Quick error summary across all logs
SINCE="${1:-1h ago}"
echo ""
echo "════════════════════════════════════════"
echo "  Error Summary (since: $SINCE)"
echo "════════════════════════════════════════"

echo ""
echo "── System errors ──────────────────────"
journalctl -p err --since "$SINCE" --no-pager -n 20 2>/dev/null | \
  grep -v "^--" | tail -20

echo ""
echo "── Nginx errors ────────────────────────"
tail -200 /var/log/nginx/error.log 2>/dev/null | grep -v "^$" | tail -20

echo ""
echo "── 5xx HTTP responses ──────────────────"
awk '$9 ~ /^5/' /var/log/nginx/access.log 2>/dev/null | tail -20

echo ""
echo "── App errors ──────────────────────────"
find /var/log/apps -name "*.log" -newer /tmp/err-check-mark 2>/dev/null | \
  while read f; do
    errors=$(grep -ciE "error|exception|fatal" "$f" 2>/dev/null || echo 0)
    [ "$errors" -gt 0 ] && echo "  $f: $errors error lines"
  done

echo ""
echo "── fail2ban bans ───────────────────────"
grep "Ban " /var/log/fail2ban.log 2>/dev/null | tail -10

touch /tmp/err-check-mark
echo ""
SCRIPT
chmod +x /opt/server-tools/error-summary.sh
```

---

## Log Aggregation (Optional: Lightweight Stack)

### Option A: loki + promtail (lightweight, pairs with Grafana)

```bash
# Install promtail to ship logs to Grafana Cloud or self-hosted Loki
# See: https://grafana.com/docs/loki/latest/send-data/promtail/

# Promtail config (ship nginx + app logs)
cat > /etc/promtail/config.yml << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

clients:
  - url: http://localhost:3100/loki/api/v1/push   # local Loki
    # OR: url: https://<user>:<token>@logs-prod.grafana.net/loki/api/v1/push  # Grafana Cloud

scrape_configs:
  - job_name: nginx
    static_configs:
      - targets: [localhost]
        labels:
          job: nginx
          __path__: /var/log/nginx/*.log

  - job_name: apps
    static_configs:
      - targets: [localhost]
        labels:
          job: apps
          __path__: /var/log/apps/**/*.log
EOF
```

### Option B: GoAccess (terminal-based real-time Nginx log analyzer)

```bash
# Install
apt-get install -y goaccess 2>/dev/null || dnf install -y goaccess 2>/dev/null

# Interactive terminal report (live update)
goaccess /var/log/nginx/access.log --log-format=COMBINED

# Generate HTML report
goaccess /var/log/nginx/access.log \
  --log-format=COMBINED \
  --output /var/www/reports/nginx-report.html \
  --real-time-html

# Pipe compressed logs too
zcat /var/log/nginx/access.log.*.gz | goaccess - --log-format=COMBINED
```

---

## Cron Job Log Troubleshooting

```bash
# View cron execution log
grep CRON /var/log/syslog | tail -30                  # Ubuntu/Debian
journalctl -u cron --since "24h ago" --no-pager       # systemd
grep "CMD\|session opened for user root" /var/log/cron | tail -20  # RHEL

# Verify cron jobs ran
grep "backup.sh" /var/log/syslog | tail -10
cat /var/log/backup.log

# Debug: run cron script manually and capture output
bash /opt/server-tools/backup.sh > /tmp/cron-test.log 2>&1
cat /tmp/cron-test.log

# Check cron is running
systemctl status cron 2>/dev/null || systemctl status crond 2>/dev/null
```

---

## Log Security Auditing

```bash
# Check for suspicious log entries
echo "=== Failed SSH logins (top IPs) ==="
grep "Failed password" /var/log/auth.log 2>/dev/null \
  | grep -oP '(?<=from )\S+' | sort | uniq -c | sort -rn | head -10

echo "=== Successful logins ==="
grep "Accepted publickey\|Accepted password" /var/log/auth.log 2>/dev/null | tail -20

echo "=== sudo usage ==="
grep "sudo:" /var/log/auth.log 2>/dev/null | tail -20

echo "=== New user creation ==="
grep "useradd\|adduser" /var/log/auth.log 2>/dev/null | tail -10

echo "=== Nginx blocked by WAF/fail2ban ==="
grep -E "444|blocked|banned" /var/log/nginx/error.log 2>/dev/null | tail -10
fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,/\n/g' | while read jail; do
  jail=$(echo $jail | xargs)
  [ -z "$jail" ] && continue
  echo "[$jail] $(fail2ban-client status $jail 2>/dev/null | grep 'Total banned')"
done
```
