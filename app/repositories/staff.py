"""人员仓储。"""
from __future__ import annotations

import psycopg

from db import cursor
from errors import Conflict

COLS = "id, name, email, role"


def list_staff() -> list[dict]:
    with cursor() as cur:
        cur.execute(f"SELECT {COLS} FROM staff ORDER BY id")
        return cur.fetchall()


def create_staff(name: str, email: str, role: str) -> dict:
    with cursor() as cur:
        try:
            cur.execute(
                f"INSERT INTO staff (name, email, role) VALUES (%s, %s, %s) RETURNING {COLS}",
                (name, email, role),
            )
        except psycopg.errors.UniqueViolation as exc:
            raise Conflict("邮箱已存在") from exc
        return cur.fetchone()
