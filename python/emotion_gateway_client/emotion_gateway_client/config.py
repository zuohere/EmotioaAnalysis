from __future__ import annotations

from dataclasses import dataclass
import os


@dataclass(frozen=True)
class ClientConfig:
    # WebSocket
    ws_url: str
    api_token: str | None = None
    token_in_header: bool = False

    # Identity / windowing
    user_id: str = "11"
    snapshot_window_sec: float = 15.0
    warmup_sec: float = 2.0

    # Media
    video_width: int = 640
    video_height: int = 360
    video_fps: int = 15

    aac_rate: int = 24000
    aac_channels: int = 1
    aac_chunk: int = 512

    @staticmethod
    def from_env() -> "ClientConfig":
        ws_url = os.getenv("WS_URL", "").strip()
        if not ws_url:
            raise ValueError("缺少 WS_URL（例如 wss://api.finnox.cn/gateway/v1/proxy/ws）")

        token = os.getenv("API_TOKEN") or os.getenv("WS_TOKEN") or os.getenv("token")
        token_in_header = os.getenv("TOKEN_IN_HEADER", "0").lower() in {"1", "true", "yes"}

        return ClientConfig(
            ws_url=ws_url,
            api_token=(token.strip() if token else None),
            token_in_header=token_in_header,
            user_id=os.getenv("USER_ID", "11"),
            snapshot_window_sec=float(os.getenv("SNAPSHOT_WINDOW_SEC", "15")),
            warmup_sec=float(os.getenv("CLIENT_WARMUP_SEC", "2.0")),
            video_width=int(os.getenv("VIDEO_WIDTH", "640")),
            video_height=int(os.getenv("VIDEO_HEIGHT", "360")),
            video_fps=int(os.getenv("VIDEO_FPS", "15")),
            aac_rate=int(os.getenv("AAC_RATE", "24000")),
            aac_channels=int(os.getenv("AAC_CHANNELS", "1")),
            aac_chunk=int(os.getenv("AAC_CHUNK", "512")),
        )

