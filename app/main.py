from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

import db
from errors import Conflict, InvalidInput, NotFound
from routers import bookings, ops, reports, rooms, staff

# 前端静态资源（零依赖单页，无需构建）；用 __file__ 定位，容器里和本机都能找到
STATIC_DIR = Path(__file__).resolve().parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.open_pool()
    try:
        yield
    finally:
        db.close_pool()


app = FastAPI(
    title="RoomDesk API",
    version="1.1.0",
    description=(
        "会议室预约与分析平台。\n\n"
        "数据链路：API → pgbouncer(事务池) → PostgreSQL 16；"
        "worker 容器通过 LISTEN/NOTIFY 消费事件并刷新物化视图。\n\n"
        "**前端界面**：[/ui/](/ui/)　|　**本页是接口文档**（Swagger）。"
    ),
    lifespan=lifespan,
)

app.include_router(rooms.router)
app.include_router(staff.router)
app.include_router(bookings.router)
app.include_router(reports.router)
app.include_router(ops.router)

# ---------- 前端：/ui/ 挂静态目录，/ 直接跳过去 ----------
app.mount("/ui", StaticFiles(directory=str(STATIC_DIR), html=True), name="ui")


@app.get("/", include_in_schema=False)
def index():
    return RedirectResponse(url="/ui/")


# ---------- 领域异常 → HTTP 状态码（仓储层不认识 HTTP） ----------
@app.exception_handler(NotFound)
async def _handle_not_found(request: Request, exc: NotFound):
    return JSONResponse(status_code=404, content={"detail": str(exc)})


@app.exception_handler(Conflict)
async def _handle_conflict(request: Request, exc: Conflict):
    return JSONResponse(status_code=409, content={"detail": str(exc)})


@app.exception_handler(InvalidInput)
async def _handle_invalid(request: Request, exc: InvalidInput):
    return JSONResponse(status_code=400, content={"detail": str(exc)})


@app.get("/health", tags=["ops"])
def health():
    """容器健康检查用：能落到数据库才算 healthy。"""
    try:
        info = db.health()
    except Exception as exc:  # 数据库不可用时返回 503，让 compose 把容器标成 unhealthy
        return JSONResponse(status_code=503, content={"status": "degraded", "detail": str(exc)})
    return {"status": "ok", **info}
