#!/usr/bin/env bash
# ============================================================
#  数据库初始化 / 迁移
#
#  两种用法：
#    容器内（compose 的 migrator 服务）：PGHOST=db 由 compose 注入
#    宿主机（不用 Docker 时）：          PGHOST=127.0.0.1 SUPERUSER_USER=postgres ...
#
#  流程：
#    1) 等数据库可连
#    2) bootstrap.sql   —— 超级用户：扩展 / 角色 / schema / schema 级权限
#    3) migrations/*.sql —— roomdesk_migrator：表、视图、物化视图、函数、授权
#       （每个迁移一个事务，执行记录写进 roomdesk.schema_migrations）
#    4) seed.sql        —— 库为空时灌演示数据
#
#  幂等：重复执行只会 apply 还没执行过的迁移。
# ============================================================
set -euo pipefail

: "${PGHOST:=db}"
: "${PGPORT:=5432}"
: "${DB_NAME:=roomdesk}"

: "${SUPERUSER_USER:=roomdesk}"          # 容器里 POSTGRES_USER 就是超级用户
: "${SUPERUSER_PASSWORD:=roomdesk}"
: "${MIGRATOR_USER:=roomdesk_migrator}"
: "${MIGRATOR_PASSWORD:=migrator_pw}"
: "${APP_USER:=roomdesk_app}"
: "${APP_PASSWORD:=app_pw}"
: "${READER_USER:=roomdesk_reader}"
: "${READER_PASSWORD:=reader_pw}"
: "${SEED:=1}"

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PSQL_VARS=(
  -v app_user="$APP_USER"           -v app_password="$APP_PASSWORD"
  -v migrator_user="$MIGRATOR_USER" -v migrator_password="$MIGRATOR_PASSWORD"
  -v reader_user="$READER_USER"     -v reader_password="$READER_PASSWORD"
  -v db_name="$DB_NAME"
)

psql_super() {
  PGPASSWORD="$SUPERUSER_PASSWORD" psql -X -q -h "$PGHOST" -p "$PGPORT" \
    -U "$SUPERUSER_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "${PSQL_VARS[@]}" "$@"
}
psql_migrator() {
  PGPASSWORD="$MIGRATOR_PASSWORD" psql -X -q -h "$PGHOST" -p "$PGPORT" \
    -U "$MIGRATOR_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "${PSQL_VARS[@]}" "$@"
}

echo "== 等待数据库 ${PGHOST}:${PGPORT} ..."
for _ in $(seq 1 60); do
  if pg_isready -h "$PGHOST" -p "$PGPORT" -q; then break; fi
  sleep 1
done
pg_isready -h "$PGHOST" -p "$PGPORT"

echo
echo "== 1/3 bootstrap（超级用户）：扩展 / 角色 / schema / 权限"
psql_super -f "$ROOT_DIR/db/bootstrap.sql"

echo
echo "== 2/3 迁移（${MIGRATOR_USER}）"
psql_migrator -c "CREATE TABLE IF NOT EXISTS schema_migrations (
                      version    text PRIMARY KEY,
                      applied_at timestamptz NOT NULL DEFAULT now());" >/dev/null

APPLIED=0
SKIPPED=0
for f in $(ls "$ROOT_DIR"/db/migrations/*.sql | sort); do
  v="$(basename "$f")"
  done_already="$(psql_migrator -tAc "SELECT 1 FROM schema_migrations WHERE version = '${v}'")"
  if [ -n "$done_already" ]; then
    echo "   skip   $v"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  echo "   apply  $v"
  # -1：整个文件 + 记账放进同一个事务，失败自动回滚
  psql_migrator -1 \
    -c "INSERT INTO schema_migrations (version) VALUES ('${v}')" \
    -f "$f"
  APPLIED=$((APPLIED + 1))
done
echo "   新增 ${APPLIED} 个，跳过 ${SKIPPED} 个"

echo
echo "== 3/3 演示数据"
if [ "$SEED" = "1" ]; then
  n="$(psql_migrator -tAc "SELECT count(*) FROM rooms" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -eq 0 ]; then
    psql_migrator -f "$ROOT_DIR/db/seed/seed.sql"
    echo "   已灌入演示数据"
  else
    echo "   已有数据（rooms=${n}），跳过 seed"
  fi
else
  echo "   SEED=0，跳过"
fi

echo
echo "== 结果"
psql_migrator -c "SELECT version, applied_at FROM schema_migrations ORDER BY version;"
psql_migrator -tA -c "SELECT 'rooms=' || count(*) FROM rooms"
psql_migrator -tA -c "SELECT 'staff=' || count(*) FROM staff"
psql_migrator -tA -c "SELECT 'bookings=' || count(*) FROM bookings"
echo "迁移完成。"
