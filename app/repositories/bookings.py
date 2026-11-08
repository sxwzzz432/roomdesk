"""预约仓储。

这里的重点是「把正确性交给数据库」：
  - 时间段重叠 → 数据库的 EXCLUDE 约束直接拒绝 → 翻译成 Conflict(409)
  - 幂等键 → 唯一索引兜底，并发下也不会重复创建
  - 取消 → 部分索引条件 status='confirmed' 失效，时段自动释放
"""
from __future__ import annotations

from datetime import datetime

import psycopg

from db import cursor
from errors import Conflict, NotFound

BOOKING_SQL = """
SELECT b.id,
       b.room_id,
       r.name AS room_name,
       b.staff_id,
       s.name AS staff_name,
       lower(b.period) AS starts_at,
       upper(b.period) AS ends_at,
       b.purpose,
       b.status,
       b.tags,
       b.idempotency_key,
       b.created_at
FROM bookings b
JOIN rooms r ON r.id = b.room_id
JOIN staff s ON s.id = b.staff_id
"""


def get(booking_id: int) -> dict | None:
    with cursor() as cur:
        cur.execute(BOOKING_SQL + " WHERE b.id = %s", (booking_id,))
        return cur.fetchone()


def get_or_404(booking_id: int) -> dict:
    row = get(booking_id)
    if row is None:
        raise NotFound("预约不存在")
    return row


def _find_by_idempotency_key(key: str | None) -> dict | None:
    if not key:
        return None
    with cursor() as cur:
        cur.execute("SELECT id FROM bookings WHERE idempotency_key = %s", (key,))
        row = cur.fetchone()
    return get(row["id"]) if row else None


def create(
    room_id: int,
    staff_id: int,
    starts_at: datetime,
    ends_at: datetime,
    purpose: str,
    tags: list[str],
    idempotency_key: str | None,
) -> tuple[dict, bool]:
    """返回 (预约, 是否新建)。重复的幂等键返回已存在的那条，created=False。"""
    existing = _find_by_idempotency_key(idempotency_key)
    if existing:
        return existing, False

    try:
        with cursor() as cur:
            cur.execute(
                """
                INSERT INTO bookings (room_id, staff_id, period, purpose, tags, idempotency_key)
                VALUES (%s, %s, tstzrange(%s, %s, '[)'), %s, %s, %s)
                RETURNING id
                """,
                (room_id, staff_id, starts_at, ends_at, purpose, tags, idempotency_key),
            )
            booking_id = cur.fetchone()["id"]
    except psycopg.errors.ExclusionViolation as exc:
        raise Conflict("该房间在所选时间段已有预约（数据库排他约束拦下）") from exc
    except psycopg.errors.ForeignKeyViolation as exc:
        raise NotFound("room_id 或 staff_id 不存在") from exc
    except psycopg.errors.UniqueViolation as exc:
        # 并发下两个相同幂等键同时插入，输的一方走这里
        existing = _find_by_idempotency_key(idempotency_key)
        if existing:
            return existing, False
        raise Conflict("幂等键冲突") from exc

    return get(booking_id), True


def list_bookings(
    q: str | None,
    room_id: int | None,
    staff_id: int | None,
    status: str | None,
    limit: int,
    offset: int,
) -> list[dict]:
    where, params = ["TRUE"], []
    if q:
        where.append("(b.purpose ILIKE %s OR b.tags::text ILIKE %s)")
        params += [f"%{q}%", f"%{q}%"]
    if room_id is not None:
        where.append("b.room_id = %s")
        params.append(room_id)
    if staff_id is not None:
        where.append("b.staff_id = %s")
        params.append(staff_id)
    if status:
        where.append("b.status = %s")
        params.append(status)

    sql = BOOKING_SQL + " WHERE " + " AND ".join(where) + " ORDER BY b.id DESC LIMIT %s OFFSET %s"
    params += [limit, offset]

    with cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def cancel(booking_id: int) -> dict:
    with cursor() as cur:
        cur.execute(
            """UPDATE bookings
                  SET status = 'cancelled', cancelled_at = now()
                WHERE id = %s AND status = 'confirmed'
                RETURNING id""",
            (booking_id,),
        )
        if cur.fetchone() is None:
            if get(booking_id) is None:
                raise NotFound("预约不存在")
            raise Conflict("该预约已取消")
    return get_or_404(booking_id)


def events(booking_id: int) -> list[dict]:
    """审计事件（分区表），顺带能看到事件落在哪个分区。"""
    with cursor() as cur:
        cur.execute(
            """SELECT id, tableoid::regclass::text AS partition, event, payload, occurred_at
                 FROM booking_events
                WHERE booking_id = %s
                ORDER BY occurred_at, id""",
            (booking_id,),
        )
        return cur.fetchall()
