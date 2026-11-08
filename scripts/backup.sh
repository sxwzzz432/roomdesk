#!/usr/bin/env bash
# ============================================================
#  逻辑备份：pg_dump -Fc + **成功校验** + **轮转清理**
#
#  用法：
#    bash scripts/backup.sh [输出目录]
#
#  环境变量：
#    BACKUP_KEEP   保留最近多少份（默认 14）
#    PGHOST 等     backup 容器里由 compose 注入；宿主机执行则走 docker compose exec
#
#  为什么不是简单一句 pg_dump：
#    1. 先写 .part，校验通过才改名 —— 失败不会留下 0 字节的"假备份"
#    2. 用 pg_restore --list 读一遍 —— 文件能打开才算有效
#    3. 轮转只保留最近 N 份 —— 否则每小时一份，几天后磁盘就满了
# ============================================================
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

# ---------- 0. 清掉历史遗留的空文件（以前的失败产物） ----------
if find "$OUT_DIR" -maxdepth 1 -name 'roomdesk-*.dump' -size 0 -print -delete 2>/dev/null | grep -q .; then
  echo "   已清理 0 字节的空备份"
fi

# ---------- 1. dump 到 .part ----------
echo "   pg_dump ..."
dump custom "$PART_DUMP" || fail "pg_dump 失败（看 db 是否存活、账号是否有权限）"
[ -s "$PART_DUMP" ] || fail "dump 文件为空"

# ---------- 2. 校验 ----------
echo "   校验 dump 可读 ..."
verify "$PART_DUMP" || fail "pg_restore --list 读不了，备份无效"
mv "$PART_DUMP" "$TARGET"

# ---------- 3. 结构快照（方便 diff / code review） ----------
dump schema-only "$PART_SNAP" || fail "结构快照生成失败"
[ -s "$PART_SNAP" ] || fail "结构快照为空"
mv "$PART_SNAP" "$SNAP"

# ---------- 4. 轮转：只留最近 KEEP 份 ----------
mapfile -t dumps < <(ls -1t "$OUT_DIR"/roomdesk-*.dump 2>/dev/null || true)
if [ "${#dumps[@]}" -gt "$KEEP" ]; then
  for old in "${dumps[@]:$KEEP}"; do
    rm -f "$old" "${old%.dump}.schema.sql"
    echo "   轮转删除 $(basename "$old")"
  done
fi

# ---------- 5. 汇总 ----------
echo ""
ls -lh "$TARGET" "$SNAP"
echo "现有备份 $(ls -1 "$OUT_DIR"/roomdesk-*.dump 2>/dev/null | wc -l) 份，最新：$(basename "$TARGET")"
