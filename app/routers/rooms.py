from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Query

from errors import InvalidInput
from repositories import rooms as repo
from schemas import RoomCreate, RoomOut

router = APIRouter(prefix="/api/rooms", tags=["rooms"])


@router.get("", response_model=list[RoomOut])
def list_rooms(include_inactive: bool = False):
    return repo.list_rooms(include_inactive)


@router.get("/available", response_model=list[RoomOut])
def available_rooms(
    from_: datetime = Query(alias="from", description="区间开始，ISO8601 带时区"),
    to: datetime = Query(description="区间结束，ISO8601 带时区"),
    min_capacity: int = Query(1, ge=1),
    equipment: str | None = Query(None, description="逗号分隔，要求全部具备，如 projector,video_conf"),
):
    """可用房间 = 数据库函数 free_rooms()，区间重叠判断用的是同一套 tstzrange 语义。"""
    if to <= from_:
        raise InvalidInput("to 必须晚于 from")
    required = [e.strip() for e in equipment.split(",") if e.strip()] if equipment else None
    return repo.free_rooms(from_, to, min_capacity, required)


@router.post("", response_model=RoomOut, status_code=201)
def create_room(payload: RoomCreate):
    return repo.create_room(
        payload.name, payload.floor, payload.capacity, payload.equipment, payload.active
    )
