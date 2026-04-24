# Linux Server Ops — AI Agent Skill

**语言 / Language**: [English](README.md) | 简体中文

---

一个 AI Agent Skill，将你的 AI 编程助手变成功能完整的 Linux 服务器管理面板——就像宝塔面板 / 1Panel，但完全由 AI 通过 SSH 驱动。

## 在 Claude Code 中安装

```bash
# 在 Claude Code 里运行:
/plugin marketplace add michael-ltm/linux-server-skill
/plugin install linux-server-skill@linux-server-skill
```

重启 Claude Code(或开新会话)。让 Agent 部署、监控、管理 Linux 服务器时,`linux-server-ops` skill 会自动加载。

| 操作 | 命令 |
|---|---|
| 更新 | `/plugin update linux-server-skill@linux-server-skill` |
| 卸载 | `/plugin uninstall linux-server-skill@linux-server-skill` |
| 查看状态 | `/plugin` |

## 功能一览

| 模块 | 能力 |
|------|------|
| **部署** | 静态网站、Node.js (PM2)、Java (systemd)、Python (Gunicorn/Uvicorn)、Go (systemd)、PHP (FPM)、Docker Compose |
| **域名 & SSL** | Nginx 虚拟主机自动生成、Let's Encrypt 自动签发 & 自动续签、通配符证书 |
| **数据库** | MySQL/MariaDB、PostgreSQL、Redis、MongoDB — 创建、管理、备份 |
| **Docker** | 容器管理、Compose 项目、私有镜像仓库、镜像管理 |
| **WAF & 防火墙** | ModSecurity + OWASP CRS、Nginx 速率限制、IP 黑白名单、fail2ban、UFW/firewalld |
| **监控** | 系统指标、PM2/systemd 健康检查、SSL 到期预警、进程守护、告警 |
| **日志** | 实时查看、按时间/级别/关键词搜索、logrotate、GoAccess、Loki |
| **文件** | 浏览、编辑、权限管理、压缩/解压、rsync 传输 |
| **用户** | Linux 用户、sudo 规则、SSH 密钥、SFTP chroot 账户 |
| **计划任务** | 查看、添加、调试 cron 任务 + systemd timers |
| **安全** | SSH 加固、内核调优、auditd 审计、入侵检测、备份 |
| **多服务器** | 管理任意数量的服务器；本地工作区上下文实现会话秒级恢复 |
| **服务控制** | 统一的 start/stop/restart/reload/enable/boot-check，自动识别服务类型 |

### 零 Token 浪费的会话记忆

Skill 维护两层上下文，新会话无需重复描述服务器环境：

- **服务器端** `/etc/server-index.json` — 由 `generate-index.sh` 自动扫描生成，包含所有已部署服务、数据库、Docker 容器、SSL 证书、用户、开放端口、WAF 状态等。
- **本地工作区** `.server/snapshots/<server-id>.json` — 由 `sync-context.sh` 拉取。新 AI 会话启动时，Agent 自动读取此文件，立刻了解整个服务器环境，无需再问。

---

## 支持的 Linux 发行版

| 发行版 | 包管理器 | Nginx 配置目录 | 初始化系统 |
|--------|---------|--------------|----------|
| Ubuntu 20.04 / 22.04 / 24.04 | apt | sites-available | systemd |
| Debian 11 / 12 | apt | sites-available | systemd |
| CentOS Stream 8/9 | dnf | conf.d | systemd |
| RHEL 8/9 | dnf | conf.d | systemd |
| Rocky Linux / AlmaLinux | dnf | conf.d | systemd |
| Fedora | dnf | conf.d | systemd |
| Alpine Linux | apk | http.d | OpenRC |
| Arch / Manjaro | pacman | conf.d | systemd |

---

## 安装

### 前提条件

- 本地环境：macOS 或 Linux
- 终端中可用 `ssh` 和 `scp`
- 本地安装 `jq`：`brew install jq`（macOS）· `apt-get install -y jq`（Linux）

### 方式一：Cursor（推荐）

**个人 Skill**（所有项目均可使用）：

```bash
# 首次安装和后续更新都用这一条命令，随时可以重复执行
git clone https://github.com/michael-ltm/linux-server-skill.git ~/.cursor/skills/linux-server-ops 2>/dev/null \
  || git -C ~/.cursor/skills/linux-server-ops pull origin main
```

**项目 Skill**（通过 git 与团队共享）：

```bash
mkdir -p .cursor/skills
git clone https://github.com/michael-ltm/linux-server-skill.git .cursor/skills/linux-server-ops 2>/dev/null \
  || git -C .cursor/skills/linux-server-ops pull origin main
```

重启 Cursor，Skill 自动被发现，无需额外配置。

### 方式二：Claude Code（claude.ai/code · Anthropic）

```bash
git clone https://github.com/michael-ltm/linux-server-skill.git ~/.claude/skills/linux-server-ops 2>/dev/null \
  || git -C ~/.claude/skills/linux-server-ops pull origin main
```

Claude Code 会话启动时自动读取 `~/.claude/skills/` 下的所有 Skill。

### 方式三：OpenClaw

```bash
git clone https://github.com/michael-ltm/linux-server-skill.git ~/.openclaw/skills/linux-server-ops 2>/dev/null \
  || git -C ~/.openclaw/skills/linux-server-ops pull origin main
```

或在 OpenClaw 设置面板中将 Skill 路径指向克隆后的目录。

### 方式四：其他 AI 编程助手（通用）

```bash
git clone https://github.com/michael-ltm/linux-server-skill.git /path/to/skills/linux-server-ops 2>/dev/null \
  || git -C /path/to/skills/linux-server-ops pull origin main
```

主入口文件是 `SKILL.md`，Agent 优先读取它，按需加载引用的各 guide 文件。

> **原理**：`git clone` 首次安装时成功执行；目录已存在时会报错但被 `2>/dev/null` 静默忽略，`||` 触发 `git pull` 自动更新。**一条命令，首次安装和后续更新通用。**

---

## 快速上手

### 第一步 — 添加第一台服务器

在项目工作区（你在 Cursor/Claude Code 中打开的目录）运行：

```bash
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh --add
```

交互式填写：
- 服务器 ID（如 `prod-web`）
- 主机 IP 或域名
- SSH 端口（默认 22）
- SSH 用户（如 `ubuntu`）
- 私钥路径（如 `~/.ssh/my_key`）

完成后会在工作区创建 `.server/servers.json`。

> **安全提示**：将 `.server/servers.json` 加入 `.gitignore`，该文件包含 SSH 连接信息，不要提交到 git。

```bash
echo ".server/servers.json" >> .gitignore
echo ".server/snapshots/" >> .gitignore
```

### 第二步 — 同步服务器状态

```bash
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh
```

脚本会连接服务器，执行全量扫描，将快照保存到 `.server/snapshots/prod-web.json`。

输出示例：
```
→ 正在同步: prod-web (ubuntu@1.2.3.4:22)
✓ SSH 连接成功
→ 正在扫描服务器（约需 10 秒）...
✓ 快照已保存: .server/snapshots/prod-web.json

快照摘要: prod-web
  主机:        web-01 (1.2.3.4)
  系统:        Ubuntu 22.04
  内存:         8.0Gi  磁盘: 12G/100G (12%)

  网站:    2
  服务:    3
  数据库:   2 个引擎
  SSL 证书:  2
  Docker:   4 个容器
```

### 第三步 — 初始化服务器（仅首次）

上传并运行初始化脚本，自动安装 Nginx、Certbot、fail2ban、防火墙及所有依赖：

```bash
# 上传脚本
scp -i ~/.ssh/my_key ~/.cursor/skills/linux-server-ops/scripts/check-system.sh ubuntu@1.2.3.4:/tmp/
scp -i ~/.ssh/my_key ~/.cursor/skills/linux-server-ops/scripts/generate-index.sh ubuntu@1.2.3.4:/tmp/
scp -i ~/.ssh/my_key ~/.cursor/skills/linux-server-ops/scripts/service-registry.sh ubuntu@1.2.3.4:/tmp/
scp -i ~/.ssh/my_key ~/.cursor/skills/linux-server-ops/scripts/service-control.sh ubuntu@1.2.3.4:/tmp/

# 执行初始化
ssh -i ~/.ssh/my_key ubuntu@1.2.3.4 'sudo bash /tmp/check-system.sh'

# 安装管理脚本到服务器
ssh -i ~/.ssh/my_key ubuntu@1.2.3.4 \
  'sudo mkdir -p /opt/server-tools && \
   sudo mv /tmp/generate-index.sh /tmp/service-registry.sh /tmp/service-control.sh /opt/server-tools/ && \
   sudo chmod +x /opt/server-tools/*.sh'
```

### 第四步 — 开始使用

在工作区打开新的 Cursor / Claude Code 会话，AI Agent 会自动读取 `.server/snapshots/prod-web.json`，立刻了解整个服务器环境。

直接用自然语言提问：

```
帮我把 ./dist 里的 React 项目部署到服务器，绑定 blog.example.com 并开启 SSL
用 PM2 在 3000 端口启动一个 Node.js 服务
查看所有服务的运行状态
API 返回 502，帮我排查一下
创建一个 SFTP 用户，让客户能上传文件到 /var/www/mysite
帮我配置 ModSecurity WAF 和 OWASP 规则集
封禁这个 IP：1.2.3.4
查看最近一小时的 Nginx 错误日志
添加一个每天凌晨 3 点执行的备份 cron 任务
创建一个 MySQL 数据库和专用用户
查看所有服务的开机自启状态，有没有哪个没配置
重启 my-api 服务
```

---

## 服务控制速查

`service-control.sh` 自动识别服务类型（PM2 / systemd / Docker Compose / Nginx），统一接口：

```bash
# 查看所有服务状态（含开机自启标志）
bash /opt/server-tools/service-control.sh status

# 查看单个服务详情
bash /opt/server-tools/service-control.sh status <服务名>

# 启动 / 停止 / 重启 / 优雅重载（零停机）
bash /opt/server-tools/service-control.sh start   <服务名>
bash /opt/server-tools/service-control.sh stop    <服务名>
bash /opt/server-tools/service-control.sh restart <服务名>
bash /opt/server-tools/service-control.sh reload  <服务名>   # 0 停机

# 开机自启管理
bash /opt/server-tools/service-control.sh boot-check    # 检查所有服务是否配置了自启
bash /opt/server-tools/service-control.sh boot-fix      # 一键修复所有未配置自启的服务
bash /opt/server-tools/service-control.sh enable <服务名>  # 开启单个服务自启

# 查看日志
bash /opt/server-tools/service-control.sh logs <服务名> 200
```

**reload vs restart 区别：**

| 类型 | reload（优雅重载）| restart（重启）|
|------|-----------------|---------------|
| PM2 (Node.js) | 集群模式滚动重载，0 停机 | 硬重启，短暂中断 |
| systemd (Java/Python/Go) | 发送 SIGHUP（应用须支持），不支持则回退到 restart | 完整进程重启 |
| Nginx | 配置热重载，0 停机 | 完整重启 |
| Docker Compose | 回退到 restart | 重建容器 |

---

## 开机自动启动说明

所有服务类型均支持开机自动启动，部署时自动配置：

| 服务类型 | 开机自启命令 | 验证 |
|---------|------------|------|
| 静态网站 / Nginx | `systemctl enable nginx` | `systemctl is-enabled nginx` |
| Node.js (PM2) | `pm2 startup` → 执行打印命令 → `pm2 save` | `pm2 list`（重启后检查） |
| Java | `systemctl enable <服务名>` | `systemctl is-enabled <服务名>` |
| Python | `systemctl enable <服务名>` | `systemctl is-enabled <服务名>` |
| Go | `systemctl enable <服务名>` | `systemctl is-enabled <服务名>` |
| PHP-FPM | `systemctl enable php<版本>-fpm` | `systemctl is-enabled php<版本>-fpm` |
| Docker Compose | compose.yml 中设置 `restart: unless-stopped` | `docker inspect <容器名>` |

> 批量验证：`bash /opt/server-tools/service-control.sh boot-check`

---

## 工作区文件结构

初始化完成后，工作区目录结构如下：

```
你的项目/
├── .server/
│   ├── servers.json          ← SSH 配置（务必加入 .gitignore）
│   └── snapshots/
│       ├── prod-web.json     ← 生产服务器状态快照
│       └── staging.json      ← 测试服务器状态快照
└── .gitignore                ← 必须包含 .server/servers.json
```

### `servers.json` 格式

```json
{
  "default": "prod-web",
  "servers": {
    "prod-web": {
      "label": "生产 Web 服务器",
      "host": "1.2.3.4",
      "port": 22,
      "user": "ubuntu",
      "key_path": "~/.ssh/prod_key",
      "tags": ["production", "web"],
      "snapshot": ".server/snapshots/prod-web.json"
    }
  }
}
```

### 管理多台服务器

```bash
# 添加另一台服务器
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh --add

# 列出所有已配置服务器
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh --list

# 同步所有服务器
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh --all

# 同步指定服务器
bash ~/.cursor/skills/linux-server-ops/scripts/sync-context.sh staging
```

---

## 脚本参考

### 本地脚本（在你的电脑上运行）

| 脚本 | 用途 |
|------|------|
| `sync-context.sh --add` | 交互式添加服务器到工作区 |
| `sync-context.sh [id]` | 拉取服务器状态到本地快照 |
| `sync-context.sh --all` | 同步所有已配置服务器 |
| `sync-context.sh --list` | 列出所有已配置服务器 |
| `sync-context.sh --show [id]` | 打印快照详情 |

### 服务器端脚本（上传至 `/opt/server-tools/`）

| 脚本 | 用途 |
|------|------|
| `check-system.sh` | 初始化：在全新服务器上安装所有依赖 |
| `generate-index.sh` | 全量扫描服务器并写入 `/etc/server-index.json` |
| `generate-index.sh --print` | 扫描并只输出 JSON（供 sync-context.sh 调用） |
| `service-registry.sh list` | 列出所有已注册服务 |
| `service-registry.sh health` | 健康检查所有服务 + 数据库 + Docker |
| `service-registry.sh db` | 数据库状态（MySQL / PostgreSQL / Redis / MongoDB） |
| `service-registry.sh docker` | Docker 容器 + Compose 项目 |
| `service-registry.sh cron` | 所有计划任务 |
| `service-registry.sh summary` | 服务器完整摘要 |
| `service-registry.sh set <名称> '{...}'` | 添加/更新服务条目 |
| `service-control.sh status [名称]` | 查看所有或单个服务状态（含开机自启标志） |
| `service-control.sh restart <名称>` | 重启服务（自动识别类型） |
| `service-control.sh reload <名称>` | 优雅重载（零停机） |
| `service-control.sh start/stop <名称>` | 启动或停止服务 |
| `service-control.sh enable <名称>` | 开启开机自动启动 |
| `service-control.sh boot-check` | 验证所有服务是否配置了开机自启 |
| `service-control.sh boot-fix` | 一键修复所有未配置开机自启的服务 |
| `service-control.sh logs <名称> [n]` | 查看最后 N 行日志 |

---

## 文档参考

| 文件 | 内容 |
|------|------|
| `SKILL.md` | 主入口 — 所有功能与命令速查 |
| `distro-guide.md` | Ubuntu / Debian / CentOS / RHEL / Alpine / Arch 差异对比 |
| `deploy-guide.md` | 完整部署流程：静态网站、Node.js、Java、Python、Go、PHP、Docker、数据库 |
| `waf-guide.md` | ModSecurity、OWASP CRS、速率限制、IP 管理、DDoS 防护 |
| `monitoring-guide.md` | 系统指标、告警、Netdata、Uptime Kuma、进程守护 |
| `log-guide.md` | 日志查看、搜索、轮转、GoAccess、Loki/Promtail |
| `file-ops-guide.md` | 文件管理：浏览、编辑、权限、压缩、传输、搜索 |
| `security-guide.md` | SSH 加固、auditd、内核调优、入侵检测、备份 |
| `user-management-guide.md` | 用户、组、sudo、SSH 密钥、SFTP chroot、会话审计 |

---

## 安全说明

- **永远不要提交 `servers.json`** — 它包含 SSH 连接凭据
- 服务器端索引 `/etc/server-index.json` 以 `chmod 600`（仅 root 可读）存储
- 所有通过本 Skill 部署的 `.env` 文件均设置为 `chmod 600`
- 服务器加固过程中会禁用 SSH 密码登录，强制使用密钥认证
- SFTP 用户被 chroot 隔离在各自的 Web 目录中，无法访问系统其他路径

---

## License

MIT — 可自由使用、修改和分发。
