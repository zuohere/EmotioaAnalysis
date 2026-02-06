"""Emotion Gateway Client.

提供向网关 WebSocket 发送多模态数据（text/audio/video/vital）的客户端实现。
"""

from .config import ClientConfig
from .runner import run_client

__all__ = ["ClientConfig", "run_client"]

