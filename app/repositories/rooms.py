"""房间仓储：所有 SQL 都写在这里，路由器不碰 SQL。"""
from __future__ import annotations

from datetime import datetime

import psycopg
from psycopg.types.json import Jsonb

from db import cursor
from errors import Conflict

ROOM_COLS = "id, name, floor, capacity, equipment, active"


def list_rooms(include_inactive: bool = False) -> list[dict]:
    with cursor() as cur:
        cur.execute(
            f"SELECT {ROOM_COLS} FROM rooms WHERE %s OR active ORDER BY floor, name",
            (include_inactive,),
        )
        return cur.fetchall()


def free_rooms(
    p_from: datetime,
    p_to: datetime,
    min_capacity: int = 1,
    equipment: list[str] | None = None,
) -> list[dict]:
    """调用数据库函数：区间重叠判断下推给 SQL（GiST 索引 + 排他约束同源）。"""
    with cursor() as cur:
        cur.execute(
            "SELECT * FROM free_rooms(%s, %s, %s, %s)",
            (p_from, p_to, min_capacity, equipment),
        )
        return cur.fetchall()


def create_room(name: str, floor: int, capacity: int, equipment: list[str], active: bool) -> dict:
    with cursor() as cur:
        try:
            cur.execute(
                f"""INSERT INTO rooms (name, floor, capacity, equipment, active)
                    VALUES (%s, %s, %s, %s, %s)
                    RETURNING {ROOM_COLS}""",
                (name, floor, capacity, Jsonb(equipment), active),
            )
        except psycopg.errors.UniqueViolation as exc:
            raise Conflict("房间名已存在") from exc
        return cur.fetchone()
