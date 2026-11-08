"""运维接口：把 PostgreSQL 的监控视图暴露成 HTTP。

除 refresh 外全部只读；refresh 用 X-Admin-Token 简单保护（演示用，不是真鉴权）。
"""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException, Query

from config import settings
from repositories import ops as ops_repo
from repositories import reports as reports_repo

router = APIRouter(prefix="/api/ops", tags=["ops"])


def require_admin(x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")) -> None:
    if x_admin_token != settings.admin_token:
        raise HTTPException(status_code=403, detail="需要正确设置 X-Admin-Token")


@router.get("/db")
def db_summary(
    top_statements: int = Query(5, ge=1, le=20),
    relations: int = Query(12, ge=1, le=40),
):
    """连接状态 + 最耗时的 SQL（pg_stat_statements）+ 表/索引体积。"""
    return ops_repo.db_summary(top_statements, relations)


@router.get("/stats")
def stats():
    """总览用的计数（房间/人员/预约/事件/通知）。"""
    return ops_repo.stats()


@router.get("/partitions")
def partitions():
    """booking_events 各分区的行数（tableoid::regclass）。"""
    return ops_repo.partitions()


@router.get("/notifications")
def notifications(limit: int = Query(50, ge=1, le=200)):
    """worker 通过 LISTEN/NOTIFY 收到并落库的事件。"""
    return ops_repo.notifications(limit)


@router.post("/refresh", dependencies=[])
def refresh_reports(x_admin_token: str | None = Header(default=None, alias="X-Admin-Token")):
    """手动刷新读模型（等价于 worker 的定时动作）。"""
    require_admin(x_admin_token)
    return reports_repo.refresh(source="api")
