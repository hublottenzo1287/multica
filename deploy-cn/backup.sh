#!/usr/bin/env bash
# Multica 备份：PostgreSQL 全量导出 + .env + 当前 compose 配置快照
#   bash deploy-cn/backup.sh [--project 名称] [--keep 份数，默认 14]
# 产物：<部署目录>/backups/multica-<项目>-<时间戳>/（.sql.gz / .env / compose-config.txt）
set -euo pipefail

PROJECT="multica"; KEEP=14
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
COMPOSE_FILES=(-f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml)
dc() { docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" "$@"; }

dc ps --status running | grep -q postgres || { echo "✗ 项目 $PROJECT 的 postgres 未在运行，先启动再备份" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
OUT="backups/multica-$PROJECT-$TS"
mkdir -p "$OUT"
echo "==> 导出数据库到 $OUT/db.sql.gz"
dc exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-multica}" "${POSTGRES_DB:-multica}"' | gzip > "$OUT/db.sql.gz"
gzip -t "$OUT/db.sql.gz" || { echo "✗ 备份文件校验失败" >&2; exit 1; }
cp .env "$OUT/.env" && chmod 600 "$OUT/.env"
dc config > "$OUT/compose-config.txt" 2>/dev/null || true
git rev-parse HEAD 2>/dev/null | sed 's/^/source_commit: /' > "$OUT/VERSION.txt" || true
SIZE=$(du -sh "$OUT" | cut -f1)
echo "✓ 备份完成：$OUT（$SIZE）"

# 只保留最近 KEEP 份
ls -dt backups/multica-"$PROJECT"-* 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  echo "清理旧备份：$old"; rm -rf "$old"
done
