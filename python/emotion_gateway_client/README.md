## Emotion Gateway Client（多模态 WebSocket 客户端）

这是从你提供的 `client.py` 重构出来的 **可复用 Python 模块**，用于向网关 WebSocket 发送多模态数据：

- **text**：触发后端开始分析（支持 `prep_data`、`snapshot_window_sec`）
- **audio**：AAC(ADTS) 音频分片（可选，需要 `pyaudio` + `ffmpeg`）
- **video**：H.264 视频分片（可选，需要 `opencv-python` + `av`）
- **vital**：心率/呼吸等生命体征（可用假数据模拟）

> 说明：本模块与 iOS 端的 `CameraAccess/EmotionAnalysisManager.swift` 使用同一类协议字段（`message_type` + `payload`，以及 `payload.emotion_result`）。

### 安装

建议使用虚拟环境：

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r python/emotion_gateway_client/requirements-base.txt
```

如果需要采集音频/视频：

```bash
pip install -r python/emotion_gateway_client/requirements-audio.txt
pip install -r python/emotion_gateway_client/requirements-video.txt
```

### 配置（重要：不要把 Token 写进代码）

通过环境变量或命令行参数配置：

- `WS_URL`：例如 `wss://api.finnox.cn/gateway/v1/proxy/ws`
- `API_TOKEN`：你的 token（默认会以 query 形式附加为 `?token=...`）
- `TOKEN_IN_HEADER=1`：将 token 放在 `Authorization: Bearer ...`（可选）
- `USER_ID`：默认 `11`

也可以写一个 `.env`（自行创建，不要提交到仓库）。本目录提供了 `env.example` 作为模板：

```bash
cp python/emotion_gateway_client/env.example .env
source .env
```

### 运行

最小运行（不采集音频/视频，仅发送 vital + text）：

```bash
python -m emotion_gateway_client --send-initial-text --no-audio --no-video
```

开启摄像头/麦克风（需要额外依赖 + 本机设备权限）：

```bash
python -m emotion_gateway_client --send-initial-text
```

### 常见问题

- **ffmpeg 未安装**：音频 AAC 编码依赖系统 `ffmpeg` 可执行文件。
- **macOS 摄像头/麦克风权限**：首次运行可能弹窗，需要在系统设置里允许终端/IDE 访问。

