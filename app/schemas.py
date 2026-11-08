from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field, model_validator


class RoomCreate(BaseModel):
    name: str = Field(min_length=1, max_length=64)
    floor: int = Field(ge=-3, le=99)
    capacity: int = Field(gt=0, le=500)
    equipment: list[str] = Field(default_factory=list)
    active: bool = True


class RoomOut(BaseModel):
    id: int
    name: str
    floor: int
    capacity: int
    equipment: list[str]
    active: bool


class StaffCreate(BaseModel):
    name: str = Field(min_length=1, max_length=32)
    email: str = Field(min_length=3, max_length=128)
    role: str = Field(default="member", pattern="^(member|admin)$")


class StaffOut(BaseModel):
    id: int
    name: str
    email: str
    role: str


class BookingCreate(BaseModel):
    room_id: int
    staff_id: int
    starts_at: datetime
    ends_at: datetime
    purpose: str = Field(default="", max_length=200)
    tags: list[str] = Field(default_factory=list)
    idempotency_key: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def _check_range(self) -> "BookingCreate":
        if self.ends_at <= self.starts_at:
            raise ValueError("ends_at 必须晚于 starts_at")
        return self


class BookingOut(BaseModel):
    id: int
    room_id: int
    room_name: str
    staff_id: int
    staff_name: str
    starts_at: datetime
    ends_at: datetime
    purpose: str
    status: str
    tags: list[str] = Field(default_factory=list)
    idempotency_key: str | None = None
    created_at: datetime
