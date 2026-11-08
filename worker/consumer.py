"""RoomDesk worker：事件消费者 + 读模型刷新器。

两条职责，刻意用两条连接：

1) LISTEN roomdesk_bookings
   - 必须**直连** db:5432 —— LISTEN 是会话级的，走 pgbouncer 事务池会被拆散
   - 收到 NOTIFY 后把事件落到 notifications 表（持久化，便于审计/重放）

2) 定时 REFRESH MATERIALIZED VIEW CONCURRENTLY
   - 必须 **autocommit** —— CONCURRENTLY 不能出现在事务块里
   - 刷新完更新 reporting.report_state 这个"新鲜度水位"

连接断了就重连，不让容器直接挂掉（运维上更重要）。
"""
from __future__ import annotations

import json
import logging
import os
import signal
import time

import psycopg
from psycopg.rows import dict_row

DSN = os.environ.get("WORKER_DSN", "postgresql://roomdesk_app:app_pw@db:5432/roomdesk")
CHANNEL = os.environ.get("NOTIFY_CHANNEL", "roomdesk_bookings")
REFRESH_INTERVAL = float(os.environ.get("REFRESH_INTERVAL", "15"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [worker] %(message)s",
)
log = logging.getLogger("worker")

_stop = False


def _on_signal(signum, frame):  # noqa: ARG001
    global _stop
    _stop = True
    log.info("收到信号 %s，准备优雅退出", signum)


def refresh_reports(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_room_daily_usage")
        cur.execute(
            """
            UPDATE reporting.report_state
               SET refreshed_at = now(),
                   row_count    = (SELECT count(*) FROM reporting.mv_room_daily_usage),
                   last_source  = 'worker'
             WHERE name = 'mv_room_daily_usage'
            RETURNING row_count
            """
        )
        row = cur.fetchone()
    log.info("读模型已刷新 rows=%s", row["row_count"])


def store_notification(conn: psycopg.Connection, payload: dict) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO notifications (event, payload) VALUES (%s, %s)",
            (payload.get("event", "unknown"), json.dumps(payload.get("payload", {}))),
        )
    log.info("收到事件 %s", payload.get("event"))


def main() -> int:
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    while not _stop:
        try:
            with psycopg.connect(DSN, autocommit=True, row_factory=dict_row) as work_conn, \
                 psycopg.connect(DSN, autocommit=True) as listen_conn:
                listen_conn.execute(f"LISTEN {CHANNEL}")
                log.info("LISTEN %s 已就绪", CHANNEL)

                refresh_reports(work_conn)
                last_refresh = time.monotonic()

                while not _stop:
                    got_any = False
                    for note in listen_conn.notifies(timeout=REFRESH_INTERVAL, stop_after=1):
                        got_any = True
                        try:
                            store_notification(work_conn, json.loads(note.payload))
                        except Exception:
                            log.exception("事件落库失败")

                    if got_any and time.monotonic() - last_refresh >= 1:
                        try:
                            refresh_reports(work_conn)
                            last_refresh = time.monotonic()
                        except Exception:
                            log.exception("刷新读模型失败")
                    elif time.monotonic() - last_refresh >= REFRESH_INTERVAL:
                        try:
                            refresh_reports(work_conn)
                            last_refresh = time.monotonic()
                        except Exception:
                            log.exception("刷新读模型失败")
        except Exception:
            if _stop:
                break
            log.exception("连接异常，5 秒后重连")
            time.sleep(5)

    log.info("worker 退出")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
