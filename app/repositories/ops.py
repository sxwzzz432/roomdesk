"""运维观测仓储：把 PostgreSQL 自带的监控视图暴露给 HTTP。

这些查询本身就是教学材料：
  pg_stat_activity      → 谁在连、在跑什么
  pg_stat_statements    → 哪条 SQL 最耗时间
  pg_total_relation_size→ 哪些表/索引在吃磁盘
  tableoid::regclass    → 事件落在哪个分区
"""
from __future__ import annotations

from db import cursor

ACTIVITY_SQL = """
SELECT coalesce(state, 'unknown') AS state, count(*) AS connections
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY 1
ORDER BY 2 DESC
"""

TOP_STATEMENTS_SQL = r"""
SELECT calls,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       round(rows::numeric, 0)            AS rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 110) AS query
FROM pg_stat_statements
WHERE query NOT ILIKE '%%pg_stat_statements%%'
  AND query NOT ILIKE '%%pg_stat_activity%%'
ORDER BY total_exec_time DESC
LIMIT %s
"""

RELATIONS_SQL = """
SELECT n.nspname                    AS schema,
       c.relname                    AS name,
       CASE c.relkind WHEN 'r' THEN 'table'
                      WHEN 'p' THEN 'partitioned table'
                      WHEN 'm' THEN 'materialized view'
                      WHEN 'v' THEN 'view'
                      ELSE c.relkind::text END AS kind,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('roomdesk', 'reporting')
  AND c.relkind IN ('r', 'p', 'm', 'v')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT %s
"""

PARTITIONS_SQL = """
SELECT tableoid::regclass::text AS partition, count(*) AS rows
FROM booking_events
GROUP BY 1
ORDER BY 1
"""

NOTIFICATIONS_SQL = """
SELECT id, event, payload, received_at
FROM notifications
ORDER BY id DESC
LIMIT %s
"""


def db_summary(top_statements: int = 5, relations: int = 12) -> dict:
    with cursor() as cur:
        cur.execute(ACTIVITY_SQL)
        activity = cur.fetchall()
        cur.execute(TOP_STATEMENTS_SQL, (top_statements,))
        statements = cur.fetchall()
        cur.execute(RELATIONS_SQL, (relations,))
        rels = cur.fetchall()
        cur.execute(
            "SELECT current_user AS db_user, current_setting('server_version') AS version"
        )
        identity = cur.fetchone()
    return {
        "identity": identity,
        "activity": activity,
        "top_statements": statements,
        "relations": rels,
    }


def partitions() -> list[dict]:
    with cursor() as cur:
        cur.execute(PARTITIONS_SQL)
        return cur.fetchall()


def notifications(limit: int = 50) -> list[dict]:
    with cursor() as cur:
        cur.execute(NOTIFICATIONS_SQL, (limit,))
        return cur.fetchall()


# 前端总览用的计数：一个 query 把几张表的 count 一起算完
STATS_SQL = """
SELECT (SELECT count(*) FROM rooms)                                AS rooms,
       (SELECT count(*) FROM rooms WHERE active)                    AS rooms_active,
       (SELECT count(*) FROM staff)                                 AS staff,
       (SELECT count(*) FROM bookings)                              AS bookings,
       (SELECT count(*) FROM bookings WHERE status = 'confirmed')    AS bookings_confirmed,
       (SELECT count(*) FROM bookings WHERE status = 'cancelled')    AS bookings_cancelled,
       (SELECT count(*) FROM booking_events)                        AS events,
       (SELECT count(*) FROM notifications)                         AS notifications
"""


def stats() -> dict:
    with cursor() as cur:
        cur.execute(STATS_SQL)
        return cur.fetchone()
