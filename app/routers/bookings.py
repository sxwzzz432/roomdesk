from __future__ import annotations

from fastapi import APIRouter, Header, Query, Response

from repositories import bookings as repo
from schemas import BookingCreate

router = APIRouter(prefix="/api/bookings", tags=["bookings"])


@router.post("", status_code=201)
def create_booking(
    payload: BookingCreate,
    response: Response,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    """创建预约。

    - 时间冲突：**由数据库的 EXCLUDE 约束判定**，不是先查后插
    - 幂等：同一个键重复提交返回第一次的结果（200），不会产生第二条
    """
    key = (payload.idempotency_key or idempotency_key or "").strip() or None
    booking, created = repo.create(
        room_id=payload.room_id,
        staff_id=payload.staff_id,
        starts_at=payload.starts_at,
        ends_at=payload.ends_at,
        purpose=payload.purpose,
        tags=payload.tags,
        idempotency_key=key,
    )
    if not created:
        response.status_code = 200
    return booking


@router.get("")
def list_bookings(
    q: str | None = Query(None, description="用途/标签模糊搜索（走 trigram 索引）"),
    room_id: int | None = None,
    staff_id: int | None = None,
    status: str | None = Query(None, pattern="^(confirmed|cancelled)$"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
):
    items = repo.list_bookings(q, room_id, staff_id, status, limit, offset)
    return {"limit": limit, "offset": offset, "count": len(items), "items": items}


@router.get("/{booking_id}")
def get_booking(booking_id: int):
    return repo.get_or_404(booking_id)


@router.post("/{booking_id}/cancel")
def cancel_booking(booking_id: int):
    """取消后，该时段因脱离部分索引条件而重新可用。"""
    return repo.cancel(booking_id)


@router.get("/{booking_id}/events")
def booking_events(booking_id: int):
    """审计事件（分区表）：能看出每条事件落在哪个月的分区。"""
    return repo.events(booking_id)
