# pgbouncer 镜像：版本钉住；带 postgresql-client（pg_isready / psql）；tini 转发信号；nobody 运行
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
