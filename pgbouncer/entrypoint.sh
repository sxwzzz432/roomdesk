#!/bin/sh
# ============================================================
#  pgbouncer 启动前生成 userlist.txt
#
#  这样密码只存在 .env 里，不用把明文提交进仓库。
#  auth_type = plain：userlist 里存明文，pgbouncer 拿它去和 SCRAM 的 PG 握手。
# ============================================================
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
