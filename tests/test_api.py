"""端到端测试：接口行为 + 数据库约束 + 最小权限 + 事件链路。

在 api 容器里跑（make test）：
    docker compose exec api python -m pytest -q tests

时间相关的用例都使用「远期 + 随机分钟」，保证反复跑不会互相撞。
"""
from __future__ import annotations

import os
import random
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import httpx
import psycopg
import pytest

BASE = os.environ.get("BASE_URL", "http://127.0.0.1:8000")
DSN = os.environ.get("DATABASE_URL", "postgresql://roomdesk_app:app_pw@pgbouncer:6432/roomdesk")
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "dev-admin-token")
TZ = timezone(timedelta(hours=8))


def client() -> httpx.Client:
    return httpx.Client(base_url=BASE, timeout=20.0)


def slot(days: int, hour: float, length_hours: float = 1.0) -> tuple[str, str]:
    """days 天后的 hour 点开始一个区间，分钟随机。"""
    start = (datetime.now(TZ) + timedelta(days=days)).replace(
        hour=0, minute=0, second=0, microsecond=0
    ) + timedelta(hours=hour, minutes=random.randrange(0, 60))
    end = start + timedelta(hours=length_hours)
    return start.isoformat(), end.isoformat()


def free_slot(room_id: int, length_hours: float = 1.0,
              days_range: tuple[int, int] = (400, 4000)) -> tuple[str, str]:
    """挑一个该房间**确实空闲**的时段。

    为什么不用固定 slot：测试会反复跑在同一个库上，而预约是整段独占的
    （同一房间同一小时内的任意两条 1 小时预约都会重叠）。这里先问
    /api/rooms/available，确认房间在那个时段真的空着再拿去建预约，
    测试就不会因为历史数据而随机失败。
    """
    with client() as c:
        for _ in range(10):
            start, end = slot(random.randint(*days_range), random.randint(5, 22), length_hours)
            r = c.get("/api/rooms/available", params={"from": start, "to": end})
            if r.status_code != 200:
                continue
            if any(room["id"] == room_id for room in r.json()):
                return start, end
    raise AssertionError(f"找不到 room_id={room_id} 的空闲时段（{length_hours}h）")


@pytest.fixture(scope="module")
def rooms() -> list[dict]:
    with client() as c:
        r = c.get("/api/rooms")
        assert r.status_code == 200, r.text
        data = r.json()
        assert len(data) >= 2
        return data


@pytest.fixture(scope="module")
def staff() -> list[dict]:
    with client() as c:
        r = c.get("/api/staff")
        assert r.status_code == 200, r.text
        data = r.json()
        assert len(data) >= 2
        return data


# ------------------------------------------------------------
# 基础设施
# ------------------------------------------------------------
def test_health():
    with client() as c:
        r = c.get("/health")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "ok"
    # 库名随环境不同（容器里是 roomdesk，本机模式是 roomdesk_local），
    # 这里只要求"确实连着某个库、而且用的是最小权限角色"。
    assert body["database"]
    assert body["server_version"]


def test_api_connects_through_pooler_as_app_role():
    """/health 里回显的 current_user 必须是应用角色 —— 证明走的是 pgbouncer + 最小权限账号。"""
    with client() as c:
        body = c.get("/health").json()
    assert body["db_user"] == "roomdesk_app", body


def test_app_role_cannot_ddl_in_business_schema():
    """最小权限的硬证明：应用角色在 roomdesk schema 里建表必须被拒绝。"""
    with psycopg.connect(DSN, autocommit=True) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("CREATE TABLE roomdesk.should_fail (id int)")

        # reporting schema 故意给了 CREATE（物化视图需要 app 持有），这里是设计内行为
        conn.execute("CREATE TABLE reporting.scratch_permission_test (id int)")
        conn.execute("DROP TABLE reporting.scratch_permission_test")


# ------------------------------------------------------------
# 预约核心
# ------------------------------------------------------------
def test_create_booking(rooms, staff):
    start, end = free_slot(rooms[0]["id"])
    with client() as c:
        r = c.post("/api/bookings", json={
            "room_id": rooms[0]["id"],
            "staff_id": staff[0]["id"],
            "starts_at": start,
            "ends_at": end,
            "purpose": "接口冒烟测试",
            "tags": ["smoke"],
        })
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["status"] == "confirmed"
    assert body["room_name"] == rooms[0]["name"]
    assert body["tags"] == ["smoke"]


def test_overlap_rejected_by_database(rooms, staff):
    # 找一段连续 3 小时都空着的窗口：前 2 小时给主预约，最后 1 小时验证「紧邻不算重叠」
    start, end3 = free_slot(rooms[0]["id"], 3)
    end = (datetime.fromisoformat(start) + timedelta(hours=2)).isoformat()
    payload = {
        "room_id": rooms[0]["id"],
        "staff_id": staff[0]["id"],
        "starts_at": start,
        "ends_at": end,
        "purpose": "第一段",
    }
    with client() as c:
        assert c.post("/api/bookings", json=payload).status_code == 201

        # 完全重叠
        r = c.post("/api/bookings", json={**payload, "purpose": "完全重叠"})
        assert r.status_code == 409
        assert "排他约束" in r.json()["detail"]

        # 部分重叠（右端伸进来）
        assert c.post("/api/bookings", json={
            **payload,
            "starts_at": (datetime.fromisoformat(end) - timedelta(minutes=30)).isoformat(),
            "ends_at": (datetime.fromisoformat(end) + timedelta(hours=1)).isoformat(),
        }).status_code == 409

        # 紧邻不算重叠（[) 半开区间）
        assert c.post("/api/bookings", json={
            **payload,
            "starts_at": end,
            "ends_at": end3,
        }).status_code == 201


def test_concurrent_double_booking_only_one_wins(rooms, staff):
    """8 个请求抢同一房间同一时段，正好 1 个成功、7 个 409。"""
    start, end = free_slot(rooms[0]["id"])

    def attempt(i: int) -> int:
        with client() as c:
            return c.post("/api/bookings", json={
                "room_id": rooms[0]["id"],
                "staff_id": staff[i % len(staff)]["id"],
                "starts_at": start,
                "ends_at": end,
                "purpose": f"并发抢房 {i}",
            }).status_code

    with ThreadPoolExecutor(max_workers=8) as ex:
        codes = list(ex.map(attempt, range(8)))

    assert codes.count(201) == 1, codes
    assert codes.count(409) == 7, codes


def test_idempotency_key(rooms, staff):
    start, end = free_slot(rooms[1]["id"])
    key = f"itest-{random.randint(1, 10**9)}"
    payload = {
        "room_id": rooms[1]["id"],
        "staff_id": staff[1]["id"],
        "starts_at": start,
        "ends_at": end,
        "purpose": "幂等测试",
        "idempotency_key": key,
    }
    with client() as c:
        r1 = c.post("/api/bookings", json=payload)
        r2 = c.post("/api/bookings", json=payload)
        r3 = c.post("/api/bookings", json={k: v for k, v in payload.items() if k != "idempotency_key"},
                    headers={"Idempotency-Key": key})
    assert r1.status_code == 201
    assert r2.status_code == 200
    assert r3.status_code == 200
    assert r1.json()["id"] == r2.json()["id"] == r3.json()["id"]


def test_availability_excludes_booked_room(rooms, staff):
    start, end = free_slot(rooms[0]["id"])
    with client() as c:
        before = c.get("/api/rooms/available", params={"from": start, "to": end})
        assert before.status_code == 200
        assert rooms[0]["id"] in {r["id"] for r in before.json()}

        assert c.post("/api/bookings", json={
            "room_id": rooms[0]["id"],
            "staff_id": staff[0]["id"],
            "starts_at": start,
            "ends_at": end,
            "purpose": "占住房间",
        }).status_code == 201

        after = c.get("/api/rooms/available", params={"from": start, "to": end})
        assert rooms[0]["id"] not in {r["id"] for r in after.json()}


def test_cancel_releases_slot_and_writes_partitioned_events(rooms, staff):
    start, end = free_slot(rooms[0]["id"])
    payload = {
        "room_id": rooms[0]["id"],
        "staff_id": staff[0]["id"],
        "starts_at": start,
        "ends_at": end,
        "purpose": "取消后重订",
    }
    with client() as c:
        created = c.post("/api/bookings", json=payload)
        assert created.status_code == 201
        booking_id = created.json()["id"]

        assert c.post(f"/api/bookings/{booking_id}/cancel").status_code == 200
        assert c.post(f"/api/bookings/{booking_id}/cancel").status_code == 409

        # 同一时段现在可以再订
        assert c.post("/api/bookings", json=payload).status_code == 201

        events = c.get(f"/api/bookings/{booking_id}/events").json()
        kinds = [e["event"] for e in events]
        assert "created" in kinds and "status_changed" in kinds
        # 事件落在分区表里，能看出属于哪个月
        assert all(e["partition"].startswith("booking_events_") for e in events)


def test_equipment_filter(rooms):
    """按设备筛选：只有 F8-观澜 同时具备 led_wall + video_conf。"""
    target = next(r for r in rooms if "led_wall" in (r["equipment"] or []))
    start, end = free_slot(target["id"])
    with client() as c:
        r = c.get("/api/rooms/available", params={
            "from": start, "to": end, "equipment": "led_wall,video_conf",
        })
    assert r.status_code == 200
    assert [room["name"] for room in r.json()] == [target["name"]]


def test_invalid_range_rejected(rooms, staff):
    start, end = free_slot(rooms[0]["id"])
    with client() as c:
        r = c.post("/api/bookings", json={
            "room_id": rooms[0]["id"],
            "staff_id": staff[0]["id"],
            "starts_at": end,
            "ends_at": start,
        })
    assert r.status_code == 422


# ------------------------------------------------------------
# 报表：物化视图 vs 现场聚合
# ------------------------------------------------------------
def test_utilization_reads_materialized_view():
    with client() as c:
        r = c.get("/api/reports/utilization", params={"days": 30})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["source"] == "reporting.mv_room_daily_usage"
    assert body["freshness"], "必须带读模型新鲜度"
    assert body["freshness"][0]["age_seconds"] is not None
    for row in body["items"]:
        assert row["rank_by_hours"] >= 1
        assert row["share_pct"] is not None
        assert row["running_hours"] >= row["total_hours"]


def test_peak_hours_is_computed_live():
    with client() as c:
        r = c.get("/api/reports/peak-hours", params={"days": 30})
    assert r.status_code == 200
    body = r.json()
    assert body["source"].startswith("live:")
    assert len(body["items"]) == 24   # generate_series 保证 0~23 点都在


def test_manual_refresh_requires_token():
    with client() as c:
        assert c.post("/api/ops/refresh").status_code == 403
        ok = c.post("/api/ops/refresh", headers={"X-Admin-Token": ADMIN_TOKEN})
    assert ok.status_code == 200, ok.text
    assert ok.json()["last_source"] == "api"


# ------------------------------------------------------------
# 运维观测 + 事件链路
# ------------------------------------------------------------
def test_ops_db_exposes_postgres_views():
    with client() as c:
        r = c.get("/api/ops/db")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["identity"]["db_user"] == "roomdesk_app"
    assert isinstance(body["activity"], list)
    assert isinstance(body["relations"], list)
    names = {rel["name"] for rel in body["relations"]}
    assert "bookings" in names
    assert "mv_room_daily_usage" in names


def test_ops_partitions():
    with client() as c:
        r = c.get("/api/ops/partitions")
    assert r.status_code == 200
    names = [p["partition"] for p in r.json()]
    assert any(n.startswith("booking_events_") or n.endswith("_default") for n in names)


def test_notify_pipeline_worker_to_notifications_table(rooms, staff):
    """LISTEN/NOTIFY 全链路：API 写库 → 触发器 NOTIFY → worker 落 notifications 表。"""
    start, end = free_slot(rooms[2]["id"])
    with client() as c:
        created = c.post("/api/bookings", json={
            "room_id": rooms[2]["id"],
            "staff_id": staff[2]["id"],
            "starts_at": start,
            "ends_at": end,
            "purpose": "notify 链路测试",
        })
        assert created.status_code == 201, created.text
        booking_id = created.json()["id"]

        deadline = time.time() + 20
        seen = None
        while time.time() < deadline:
            for row in c.get("/api/ops/notifications", params={"limit": 200}).json():
                payload = row["payload"] or {}
                if str(payload.get("id")) == str(booking_id):
                    seen = row
                    break
            if seen:
                break
            time.sleep(0.5)

    assert seen is not None, "worker 没有把 NOTIFY 事件落库"
    assert seen["event"] == "booking.created"
