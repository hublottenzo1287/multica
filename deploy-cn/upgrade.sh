#!/usr/bin/env bash
# Multica 升级：先备份 → 拉取最新源码 → 重建 → 健康检查
#   bash deploy-cn/upgrade.sh [--project 名称] [--branch 分支，默认当前分支]
# 数据库迁移由后端启动时自动执行（健康检查含 migrations 项）；
# 若新版本迁移不可逆，回滚代码也救不回数据——所以升级前备份是硬步骤，失败即中止。
set -euo pipefail

PROJECT="multica"; BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
COMPOSE_FILES=(-f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml)
dc() { docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" "$@"; }
die() { echo "✗ $*" >&2; exit 1; }

[ -d .git ] || die "当前目录不是 git checkout，无法自动拉取升级；请手动更新源码后用 install.sh 重跑"
# 只拦已跟踪文件的改动：backups/、.env 等部署产物是未跟踪文件，不应挡住升级
# （首版没区分，实测中被自己生成的 backups/ 挡下——已修正）
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "工作区有未提交的源码改动，先处理（commit/stash）再升级，避免拉取冲突"
OLD=$(git rev-parse --short HEAD)
BRANCH=${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}

echo "==> 1/4 升级前备份"
bash deploy-cn/backup.sh --project "$PROJECT" || die "备份失败，升级中止（数据安全优先）"

echo "==> 2/4 拉取源码（分支 $BRANCH）"
git pull --ff-only origin "$BRANCH" || die "拉取失败：可能与远端分叉，先人工处理"
NEW=$(git rev-parse --short HEAD)
[ "$OLD" = "$NEW" ] && { echo "已是最新（$NEW），无需升级"; exit 0; }
echo "版本：$OLD → $NEW"

echo "==> 3/4 重建并启动"
dc up -d --build

echo "==> 4/4 健康检查"
BACKEND_PORT=$(grep -E "^BACKEND_PORT=" .env | tail -1 | cut -d= -f2); BACKEND_PORT=${BACKEND_PORT:-8080}
OK=""
for i in $(seq 1 60); do
  if curl -fs "http://localhost:$BACKEND_PORT/health" >/dev/null 2>&1; then OK=1; break; fi
  sleep 10
done
[ -n "$OK" ] || { dc logs --tail 50 backend; die "升级后后端未恢复健康。回滚：git checkout $OLD 后重跑本脚本；数据异常则用 backups/ 里升级前的备份恢复（见 README）"; }
echo "✓ 升级完成：$OLD → $NEW，后端健康（含数据库迁移状态）"
