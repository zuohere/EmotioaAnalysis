from __future__ import annotations

import os
import queue
import subprocess
import threading
import time
from dataclasses import dataclass
from fractions import Fraction
from typing import List, Optional


def _try_import_pyaudio():
    try:
        import pyaudio  # type: ignore

        return pyaudio
    except Exception:
        return None


def _try_import_video_deps():
    try:
        import av  # type: ignore
        import cv2  # type: ignore

        return av, cv2
    except Exception:
        return None, None


@dataclass(frozen=True)
class VideoParams:
    width: int
    height: int
    fps: int


class H264Encoder:
    """简单的 H.264 编码器（基于 PyAV）。"""

    def __init__(self, params: VideoParams):
        self.params = params
        self._av, _ = _try_import_video_deps()
        self.encoder = self._create_encoder()

    def _create_encoder(self):
        if not self._av:
            return None
        av = self._av
        errors: List[str] = []
        for codec_name in ("libx264", "h264"):
            try:
                enc = av.codec.CodecContext.create(codec_name, "w")
                enc.width = self.params.width
                enc.height = self.params.height
                enc.pix_fmt = "yuv420p"
                enc.time_base = Fraction(1, self.params.fps)
                enc.framerate = Fraction(self.params.fps, 1)
                enc.options = {
                    "preset": "ultrafast",
                    "tune": "zerolatency",
                    "crf": "23",
                }
                enc.open()
                return enc
            except Exception as exc:
                errors.append(f"{codec_name}: {exc}")
        raise RuntimeError(f"无法创建H.264编码器: {'; '.join(errors)}")

    def encode(self, frame_bgr, frame_idx: int) -> List[bytes]:
        if not self.encoder or not self._av:
            return []
        av = self._av
        try:
            video_frame = av.VideoFrame.from_ndarray(frame_bgr, format="bgr24")
            video_frame.pts = frame_idx
            packets = self.encoder.encode(video_frame)
            return [bytes(pkt) for pkt in packets]
        except Exception:
            return []

    def flush(self) -> List[bytes]:
        if not self.encoder:
            return []
        try:
            return [bytes(pkt) for pkt in self.encoder.encode(None)]
        except Exception:
            return []


class AACEncoder:
    """AAC 编码器：使用 ffmpeg 将 PCM 转换为 ADTS 流。"""

    def __init__(self, rate: int, channels: int):
        self.rate = rate
        self.channels = channels
        self.proc: Optional[subprocess.Popen] = None
        self.queue: "queue.Queue[Optional[bytes]]" = queue.Queue()
        self.reader: Optional[threading.Thread] = None

    def start(self) -> bool:
        ffmpeg_cmd = [
            "ffmpeg",
            "-f",
            "s16le",
            "-ar",
            str(self.rate),
            "-ac",
            str(self.channels),
            "-i",
            "pipe:0",
            "-c:a",
            "aac",
            "-b:a",
            "64k",
            "-profile:a",
            "aac_low",
            "-frame_duration",
            "10",
            "-cutoff",
            "12000",
            "-f",
            "adts",
            "-flush_packets",
            "1",
            "-fflags",
            "+flush_packets+nobuffer",
            "-max_delay",
            "0",
            "-avioflags",
            "direct",
            "pipe:1",
        ]
        try:
            self.proc = subprocess.Popen(
                ffmpeg_cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except FileNotFoundError:
            return False
        except Exception:
            return False

        self.reader = threading.Thread(target=self._drain_stdout, daemon=True)
        self.reader.start()
        return True

    def _drain_stdout(self) -> None:
        if not self.proc or not self.proc.stdout:
            return

        # 非阻塞读取（Linux/macOS）
        try:
            import fcntl  # type: ignore
            import select  # type: ignore

            fd = self.proc.stdout.fileno()
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

            while True:
                if self.proc.poll() is not None:
                    break
                ready, _, _ = select.select([self.proc.stdout], [], [], 0.05)
                if not ready:
                    continue
                try:
                    chunk = self.proc.stdout.read(4096) or b""
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    self.queue.put(chunk)
                else:
                    time.sleep(0.005)
        except Exception:
            # 退化为阻塞读
            while True:
                if self.proc.poll() is not None:
                    break
                chunk = self.proc.stdout.read(4096) if self.proc.stdout else b""
                if chunk:
                    self.queue.put(chunk)
                else:
                    time.sleep(0.01)

        self.queue.put(None)

    def encode(self, pcm: bytes) -> None:
        if not self.proc or not self.proc.stdin:
            return
        try:
            self.proc.stdin.write(pcm)
            self.proc.stdin.flush()
        except Exception:
            return

    def get_packets(self) -> List[bytes]:
        packets: List[bytes] = []
        while True:
            try:
                item = self.queue.get_nowait()
            except queue.Empty:
                break
            if item is None:
                break
            packets.append(item)
        return packets

    def close(self) -> None:
        if not self.proc:
            return
        try:
            if self.proc.stdin:
                try:
                    self.proc.stdin.close()
                except Exception:
                    pass
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        finally:
            self.proc = None


def pyaudio_available() -> bool:
    return _try_import_pyaudio() is not None


def video_deps_available() -> bool:
    av, cv2 = _try_import_video_deps()
    return av is not None and cv2 is not None

