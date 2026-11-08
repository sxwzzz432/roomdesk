# ============================================================
#  pgbouncer 镜像（自建）
#
#  为什么不用现成镜像：
#    官方没有 pgbouncer 镜像；社区镜像大多用环境变量拼配置，
#    而这里需要"配置文件 + 从环境变量生成 userlist"的精确控制，
#    自己维护一个 25 行的 Dockerfile 反而最省事。
#
#  要点：
#    · 版本全部钉住（alpine、pgbouncer、postgresql-client）
#    · 带上 postgresql-client：为了 pg_isready（健康检查）和 psql（SHOW POOLS）
#    · tini 做 1 号进程，SIGTERM 能正确转发
#    · 以 nobody 运行（pgbouncer 拒绝 root）
# ============================================================
FROM alpine:3.20

LABEL org.opencontainers.image.title="roomdesk-pgbouncer" \
      org.opencontainers.image.description="PostgreSQL 事务连接池（pool_mode=transaction）" \
      org.opencontainers.image.source="roomdesk/pgbouncer"

RUN apk add --no-cache \
        pgbouncer \
        postgresql16-client \
        tini \
    && mkdir -p /etc/pgbouncer /var/log/pgbouncer \
    && chown -R nobody:nobody /etc/pgbouncer /var/log/pgbouncer

COPY pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && chown nobody:nobody /etc/pgbouncer/pgbouncer.ini /usr/local/bin/entrypoint.sh

USER nobody
EXPOSE 6432
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
    CMD pg_isready -h 127.0.0.1 -p 6432 -q || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
