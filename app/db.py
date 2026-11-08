"""连接池与查询辅助。

两点刻意设计：
1. prepare_threshold=None —— 我们连的是 pgbouncer **事务池**，同一个服务端连接会
   被不同客户端复用，服务端预编译语句会串味，必须关掉自动预编译。
2. autocommit_connection() —— REFRESH MATERIALIZED VIEW CONCURRENTLY 不能跑在
   事务块里，需要一条 autocommit 的独立连接。
"""
from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from config import settings

pool = ConnectionPool(
    conninfo=settings.database_url,
    min_size=settings.pool_min,
    max_size=settings.pool_max,
    kwargs={"row_factory": dict_row, "prepare_threshold": None},
    open=False,
)


def open_pool(wait: bool = True, timeout: float = 30.0) -> None:
    pool.open(wait=wait, timeout=timeout)


def close_pool() -> None:
    pool.close()


@contextmanager
def cursor() -> Iterator:
    """借一条连接执行 SQL：正常退出提交，抛异常回滚。"""
    with pool.connection() as conn:
        with conn.cursor() as cur:
            yield cur


@contextmanager
def autocommit_connection() -> Iterator[psycopg.Connection]:
    """脱离事务块的语句（REFRESH ... CONCURRENTLY 等）用这个。"""
    conn = psycopg.connect(settings.database_url, autocommit=True, row_factory=dict_row)
    try:
        yield conn
    finally:
        conn.close()


def health() -> dict:
    with cursor() as cur:
        cur.execute(
            """
            SELECT current_user                             AS db_user,
                   current_database()                       AS database,
                   now()                                    AS server_time,
                   current_setting('server_version')        AS server_version,
                   (SELECT count(*) FROM pg_stat_activity
                     WHERE datname = current_database())    AS connections
            """
        )
        return cur.fetchone()
