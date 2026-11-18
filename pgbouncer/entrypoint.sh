#!/bin/sh
# 启动前从环境变量生成 userlist.txt（密码只存在 .env，不进仓库）
set -eu

: "${DB_USER:=roomdesk_app}"
: "${DB_PASSWORD:?DB_PASSWORD 必须设置}"
: "${ADMIN_USER:=pgb_admin}"
: "${ADMIN_PASSWORD:=$DB_PASSWORD}"

umask 077
cat > /etc/pgbouncer/userlist.txt <<EOF
"$DB_USER" "$DB_PASSWORD"
"$ADMIN_USER" "$ADMIN_PASSWORD"
EOF

echo "[pgbouncer] userlist 就绪：$DB_USER, $ADMIN_USER"
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
