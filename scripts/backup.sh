#!/usr/bin/env bash
#  逻辑备份：pg_dump -Fc → pg_restore 校验 → 轮转（BACKUP_KEEP，默认 14）
#  先写 .part 再改名，失败不会留下 0 字节的假备份
#  用法：bash scripts/backup.sh [输出目录]
set -euo pipefail

OUT_DIR="${1:-./backups}"
KEEP="${BACKUP_KEEP:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

TARGET="$OUT_DIR/roomdesk-$STAMP.dump"
SNAP="${TARGET%.dump}.schema.sql"
PART_DUMP="$TARGET.part"
PART_SNAP="$SNAP.part"

# 容器内执行（compose 注入 PGHOST）还是宿主机执行（借 db 容器的 pg_dump）
IN_CONTAINER=0
if [ -n "${PGHOST:-}" ] && command -v pg_dump >/dev/null 2>&1; then IN_CONTAINER=1; fi

dump() {   # $1 = custom | schema-only,  $2 = 目标文件
  if [ "$IN_CONTAINER" = "1" ]; then
    if [ "$1" = "custom" ]; then
      pg_dump --format=custom --no-owner --no-privileges --file="$2"
    else
      pg_dump --schema-only --no-owner --no-privileges --file="$2"
    fi
  else
    if [ "$1" = "custom" ]; then
      docker compose exec -T db sh -lc \
        'pg_dump --format=custom --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$2"
    else
      docker compose exec -T db sh -lc \
        'pg_dump --schema-only --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$2"
    fi
  fi
}

verify() {  # 能列出内容才算有效备份
  if [ "$IN_CONTAINER" = "1" ] && command -v pg_restore >/dev/null 2>&1; then
    pg_restore --list "$1" > /dev/null
  else
    docker compose exec -T db pg_restore --list < "$1" > /dev/null
  fi
}

fail() {
  rm -f "$PART_DUMP" "$PART_SNAP"
  echo "[FAIL] $1"
  exit 1
}

echo "== 备份到 $OUT_DIR（保留最近 $KEEP 份）"

if find "$OUT_DIR" -maxdepth 1 -name 'roomdesk-*.dump' -size 0 -print -delete 2>/dev/null | grep -q .; then
  echo "   已清理 0 字节的空备份"
fi

echo "   pg_dump ..."
dump custom "$PART_DUMP" || fail "pg_dump 失败（看 db 是否存活、账号是否有权限）"
[ -s "$PART_DUMP" ] || fail "dump 文件为空"

echo "   校验 dump 可读 ..."
verify "$PART_DUMP" || fail "pg_restore --list 读不了，备份无效"
mv "$PART_DUMP" "$TARGET"

dump schema-only "$PART_SNAP" || fail "结构快照生成失败"
[ -s "$PART_SNAP" ] || fail "结构快照为空"
mv "$PART_SNAP" "$SNAP"

mapfile -t dumps < <(ls -1t "$OUT_DIR"/roomdesk-*.dump 2>/dev/null || true)
if [ "${#dumps[@]}" -gt "$KEEP" ]; then
  for old in "${dumps[@]:$KEEP}"; do
    rm -f "$old" "${old%.dump}.schema.sql"
    echo "   轮转删除 $(basename "$old")"
  done
fi

echo ""
ls -lh "$TARGET" "$SNAP"
echo "现有备份 $(ls -1 "$OUT_DIR"/roomdesk-*.dump 2>/dev/null | wc -l) 份，最新：$(basename "$TARGET")"
