"""进程配置：全部来自环境变量，容器里由 compose 注入。"""
from __future__ import annotations

import os
from dataclasses import dataclass

@dataclass(frozen=True)
class Settings:
    database_url: str
    pool_min: int
    pool_max: int
    admin_token: str

def load_settings() -> Settings:
    return Settings(
        database_url=os.environ.get(
            "DATABASE_URL",
            "postgresql://roomdesk_app:app_pw@127.0.0.1:6432/roomdesk",
        ),
        pool_min=int(os.environ.get("DB_POOL_MIN", "1")),
        pool_max=int(os.environ.get("DB_POOL_MAX", "10")),
        admin_token=os.environ.get("ADMIN_TOKEN", "dev-admin-token"),
    )

settings = load_settings()
