"""报表仓储。

两个接口刻意用不同实现，方便对比：
  utilization  → 读物化视图（预聚合读模型），秒回
  peak_hours   → 现场从明细表算（generate_series 造时间轴）
"""
from __future__ import annotations

from datetime import datetime

from db import autocommit_connection, cursor

WINDOW_CTE = """
WITH win AS (
    SELECT coalesce(%(p_from)s::timestamptz,
                    date_trunc('day', now()) - ((%(days)s - 1) * interval '1 day')) AS p_from,
           coalesce(%(p_to)s::timestamptz,
                    date_trunc('day', now()) + interval '1 day')                   AS p_to
)
"""

# ---------- 读模型 + 窗口函数 ----------
UTILIZATION_SQL = WINDOW_CTE + """
, usage AS (
    SELECT m.room_id,
           m.room_name,
           sum(m.bookings)                                      AS booking_count,
           sum(m.total_hours)                                   AS total_hours,
           -- 每天的平均时长要按「当天次数」加权，才能还原全局平均
           round(sum(m.avg_hours * m.bookings) / nullif(sum(m.bookings), 0), 2) AS avg_hours,
           max(m.max_hours)                                     AS max_hours
    FROM reporting.mv_room_daily_usage m
    CROSS JOIN win
    WHERE m.book_date >= (win.p_from AT TIME ZONE 'Asia/Shanghai')::date
      AND m.book_date <= (win.p_to   AT TIME ZONE 'Asia/Shanghai')::date
    GROUP BY m.room_id, m.room_name
)
SELECT u.room_id,
       u.room_name,
       u.booking_count,
       u.total_hours,
       u.avg_hours,
       u.max_hours,
       rank() OVER (ORDER BY u.total_hours DESC)                              AS rank_by_hours,
       round(u.total_hours / nullif(sum(u.total_hours) OVER (), 0) * 100, 1)  AS share_pct,
       sum(u.total_hours) OVER (ORDER BY u.total_hours DESC, u.room_id
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_hours
FROM usage u
ORDER BY u.total_hours DESC, u.room_name
"""

# ---------- 现场聚合 + 时间轴骨架 ----------
PEAK_HOURS_SQL = WINDOW_CTE + """
SELECT h.hour,
       coalesce(count(b.id), 0)                  AS bookings,
       coalesce(sum(b.hours), 0)::numeric(10, 2) AS hours_booked
FROM generate_series(0, 23) AS h(hour)
LEFT JOIN v_confirmed_bookings b
       ON date_part('hour', b.starts_at AT TIME ZONE 'Asia/Shanghai') = h.hour
      AND b.starts_at >= (SELECT p_from FROM win)
      AND b.ends_at   <= (SELECT p_to   FROM win)
GROUP BY h.hour
ORDER BY h.hour
"""

WINDOW_BOUNDS_SQL = WINDOW_CTE + "SELECT p_from, p_to FROM win"

FRESHNESS_SQL = """
SELECT name, refreshed_at, row_count, last_source,
       round(extract(epoch FROM now() - refreshed_at)::numeric, 1) AS age_seconds
FROM reporting.report_state
ORDER BY name
"""


def utilization(days: int, p_from: datetime | None, p_to: datetime | None) -> dict:
    params = {"days": days, "p_from": p_from, "p_to": p_to}
    with cursor() as cur:
        cur.execute(WINDOW_BOUNDS_SQL, params)
        win = cur.fetchone()
        cur.execute(UTILIZATION_SQL, params)
        items = cur.fetchall()
        cur.execute(FRESHNESS_SQL)
        freshness = cur.fetchall()
    return {"window": win, "source": "reporting.mv_room_daily_usage", "freshness": freshness, "items": items}


def peak_hours(days: int, p_from: datetime | None, p_to: datetime | None) -> dict:
    params = {"days": days, "p_from": p_from, "p_to": p_to}
    with cursor() as cur:
        cur.execute(WINDOW_BOUNDS_SQL, params)
        win = cur.fetchone()
        cur.execute(PEAK_HOURS_SQL, params)
        items = cur.fetchall()
    return {"window": win, "source": "live: v_confirmed_bookings", "items": items}


def refresh(source: str) -> dict:
    """REFRESH ... CONCURRENTLY：刷新时不阻塞读，但必须脱离事务块执行。"""
    with autocommit_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_room_daily_usage")
            cur.execute(
                """
                UPDATE reporting.report_state
                   SET refreshed_at = now(),
                       row_count    = (SELECT count(*) FROM reporting.mv_room_daily_usage),
                       last_source  = %s
                 WHERE name = 'mv_room_daily_usage'
                RETURNING name, refreshed_at, row_count, last_source
                """,
                (source,),
            )
            return cur.fetchone()
