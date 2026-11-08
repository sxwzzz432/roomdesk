from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Query

from repositories import reports as repo

router = APIRouter(prefix="/api/reports", tags=["reports"])


@router.get("/utilization")
def utilization(
    days: int = Query(7, ge=1, le=365),
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
):
    """房间使用率：读 **物化视图**（reporting.mv_room_daily_usage），并附带新鲜度。"""
    return repo.utilization(days, from_, to)


@router.get("/peak-hours")
def peak_hours(
    days: int = Query(7, ge=1, le=365),
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
):
    """按小时分布：现场从明细表聚合，用 generate_series 保证没有预约的小时也在。"""
    return repo.peak_hours(days, from_, to)
