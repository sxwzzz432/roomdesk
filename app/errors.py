"""领域异常：让仓储层不依赖 HTTP，由 main.py 统一翻译成状态码。"""
from __future__ import annotations


class RoomDeskError(Exception):
    """所有业务异常的基类。"""


class NotFound(RoomDeskError):
    """资源不存在 → 404"""


class Conflict(RoomDeskError):
    """状态冲突：时段被占、已取消、幂等键冲突 → 409"""


class InvalidInput(RoomDeskError):
    """参数不合法 → 400"""
