#!/usr/bin/env bash
# 从 pg_dump 自定义格式恢复（会先清空已有对象）
# 用法：bash scripts/restore.sh backups/roomdesk-20250101-120000.dump
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "用法：bash scripts/restore.sh <备份文件.dump>" >&2
  exit 1
fi

DUMP="$1"
[ -f "$DUMP" ] || { echo "找不到备份文件：$DUMP" >&2; exit 1; }

docker compose exec -T db sh -lc '
  set -e
  pg_restore --clean --if-exists --no-owner --no-privileges \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc - < /dev/stdin
' < "$DUMP"

echo "恢复完成，验证一下："
docker compose exec -T db sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
     SELECT (SELECT count(*) FROM rooms)    AS rooms,
            (SELECT count(*) FROM staff)    AS staff,
            (SELECT count(*) FROM bookings) AS bookings;"'
