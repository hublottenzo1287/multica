#!/usr/bin/env bash
# Multica 一键部署（国内网络适配版）
#
# 在当前 checkout 内从源码构建并启动一套 Multica：
#   bash deploy-cn/install.sh [--project 名称] [--frontend-port 端口] [--backend-port 端口]
#
# 设计原则：只编排官方 selfhost 机制（docker-compose.selfhost.yml + .build.yml），
# 本脚本负责官方流程之外的四件事：环境预检、Docker 镜像源、.env 密钥与隐私默认值、
# 健康等待与结果汇总。可重复运行：已部署时只报告状态并提示用 upgrade.sh 升级。
set -euo pipefail

PROJECT="multica"
FRONTEND_PORT=""
BACKEND_PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --frontend-port) FRONTEND_PORT="$2"; shift 2 ;;
    --backend-port) BACKEND_PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
START_TS=$(date +%s)
step() { echo; echo "==> [$(( $(date +%s) - START_TS ))s] $*"; }
die() { echo "✗ $*" >&2; exit 1; }

COMPOSE_FILES=(-f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml)
dc() { docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" "$@"; }

# ---------- 1. 预检 ----------
step "环境预检"
[ "$(uname -s)" = "Linux" ] || die "仅支持 Linux 主机"
command -v openssl >/dev/null || die "缺少 openssl（生成密钥用），先装：sudo apt-get install -y openssl"

if ! command -v docker >/dev/null; then
  echo "未检测到 Docker，尝试自动安装（官方脚本 + 阿里云镜像）…"
  if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    curl -fsSL https://get.docker.com | sudo sh -s -- --mirror Aliyun \
      || die "Docker 自动安装失败，请手动安装 Docker Engine 24+ 与 Compose v2 后重跑"
    sudo systemctl enable --now docker 2>/dev/null || true
  else
    die "无 Docker 且无免密 sudo，无法自动安装。请先装 Docker Engine 24+ 与 Compose v2 插件后重跑"
  fi
fi
docker compose version >/dev/null 2>&1 || die "缺少 Docker Compose v2 插件"
docker info >/dev/null 2>&1 || die "Docker 守护进程未运行或当前用户无权限（试试把用户加入 docker 组后重新登录）"

# 阶段 2 教训：构建缓存先进临时目录，/tmp 太小会报出与主盘无关的假象错误
TMP_FREE_MB=$(df -Pm /tmp | awk 'NR==2 {print $4}')
[ "${TMP_FREE_MB:-0}" -ge 5120 ] || echo "⚠ /tmp 可用空间 ${TMP_FREE_MB}MB < 5GB：Docker 构建一般不受影响，但本机本地构建（Go 等）会踩坑，建议清理或扩容"
DISK_FREE_GB=$(df -PG . | awk 'NR==2 {print $4}')
[ "${DISK_FREE_GB:-0}" -ge 10 ] || die "安装目录可用空间不足 10GB（当前 ${DISK_FREE_GB}GB）"
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
[ "${MEM_GB:-0}" -ge 4 ] || echo "⚠ 内存 ${MEM_GB}GB < 4GB：前端构建可能吃紧，建议 8GB 以上"

if dc ps --status running 2>/dev/null | grep -q backend; then
  echo "项目 $PROJECT 已在运行，本次不重复部署。升级请用 deploy-cn/upgrade.sh；状态："
  dc ps
  exit 0
fi

# ---------- 2. Docker 镜像源（国内网络） ----------
step "检查 Docker 镜像源"
if [ -f /etc/docker/daemon.json ] && grep -q "registry-mirrors" /etc/docker/daemon.json; then
  echo "已配置 registry-mirrors，跳过"
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
  [ -f /etc/docker/daemon.json ] && sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  printf '%s\n' '{"registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run"]}' \
    | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
  echo "已写入镜像源（daocloud + 1ms.run）并重启 Docker"
else
  echo "⚠ 未配置镜像源且无免密 sudo：直连 Docker Hub 在国内网络常超时。"
  echo "  如拉取失败，请手动在 /etc/docker/daemon.json 配置 registry-mirrors 后重跑（见 deploy-cn/README.md）"
fi

# ---------- 3. .env：密钥与默认值 ----------
step "准备 .env"
if [ ! -f .env ]; then
  cp .env.example .env
  JWT=$(openssl rand -hex 32); PGPASS=$(openssl rand -hex 24); VCSKEY=$(openssl rand -base64 32)
  sed -i "s/^JWT_SECRET=.*/JWT_SECRET=$JWT/" .env
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$PGPASS/" .env
  sed -i "s#^MULTICA_VCS_SECRET_KEY=.*#MULTICA_VCS_SECRET_KEY=$VCSKEY#" .env
  echo "已生成随机 JWT_SECRET / POSTGRES_PASSWORD / MULTICA_VCS_SECRET_KEY"
fi
# 隐私默认：关闭遥测（幂等；已有明确取值则尊重）
if grep -q "^DO_NOT_TRACK=" .env; then
  sed -i "s/^DO_NOT_TRACK=.*/DO_NOT_TRACK=1/" .env
else
  echo "DO_NOT_TRACK=1" >> .env
fi
[ -n "$FRONTEND_PORT" ] && { grep -q "^FRONTEND_PORT=" .env && sed -i "s/^FRONTEND_PORT=.*/FRONTEND_PORT=$FRONTEND_PORT/" .env || echo "FRONTEND_PORT=$FRONTEND_PORT" >> .env; }
[ -n "$BACKEND_PORT" ] && { grep -q "^BACKEND_PORT=" .env && sed -i "s/^BACKEND_PORT=.*/BACKEND_PORT=$BACKEND_PORT/" .env || echo "BACKEND_PORT=$BACKEND_PORT" >> .env; }
chmod 600 .env
FRONTEND_PORT=$(grep -E "^FRONTEND_PORT=" .env | tail -1 | cut -d= -f2); FRONTEND_PORT=${FRONTEND_PORT:-3000}
BACKEND_PORT=$(grep -E "^BACKEND_PORT=" .env | tail -1 | cut -d= -f2); BACKEND_PORT=${BACKEND_PORT:-8080}
for p in "$FRONTEND_PORT" "$BACKEND_PORT"; do
  if (command -v ss >/dev/null && ss -ltn | grep -q ":$p ") || (command -v netstat >/dev/null && netstat -ltn | grep -q ":$p "); then
    die "端口 $p 已被占用，换端口重跑（如 --frontend-port $((p+1000))）或先停掉占用进程"
  fi
done
echo ".env 就绪（权限 600）：前端端口 $FRONTEND_PORT，后端端口 $BACKEND_PORT，DO_NOT_TRACK=1"

# ---------- 4. 构建并启动 ----------
step "构建镜像并启动（源码构建，首次约 5–15 分钟，含国内源适配）"
dc up -d --build

# ---------- 5. 健康等待 ----------
step "等待服务健康"
OK=""
for i in $(seq 1 60); do
  if curl -fs "http://localhost:$BACKEND_PORT/health" >/dev/null 2>&1; then OK=1; break; fi
  sleep 10
done
[ -n "$OK" ] || { dc ps; dc logs --tail 50 backend; die "后端 10 分钟内未通过健康检查，日志见上"; }
FE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$FRONTEND_PORT/" || true)
[ "$FE_CODE" = "200" ] || echo "⚠ 前端返回 $FE_CODE（后端已健康，前端可能还在启动，稍后刷新试试）"

# ---------- 6. 汇总 ----------
ELAPSED=$(( $(date +%s) - START_TS ))
step "部署完成，用时 ${ELAPSED}s"
dc ps
cat <<EOF

  前端（登录入口）: http://localhost:$FRONTEND_PORT
  后端健康检查:     http://localhost:$BACKEND_PORT/health
  首次使用: 打开前端注册账号；自托管默认无邮件服务时，验证码在数据库
            verification_code 表中（交付场景请先配好发信，见 README）。
  密钥文件: $ROOT_DIR/.env（权限 600，含数据库密码与 JWT 密钥，切勿外传或提交 Git）
  日常运维: 备份 deploy-cn/backup.sh ｜ 升级 deploy-cn/upgrade.sh ｜ 日志 dc logs -f
EOF
