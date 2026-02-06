from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import random
import sys
from typing import Any, Dict, Optional

import websockets

from .config import ClientConfig
from .encoders import AACEncoder, H264Encoder, VideoParams, pyaudio_available, video_deps_available
from .protocol import build_gateway_headers, build_gateway_ws_url, dumps_message, now_iso


async def _ws_send(ws, message_type: str, payload: Any) -> None:
    await ws.send(dumps_message(message_type, payload))


def _build_initial_payload(cfg: ClientConfig) -> Dict[str, Any]:
    prep_data = {
        "user_prompt": {
            "scene": "本地算法服务器调试场景",
            "intention": "请综合语音、表情和生命体征，判断用户当前压力与情绪状态。",
            "analysis": "输出结构化结果，包含情绪标签、强度，以及是否需要干预的建议。",
        }
    }
    return {
        "user_id": cfg.user_id,
        "messages": [{"role": "user", "content": "你好，这是本地多模态情绪分析测试。"}],
        "prep_data": prep_data,
        "snapshot_window_sec": cfg.snapshot_window_sec,
        "is_last": False,
    }


async def recv_loop(ws, stop_event: asyncio.Event) -> None:
    try:
        async for message in ws:
            try:
                data = json.loads(message)
            except Exception:
                print("[recv]", message)
                continue

            if not isinstance(data, dict):
                print("[recv]", data)
                continue

            code = data.get("code")
            if code:
                print(
                    f"[gateway][error] request_id={data.get('request_id')} code={code} msg={data.get('msg')}"
                )
                continue

            msg_type = data.get("message_type")
            if msg_type in {"ack", "pong"}:
                continue

            request_id = data.get("request_id")
            if msg_type == "chunk":
                payload = data.get("payload")
                seq = data.get("seq")
                is_final = bool(data.get("is_final"))
                if isinstance(payload, dict):
                    if payload.get("delta"):
                        print(
                            f"[chunk] req={request_id} seq={seq} final={is_final} delta={payload.get('delta')}"
                        )
                    if is_final and payload.get("emotion_result") is not None:
                        print(
                            "[emotion_result]\n"
                            + json.dumps(payload.get("emotion_result"), ensure_ascii=False, indent=2, default=str)
                        )
                elif payload not in (None, ""):
                    print(f"[chunk] req={request_id} seq={seq} final={is_final} payload={payload}")

                if is_final and (data.get("token_usage") is not None or data.get("time_usage") is not None):
                    print(
                        f"[usage] req={request_id} tokens={data.get('token_usage')} time_ms={data.get('time_usage')}"
                    )
            else:
                print(f"[recv] {data}")
    except websockets.ConnectionClosed as exc:
        print(
            f"[client] 连接关闭: code={getattr(exc, 'code', None)} reason={getattr(exc, 'reason', '')}"
        )
    finally:
        stop_event.set()


async def vital_sender(ws, stop_event: asyncio.Event) -> None:
    while not stop_event.is_set():
        payload = {
            "timestamp": now_iso(),
            "heart_rate": round(random.uniform(70, 90), 1),
            "breath_rate": round(random.uniform(12, 20), 1),
            "breath_amp": round(random.uniform(0.5, 1.0), 3),
            "conf": round(random.uniform(0.8, 0.99), 3),
            "init_stat": 1,
            "presence_status": 1,
        }
        await _ws_send(ws, "vital", payload)
        await asyncio.sleep(2.0)


async def audio_sender(ws, stop_event: asyncio.Event, cfg: ClientConfig) -> None:
    if not pyaudio_available():
        print("[client] 未安装 pyaudio，跳过音频采集（可用 requirements-audio.txt 安装）")
        return

    import pyaudio  # type: ignore

    pa = pyaudio.PyAudio()
    try:
        stream = pa.open(
            format=pyaudio.paInt16,
            channels=cfg.aac_channels,
            rate=cfg.aac_rate,
            input=True,
            frames_per_buffer=cfg.aac_chunk,
        )
    except Exception as exc:
        print(f"[client] 打开麦克风失败: {exc}")
        pa.terminate()
        return

    encoder = AACEncoder(rate=cfg.aac_rate, channels=cfg.aac_channels)
    if not encoder.start():
        print("[client] ffmpeg 不可用，跳过 AAC 编码（请先安装 ffmpeg）")
        stream.close()
        pa.terminate()
        return

    print("[client] 启动音频采集(AAC)...")
    chunk_idx = 0
    try:
        while not stop_event.is_set():
            try:
                pcm_data = await asyncio.to_thread(stream.read, cfg.aac_chunk, False)
            except Exception as exc:
                print(f"[client] 读取麦克风失败: {exc}")
                break

            encoder.encode(pcm_data)
            for pkt in encoder.get_packets():
                b64 = base64.b64encode(pkt).decode("ascii")
                payload = {
                    "timestamp": now_iso(),
                    "chunk_index": chunk_idx,
                    "codec": "AAC",
                    "sample_rate": cfg.aac_rate,
                    "channels": cfg.aac_channels,
                    "data": b64,
                    "size": len(pkt),
                }
                await _ws_send(ws, "audio", payload)
                chunk_idx += 1

            await asyncio.sleep(0.001)
    finally:
        stop_event.set()
        encoder.close()
        try:
            stream.stop_stream()
        except Exception:
            pass
        stream.close()
        pa.terminate()
        print("[client] 音频采集结束")


async def video_sender(ws, stop_event: asyncio.Event, cfg: ClientConfig) -> None:
    if not video_deps_available():
        print("[client] 未安装 opencv-python/av，跳过视频采集（可用 requirements-video.txt 安装）")
        return

    import cv2  # type: ignore

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("[client] 无法打开摄像头，跳过视频采集")
        return

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, cfg.video_width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, cfg.video_height)
    cap.set(cv2.CAP_PROP_FPS, cfg.video_fps)

    actual_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) or cfg.video_width
    actual_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or cfg.video_height
    actual_fps = int(cap.get(cv2.CAP_PROP_FPS)) or cfg.video_fps

    try:
        encoder = H264Encoder(VideoParams(actual_width, actual_height, actual_fps))
    except Exception as exc:
        print(f"[client] 视频编码器不可用: {exc}")
        cap.release()
        return

    frame_idx = 0
    print(f"[client] 启动视频采集(H.264) {actual_width}x{actual_height}@{actual_fps}fps ...")
    try:
        while not stop_event.is_set():
            ret, frame = cap.read()
            if not ret:
                print("[client] 读取视频帧失败，停止视频采集")
                break

            packets = encoder.encode(frame, frame_idx)
            for pkt in packets:
                b64 = base64.b64encode(pkt).decode("ascii")
                payload = {
                    "timestamp": now_iso(),
                    "frame_index": frame_idx,
                    "codec": "H264",
                    "width": actual_width,
                    "height": actual_height,
                    "data": b64,
                    "size": len(pkt),
                }
                await _ws_send(ws, "video", payload)

            frame_idx += 1
            await asyncio.sleep(1.0 / max(1, actual_fps))
    finally:
        stop_event.set()
        cap.release()
        for pkt in encoder.flush():
            b64 = base64.b64encode(pkt).decode("ascii")
            payload = {
                "timestamp": now_iso(),
                "frame_index": frame_idx,
                "codec": "H264",
                "width": actual_width,
                "height": actual_height,
                "data": b64,
                "size": len(pkt),
            }
            await _ws_send(ws, "video", payload)
            frame_idx += 1
        print("[client] 视频采集结束")


async def run_client(
    cfg: ClientConfig,
    *,
    enable_audio: bool = True,
    enable_video: bool = True,
    enable_vital: bool = True,
    send_initial_text: bool = True,
) -> None:
    if not cfg.api_token:
        print("[client] 警告：未提供 API_TOKEN/WS_TOKEN；如果服务端需要鉴权，连接会失败。")

    stop_event = asyncio.Event()
    gateway_url = build_gateway_ws_url(cfg.ws_url, cfg.api_token if not cfg.token_in_header else None)
    extra_headers = build_gateway_headers(cfg.api_token, cfg.token_in_header)

    connect_kwargs: Dict[str, Any] = {"max_size": None}
    if extra_headers:
        # websockets>=15 使用 additional_headers，旧版本使用 extra_headers
        import inspect

        if "additional_headers" in inspect.signature(websockets.connect).parameters:
            connect_kwargs["additional_headers"] = extra_headers
        else:  # pragma: no cover
            connect_kwargs["extra_headers"] = extra_headers

    print(f"[client] 连接到 {gateway_url}")
    async with websockets.connect(gateway_url, **connect_kwargs) as ws:
        tasks = [asyncio.create_task(recv_loop(ws, stop_event))]
        if enable_audio:
            tasks.append(asyncio.create_task(audio_sender(ws, stop_event, cfg)))
        if enable_video:
            tasks.append(asyncio.create_task(video_sender(ws, stop_event, cfg)))
        if enable_vital:
            tasks.append(asyncio.create_task(vital_sender(ws, stop_event)))

        if cfg.warmup_sec > 0:
            print(f"[client] 等待 {cfg.warmup_sec:.1f}s 收集初始多模态数据...")
            await asyncio.sleep(cfg.warmup_sec)

        if send_initial_text:
            await _ws_send(ws, "text", _build_initial_payload(cfg))

        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            stop_event.set()
            for t in tasks:
                t.cancel()
            await asyncio.sleep(0.1)


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="emotion-gateway-client", add_help=True)
    p.add_argument("--ws-url", default=os.getenv("WS_URL", ""), help="WebSocket URL（不含 token 也可）")
    p.add_argument("--token", default=os.getenv("API_TOKEN") or os.getenv("WS_TOKEN") or "", help="API token")
    p.add_argument("--token-in-header", action="store_true", default=os.getenv("TOKEN_IN_HEADER", "0").lower() in {"1","true","yes"})
    p.add_argument("--user-id", default=os.getenv("USER_ID", "11"))
    p.add_argument("--snapshot-window-sec", type=float, default=float(os.getenv("SNAPSHOT_WINDOW_SEC", "15")))
    p.add_argument("--warmup-sec", type=float, default=float(os.getenv("CLIENT_WARMUP_SEC", "2.0")))

    p.add_argument("--no-audio", action="store_true", help="禁用麦克风采集与 AAC 发送")
    p.add_argument("--no-video", action="store_true", help="禁用摄像头采集与 H.264 发送")
    p.add_argument("--no-vital", action="store_true", help="禁用生命体征假数据发送")
    p.add_argument("--send-initial-text", action="store_true", help="连接后发送 text 触发分析")
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    if not args.ws_url:
        print("缺少 --ws-url 或环境变量 WS_URL", file=sys.stderr)
        return 2

    cfg = ClientConfig(
        ws_url=args.ws_url,
        api_token=(args.token.strip() or None),
        token_in_header=bool(args.token_in_header),
        user_id=args.user_id,
        snapshot_window_sec=float(args.snapshot_window_sec),
        warmup_sec=float(args.warmup_sec),
    )

    try:
        asyncio.run(
            run_client(
                cfg,
                enable_audio=not args.no_audio,
                enable_video=not args.no_video,
                enable_vital=not args.no_vital,
                send_initial_text=bool(args.send_initial_text),
            )
        )
    except KeyboardInterrupt:
        print("\n[client] 手动退出")
        return 0
    return 0

