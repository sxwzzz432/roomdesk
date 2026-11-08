from __future__ import annotations

from fastapi import APIRouter

from repositories import staff as repo
from schemas import StaffCreate, StaffOut

router = APIRouter(prefix="/api/staff", tags=["staff"])


@router.get("", response_model=list[StaffOut])
def list_staff():
    return repo.list_staff()


@router.post("", response_model=StaffOut, status_code=201)
def create_staff(payload: StaffCreate):
    return repo.create_staff(payload.name, payload.email, payload.role)
