//
//  EmotionAnalysisManager.swift
//  CameraAccess
//
//  Created by zora on 2026/1/19.
//

import Foundation
import AVFoundation
import UIKit // 用于图像处理
import VideoToolbox
import OSLog
import MetricKit

private let performanceLog = OSLog(subsystem: "com.turbometa.emotion", category: "DataFlow")

// MARK: - 核心管理器
class EmotionAnalysisManager: NSObject, ObservableObject
{
    // 在 EmotionAnalysisManager 类顶部定义
    // swift
    private let audioSendSemaphore = DispatchSemaphore(value: 1)
    private var audioChunkIndex = 0
    private let audioEngine = AVAudioEngine()
        
        // 1. 声明持久化的转换器 (use `audioConverter` below)
        
        // 2. 目标格式：必须与你 Python 后端的 AAC_RATE 一致
    let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
    lazy var aacFormat: AVAudioFormat = {
            return AVAudioFormat(settings: aacSettings)!
        }()
    private var triggerRequestTimer: Timer?
    private let videoQueue = DispatchQueue(label: "com.emotion.videoSend", qos: .userInteractive)
    
    static let shared = EmotionAnalysisManager()
    private var heartbeatTimer: Timer?
    private var frameIndex = 0
    private var webSocketTask: URLSessionWebSocketTask?
    // Outgoing message queue (stores serialized JSON strings)
    private var outgoingQueue = [String]()
    private let outgoingQueueLock = DispatchQueue(label: "com.turbometa.outgoingQueue", qos: .userInitiated)
    private let outgoingWorkerQueue = DispatchQueue(label: "com.turbometa.outgoingWorker", qos: .utility)
    private let session = URLSession(configuration: .default)
    private var videoEncoder: H264Encoder?
    private var isRunning = false
    private var isAudioEnabled = false
    private var currentRequestId: String?
    private let userId = "11"
    private var audioConverter: AVAudioConverter? // 只初始化一次
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
    
    private let processingQueue = DispatchQueue(label: "com.turbometa.emotion.processing", qos: .userInteractive)
    
    
    // Build a 7-byte ADTS header for an AAC frame
    private func adtsHeader(aacLength: Int, sampleRate: Int, channels: UInt8, profile: UInt8 = 2) -> Data {
        // ADTS header is 7 bytes long
        let adtsLength = aacLength + 7

        // Mapping common sample rates to ADTS freq index
        let freqIdxLookup: [Int: UInt8] = [96000:0, 88200:1, 64000:2, 48000:3, 44100:4, 32000:5, 24000:6, 22050:7, 16000:8, 12000:9, 11025:10, 8000:11, 7350:12]
        let freqIdx: UInt8 = freqIdxLookup[sampleRate] ?? 6 // default to 24000 if unknown

        var packet = [UInt8](repeating: 0, count: 7)
        packet[0] = 0xFF
        packet[1] = 0xF1 // syncword(12) + MPEG-4 + layer + protection_absent
        packet[2] = ((profile - 1) << 6) | (freqIdx << 2) | (channels >> 2)
        packet[3] = ((channels & 3) << 6) | UInt8((adtsLength >> 11) & 0x03)
        packet[4] = UInt8((adtsLength >> 3) & 0xFF)
        packet[5] = UInt8(((adtsLength & 0x7) << 5) | 0x1F)
        packet[6] = 0xFC
        return Data(packet)
    }

    private let wsURL: URL = {
            // 检查字符串里有没有空格或换行
            let token = "25942d659fd81c3a4faa8deae5d3e278.CwjYQzIEqF1uHX0f7EG9CiBfZN14qRimke4lixE9dzw"
            let urlStr = "wss://api.finnox.cn/gateway/v1/proxy/ws?token=\(token)"
//            let urlStr = "ws://10.10.40.232:8900/ws"
            
            if let url = URL(string: urlStr) {
                return url
            } else {
                print("❌ 严重错误: URL 格式不正确，请检查 Token 是否包含空格")
                return URL(string: "wss://localhost")! // 防止崩溃的保底地址
            }
        }()

    
    @Published var isConnected: Bool = false {
        didSet {
            if isConnected {
                print("🌐 WebSocket 连接成功，等待 1s 执行初始化...")
                
                // ✅ 改进：增加防抖延迟，避免频繁重连信号抖动
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.isConnected else { return }
                    print("🌐 WebSocket 已连接，开始 2 秒数据预热（不发指令，只推流）...")
                    
                    // 给音视频编码和传输留出时间，确保后端缓冲区有数据
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if self.isConnected {
                            print("🚀 预热结束，发送正式分析指令")
                            self.sendTriggerRequest()
                        }
                    }
                }
            }
        }
    }
    @Published var emotionResult: String = "等待分析..."
    @Published var emotionScores: [String: Double] = [:] // 存储 happy, sad 等具体数值
    @Published var aiReasoning: String = "正在观察微表情与语调..." // 深度推理
    @Published var aiAdvice: String = "正在分析..." // 建议
    @Published var dominantEmotion: String = "Neutral" // 当前主导情绪
    
    
    // 计数器
    
    // 启动分析
    func start() {
        guard !isRunning else { return }
        print("[Emotion] 🚀 启动分析模块")
        isRunning = true
        // ✅ 修复：立即启用音频，而不是等待 15s 后
        isAudioEnabled = true
        currentRequestId = nil
        connectWebSocket()
        startFakeVitalSigns()
        startTriggerRequestTimer() // 启动每15秒发送一次触发请求
        checkMicrophonePermissionAndStartAudio() // 权限检查后启动音频捕获
    }
    
    // 停止分析
    func stop() {
        print("[Emotion] 🛑 停止分析模块")
        isRunning = false
        isAudioEnabled = false
        currentRequestId = nil
        disconnectWebSocket()
        videoEncoder = nil
        stopTriggerRequestTimer() // 停止定时器
        stopAudioCapture()
        
        // ✅ 新增：停用音频会话
        deactivateAudioSession()
    }
//    func startHeartbeat() {
//        // 1. 停止旧的计时器
//        heartbeatTimer?.invalidate()
//        
//        // 2. 每 5 秒发送一次极简包
//        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
//            guard let self = self, self.isConnected else { return }
//            let payload: [String: Any] = ["timestamp": Date().timeIntervalSince1970]
//            self.sendMessage(type: "ping", payload: payload)
//            print("📡 [Heartbeat] Ping sent")
//        }
//    }
    // MARK: - 音频会话配置
    private func configureAudioSession() {
         let audioSession = AVAudioSession.sharedInstance()
         do {
             // 推荐 playAndRecord，兼容更多设备
             try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
             try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
             // AudioSession configured and activated (log removed)
         } catch {
            // AudioSession configuration/activation failed (log removed): \(error.localizedDescription)
         }
     }

     private func deactivateAudioSession() {
         let audioSession = AVAudioSession.sharedInstance()
         do {
             try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            // AudioSession deactivated (log removed)
         } catch {
            // AudioSession deactivation failed (log removed): \(error.localizedDescription)
         }
     }
    
    
    // MARK: - 视频输入接口
    
    /// 接收 CVPixelBuffer (从 StreamSessionViewModel 传入)
    func processVideoFrame(_ pixelBuffer: CVPixelBuffer) {
            print("[Video] processVideoFrame called - isRunning=\(isRunning) isConnected=\(isConnected) bufferWidth=\(CVPixelBufferGetWidth(pixelBuffer)) bufferHeight=\(CVPixelBufferGetHeight(pixelBuffer))")
             // 🔒 丢帧保护：如果网络还没发完，或者模块没启动，直接丢弃，不占内存
             guard isRunning, isConnected else { return }
            
            processingQueue.async { [weak self] in
                guard let self = self else { return }
                
                // 💡 直接操作 Buffer 进行中心裁剪 (1280x640)
                // 这里我们调用 buffer(from: UIImage) 逻辑的逆过程，或者为了兼容性
                // 暂时沿用 UIImage 裁剪，但必须在异步队列中完成以防 Code 22
                
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let context = CIContext()
                guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
                
                let originalImage = UIImage(cgImage: cgImage)
                let cropRect = CGRect(
                    x: (originalImage.size.width - 1280) / 2,
                    y: (originalImage.size.height - 640) / 2,
                    width: 1280,
                    height: 640
                )
                
                guard let croppedCG = cgImage.cropping(to: cropRect) else { return }
                let croppedUIImage = UIImage(cgImage: croppedCG)
                
                // 缩放到 360x180 (2:1 比例)
                let targetSize = CGSize(width: 360, height: 180)
                UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
                croppedUIImage.draw(in: CGRect(origin: .zero, size: targetSize))
                let finalImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                
                if let processed = finalImage, let buffer = self.buffer(from: processed) {
                    print("[Video] Cropped and resized frame ready for encoding.")
                    self.encodeAndSend(buffer)
                } else {
                    print("[Video] Failed to crop/resize frame.")
                }
            }
        }
    // 确保这个方法在 EmotionAnalysisManager 类的大括号内
    private func sendVideoData(_ data: Data, isKeyframe: Bool) {
//        print("[Video] Sending video data: size=\(data.count), frame_index=\(frameIndex)")
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "frame_index": frameIndex,
            "codec": "H264",
            "width": 360,
            "height": 180,
            "is_keyframe": isKeyframe,
            "data": data.base64EncodedString(),
            "size": data.count
        ]
         self.sendMessage(type: "video", payload: payload, isPriority: true)
        frameIndex += 1
    }
    
    private func encodeAndSend(_ pixelBuffer: CVPixelBuffer) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        
        // 如果编码器尚未创建，或者分辨率发生变化，则重新创建
        if videoEncoder == nil || videoEncoder?.width != w || videoEncoder?.height != h {
            print("[Video] 🚀 初始化 H264 编码器: \(w)x\(h)")
            let newEncoder = H264Encoder()
            newEncoder.configure(width: w, height: h)
            
            // ✅ 核心修复：挂载回调，将编码后的 Data 送往 WebSocket
            newEncoder.callback = { [weak self] (data, isKeyframe) in
                self?.sendVideoData(data, isKeyframe: isKeyframe)
            }
            
            self.videoEncoder = newEncoder
        }
        
        // 喂入像素数据进行编码
        videoEncoder?.encode(pixelBuffer)
    }
    // swift
    private func checkMicrophonePermissionAndStartAudio() {
        print("[Audio] 📋 检查麦克风权限...")
        if #available(iOS 17.0, *) {
            // iOS 17+：使用新 API
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        print("[Audio] ✅ 麦克风权限已获得 (iOS 17+)")
                        self?.configureAudioSession()
                        self?.startAudioCapture()
                    } else {
                        print("[Audio] ❌ 麦克风权限被拒绝 (iOS 17+) - 请在设置中启用")
                    }
                }
            }
        } else {
            // iOS 16 及以下：使用旧 API
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        print("[Audio] ✅ 麦克风权限已获得 (iOS 16-)")
                        self?.configureAudioSession()
                        self?.startAudioCapture()
                    } else {
                        print("[Audio] ❌ 麦克风权限被拒绝 (iOS 16-) - 请在设置中启用")
                    }
                }
            }
        }
    }
    func startAudioCapture() {
        print("[Audio] 🎙️ 启动音频捕获...")
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // ✅ 改进：提前初始化和验证 converter
            audioConverter = AVAudioConverter(from: recordingFormat, to: aacFormat)
            guard let audioConverter = audioConverter else {
                print("[Audio] ❌ 无法创建 AAC 转换器")
                return
            }
            audioConverter.bitRate = 64000
            print("[Audio] ✅ AAC 转换器已创建: \(recordingFormat.sampleRate)Hz → \(aacFormat.sampleRate)Hz")
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            
            // ✅ 改进：分别检查每个条件，便于调试
            guard self.isRunning else { 
                // 静默返回，这是正常情况
                return 
            }
            guard self.isConnected else { 
                // 静默返回，等待连接
                return 
            }
            guard self.isAudioEnabled else { 
                // 静默返回，等待后端准备好
                return 
            }
            guard let converter = self.audioConverter else { 
                print("[Audio] ⚠️ 转换器为 nil")
                return 
            }
            
            let aacBuffer = AVAudioCompressedBuffer(format: self.aacFormat, packetCapacity: 32, maximumPacketSize: converter.maximumOutputPacketSize)

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            let status = converter.convert(to: aacBuffer, error: &error, withInputFrom: inputBlock)
            // ✅ 改为检查 status
            guard status == .haveData, aacBuffer.packetCount > 0 else {
                print("[Audio] AAC 编码失败或无数据: status=\(status), packetCount=\(aacBuffer.packetCount)")
                return
            }

            // Prefer per-packet ADTS framing if packet descriptions are provided
            var outData = Data()
            let sampleRate = Int(self.aacFormat.sampleRate)
            let channelCount = UInt8(self.aacFormat.channelCount)

            if let packetDescPtr = aacBuffer.packetDescriptions {
                let packetDescBuffer = UnsafeBufferPointer(start: packetDescPtr, count: Int(aacBuffer.packetCount))
                for desc in packetDescBuffer {
                    let start = Int(desc.mStartOffset)
                    let size = Int(desc.mDataByteSize)
                    if size <= 0 { continue }
                    let packetBytes = Data(bytes: aacBuffer.data.advanced(by: start), count: size)
                    let header = self.adtsHeader(aacLength: size, sampleRate: sampleRate, channels: channelCount)
                    outData.append(header)
                    outData.append(packetBytes)
                }
            } else {
                // Fallback: treat whole buffer as a single AAC packet
                let aacData = Data(bytes: aacBuffer.data, count: Int(aacBuffer.byteLength))
                let header = self.adtsHeader(aacLength: aacData.count, sampleRate: sampleRate, channels: channelCount)
                outData.append(header)
                outData.append(aacData)
            }

            let aacPayload: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "chunk_index": self.audioChunkIndex,
                "codec": "AAC",
                "sample_rate": sampleRate,
                "channels": Int(channelCount),
                "data": outData.base64EncodedString(),
                "size": outData.count
            ]
            wsSendQueue.async {
                print("[Audio] 📤 发送 AAC chunk: index=\(self.audioChunkIndex) size=\(outData.count) bytes")
                self.sendMessage(type: "audio", payload: aacPayload)
                }
            self.audioChunkIndex += 1
         }
         do {
             try audioEngine.start()
             print("[Audio] ✅ 音频引擎已启动，开始捕获")
         } catch {
             print("[Audio] ❌ 音频引擎启动失败: \(error.localizedDescription)")
         }
     }
        
    // MARK: - 音频停止输入接口
    func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

        // MARK: - 通信与保活 (基于 Payload 标准)

        private func sendTriggerRequest() {
            let reqId = "req-" + UUID().uuidString
            currentRequestId = reqId
            let payload: [String: Any] = [
                "request_id": reqId,
                "user_id": userId,
                "messages": [["role": "user", "content": "s"]], // ✅ 模拟按键 's' 激活后端
                "prep_data": [
                    "user_prompt": ["scene": "Live", "intention": "情绪分析", "analysis": "输出建议"]
                ],
                "snapshot_window_sec": 6,
                "is_last": false
            ]
            isAudioEnabled = true
            sendMessage(type: "text", payload: payload)
        }

        private func startMaintenanceHeartbeat() {
            heartbeatTimer?.invalidate()
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isConnected else { return }
                let payload: [String: Any] = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "presence_status": 1
                ]
                self.sendMessage(type: "vital", payload: payload) // ✅ 使用 vital 包保活
            }
        }
    
    
    // MARK: - WebSocket 逻辑
    
    private func connectWebSocket() {
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        
        // ✅ 这里直接认为「传输通道已建立」，允许先发起首包/指令
        // 如果服务端还有「业务就绪」概念，可以另外加业务层状态，而不是卡在物理连接上
        DispatchQueue.main.async {
            if !self.isConnected {
                self.isConnected = true
            }
        }
        
        print("[Emotion] WebSocket 连接已发起 (socket resumed)...")
        
        // 开始接收消息
        receiveMessage()
        
        // 稍后尝试刷新队列并发送初始包（仍可保留短延迟）
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            self.flushOutgoingQueue()
            self.sendInitialText()
        }
    }
    final class AudioBatcher {

        // ===== 配置参数 =====
        private let targetBatchBytes = 3200    // ≈ 100ms @ 16kHz mono PCM16
        private let maxQueueBytes = 64 * 1024   // 防止无限堆积
        private let sendInterval: TimeInterval = 0.05 // 20 FPS

        // ===== 依赖 =====
        private let send: (Data) -> Void

        // ===== 内部状态 =====
        private var buffer = Data()
        private let queue = DispatchQueue(label: "audio.batching.queue")
        private var timer: DispatchSourceTimer?

        init(send: @escaping (Data) -> Void) {
            self.send = send
            startTimer()
        }

        // ===== 外部入口 =====
        func append(_ data: Data) {
            queue.async {
                // 限制总缓存
                if self.buffer.count + data.count > self.maxQueueBytes {
                    print("⚠️ [AudioBatcher] buffer overflow, drop old audio")
                    self.buffer.removeFirst(min(self.buffer.count, data.count))
                }
                self.buffer.append(data)
            }
        }

        // ===== 定时 flush =====
        private func startTimer() {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer?.schedule(deadline: .now() + sendInterval, repeating: sendInterval)
            timer?.setEventHandler { [weak self] in
                self?.flush()
            }
            timer?.resume()
        }

        private func flush() {
            guard buffer.count >= targetBatchBytes else { return }

            let chunk = buffer.prefix(targetBatchBytes)
            buffer.removeFirst(targetBatchBytes)

            send(chunk)
        }

        deinit {
            timer?.cancel()
        }
    }

    // swift（保留这个版本，删除重复的）
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    self.handleMessageData(data)
                @unknown default:
                    break
                }
                self.flushOutgoingQueue()

                if self.isConnected {
                    self.receiveMessage()  // 递归继续监听
                }
                
            case .failure(let error):
                print("[Emotion] WebSocket Error: \(error)")
                self.disconnectWebSocket()
            }
        }
    }

    
    private func disconnectWebSocket() {
            print("[Emotion] WebSocket 断开连接")
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            
            DispatchQueue.main.async {
                self.isConnected = false
                
                // 🔥🔥 新增：销毁编码器
                // 这样下次连接时会重新创建，从而强制发送 SPS/PPS 和 关键帧
                self.videoEncoder = nil
                print("[Emotion] 编码器已重置，等待下一次会话")
            }
        }
    
    

    
    // Thread-safe sender: queue when not connected, flush when possible
    // swift
    private let wsSendQueue = DispatchQueue(label: "ws.send.queue")
    // MARK: - 优化后的发送系统
    private func sendMessage(type: String, payload: Any, isPriority: Bool = false) {
        guard isRunning else { return }

        var finalPayload = payload
        // 1. 快速数据清理
        if var dict = payload as? [String: Any] {
            if let dataStr = dict["data"] as? String {
                dict["data"] = dataStr.components(separatedBy: .whitespacesAndNewlines).joined()
            }
            if let requestId = currentRequestId, dict["request_id"] == nil {
                dict["request_id"] = requestId
            }
            finalPayload = dict
        }

        var msg: [String: Any] = ["message_type": type, "payload": finalPayload]
        if let requestId = currentRequestId {
            msg["request_id"] = requestId
        }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }

        // 2. 视频帧(H264)和触发指令(Text)强制设为高优先级
        let needsPriority = isPriority || (type == "video" || type == "text")

        outgoingQueueLock.async { [weak self] in
            guard let self = self else { return }
            
            if needsPriority {
                // 高优先级插到队首，确保后端在 15s 窗口内优先看到脸
                self.outgoingQueue.insert(json, at: 0)
            } else {
                // 普通媒体数据，如果积压严重则直接丢弃旧包（防止 Code 57）
                if self.outgoingQueue.count > 15 {
                    self.outgoingQueue.removeFirst(self.outgoingQueue.count - 10)
                    print("⚠️ [Queue] 拥塞丢包：清理旧音频/体征数据")
                }
                self.outgoingQueue.append(json)
            }
            
            // 3. 立即触发同步发送逻辑
            self.flushOutgoingQueue()
        }
    }

    private func flushOutgoingQueue() {
        // 提升 QOS 解决线程优先级反转
        outgoingWorkerQueue.async { [weak self] in
            guard let self = self, self.isConnected, let task = self.webSocketTask else { return }
            
            while true {
                var msgToSend: String?
                self.outgoingQueueLock.sync {
                    if !self.outgoingQueue.isEmpty {
                        msgToSend = self.outgoingQueue.removeFirst()
                    }
                }

                guard let msg = msgToSend else { break }

                // 4. 模拟同步发送：使用信号量阻塞 worker 线程直到该包发出
                let semaphore = DispatchSemaphore(value: 0)
                task.send(.string(msg)) { error in
                    if let err = error {
                        print("❌ [Flush] 发送失败: \(err.localizedDescription)")
                        // 仅指令重入队，音视频丢弃防止死循环
                    }
                    semaphore.signal()
                }
                
                // 等待当前包发完再发下一个，确保顺序和低延迟
                let result = semaphore.wait(timeout: .now() + 1.0)
                if result == .timedOut { break }
            }
        }
    }


    private func enqueueOutgoing(_ json: String) {
        outgoingQueueLock.async {
            self.outgoingQueue.append(json)
            if self.outgoingQueue.count > 50 {
                        os_log("⚠️ [Network_Congestion] Queue size reached %d", log: performanceLog, type: .error, self.outgoingQueue.count)
                    }
            if self.outgoingQueue.count > 500 { self.outgoingQueue.removeFirst(self.outgoingQueue.count - 500) }
            print("[Queue] enqueued (size=\(self.outgoingQueue.count))")
        }
    }


    private func reconnectWebSocketIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.webSocketTask == nil || !self.isConnected {
                print("[Reconnect] attempting reconnect")
                self.connectWebSocket()
            }
        }
    }
    

    
    
    // MARK: - 视频输入接口
    
    // 在 EmotionAnalysisManager.swift 中找到这个方法并替换

    private func handleMessage(_ text: String) {
        print("📥 [Raw Data from Server]: \(text)")
        guard let data = text.data(using: .utf8) else { return }
        handleMessageData(data)
    }

    private func handleMessageData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        let messageType = json["message_type"] as? String
        
        if messageType == "chunk",
           let payload = json["payload"] as? [String: Any] {
            
            // 解析 emotion_result (这是你 client.py 里定义的结构)
            if let result = payload["emotion_result"] as? [String: Any] {
                let emotionBlock = result["emotion"] as? [String: Any]
                let scores = emotionBlock?["emotion"] as? [String: Double]
                let analysisText = emotionBlock?["analysis"] as? String
                let intention = result["intention"] as? [String: Any]
                let detected = intention?["detected_intentions"] as? [[String: Any]]
                let firstIntention = detected?.first
                let reasoning = firstIntention?["reasoning"] as? String
                let recommendedContent = intention?["recommended_content"] as? [String: Any]
                let suggestion = recommendedContent?["suggestion"] as? String

                DispatchQueue.main.async {
                    // 1. 提取详细情绪分数 (用于画图)
                    if let scores = scores {
                        self.emotionScores = scores
                        // 找出分数最高的情绪作为主导
                        self.dominantEmotion = scores.max { a, b in a.value < b.value }?.key ?? "Neutral"
                    }
                    
                    // 2. 提取建议 (Analysis 字段包含建议)
                    if let analysisText = analysisText {
                        self.emotionResult = analysisText // 简略版
                        self.aiAdvice = analysisText // 详细建议
                    }

                    // 2.1 如果后端有更明确的建议，优先覆盖
                    if let suggestion = suggestion, !suggestion.isEmpty {
                        self.aiAdvice = suggestion
                    }
                    
                    // 3. 提取深度推理 (Intention -> Reasoning)
                    if let reasoning = reasoning {
                        self.aiReasoning = reasoning
                    }
                }
                
                print("🧠 [更新数据] 主导情绪: \(self.dominantEmotion)")
            }
        }
    }
    
    // MARK: - 发送逻辑
    

    
    private func startFakeVitalSigns() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isRunning, self.isConnected else { return }
            
            // ✅ 优化：增大间隔从 2s 到 3s，减少发送频率以缓解拥塞
            let payload: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "heart_rate": Double.random(in: 70...90),
                "breath_rate": Double.random(in: 12...20),
                "breath_amp": Double.random(in: 0.5...1.0),
                "conf": 0.95,
                "init_stat": 1,
                "presence_status": 1
            ]
            self.sendMessage(type: "vital", payload: payload)
        }
    }
    
    private func sendInitialText() {
         let prepData: [String: Any] = [
             "user_prompt": [
                 "scene": "Ray-Ban眼镜第一视角",
                 "intention": "分析用户所处环境压力",
                 "analysis": "输出情绪标签与建议"
             ]
         ]
         let payload: [String: Any] = [
             "user_id": userId,
             "messages": [["role": "user", "content": "Start Analysis"]],
             "prep_data": prepData,
             "snapshot_window_sec": 15,
             "is_last": false
         ]
         sendMessage(type: "text", payload: payload)
     }
    
    // Public debug helper to send a synthetic audio payload from the Xcode console.
    // Usage (Xcode debug console):
    // expr -l Swift -- EmotionAnalysisManager.shared.debugSendTestAudio()
//    @objc public func debugSendTestAudio() {
//        let raw = "test-audio"
//        let b64 = raw.data(using: .utf8)!.base64EncodedString()
//        let payload: [String: Any] = [
//            "timestamp": ISO8601DateFormatter().string(from: Date()),
//            "chunk_index": self.audioChunkIndex,
//            "codec": "AAC",
//            "sample_rate": 24000,
//            "channels": 1,
//            "data": b64,
//            "size": b64.count
//        ]
//        print("[Debug] Sending synthetic audio payload (chunk_index=\(self.audioChunkIndex))")
//        self.sendMessage(type: "audio", payload: payload)
//        self.audioChunkIndex += 1
//    }
    // MARK: - 万能适配接口 (UIImage -> H.264)
    
    /// 当无法获取原始 buffer 时，使用此方法传入 UIImage
    // 在 EmotionAnalysisManager.swift 中

    func processUIImage(_ image: UIImage) {
        let signpostID = OSSignpostID(log: performanceLog)
                os_signpost(.begin, log: performanceLog, name: "ImageProcessing", signpostID: signpostID)
        guard isRunning, isConnected else { return }

        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // 1. 计算居中裁剪区域 (保持 2:1 比例)
            let originalSize = image.size
            let targetAspect: CGFloat = 2.0
            var cropWidth = originalSize.width
            var cropHeight = originalSize.height

            if originalSize.width / originalSize.height > targetAspect {
                cropWidth = originalSize.height * targetAspect
            } else {
                cropHeight = originalSize.width / targetAspect
            }

            let cropRect = CGRect(
                x: (originalSize.width - cropWidth) / 2,
                y: (originalSize.height - cropHeight) / 2,
                width: cropWidth,
                height: cropHeight
            )

            // 2. 执行裁剪与缩放
            guard let cgImage = image.cgImage?.cropping(to: cropRect) else { return }
            let targetSize = CGSize(width: 360, height: 180)
            
            UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
            let finalImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            // 3. 转换并直接送去编码
            if let processed = finalImage, let buffer = self.buffer(from: processed) {
                // 直接跳过原来的 processVideoFrame，直接去编码
                self.encodeAndSend(buffer)
            }
            
        }
    }
    
    // 辅助函数：UIImage 转 CVPixelBuffer
     private func buffer(from image: UIImage) -> CVPixelBuffer? {
        // Create a CVPixelBuffer with NV12 pixel format which is supported by VideoToolbox hardware encoder
        let width = Int(image.size.width)
        let height = Int(image.size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(pb, CVPixelBufferLockFlags(rawValue: 0)) }

        // Render UIImage -> CIImage -> CVPixelBuffer (NV12)
        let ciContext = CIContext(options: nil)
        var ciImage: CIImage?
        if let cg = image.cgImage {
            ciImage = CIImage(cgImage: cg)
        } else if let ci = image.ciImage {
            ciImage = ci
        } else {
            return nil
        }

        // Scale CIImage to target pixel buffer size if needed
        let imgExtent = ciImage!.extent
        if Int(imgExtent.width) != width || Int(imgExtent.height) != height {
            let scaleX = CGFloat(width) / imgExtent.width
            let scaleY = CGFloat(height) / imgExtent.height
            let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            ciImage = ciImage!.transformed(by: transform)
        }

        ciContext.render(ciImage!, to: pb)
        return pb
    }
    // MARK: - 辅助任务 (发送触发请求与保活)
    /// 步骤 B: 启动保活心跳，防止后端 10 秒杀进程
    func startTriggerRequestTimer() {
        triggerRequestTimer?.invalidate()
        triggerRequestTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            self.sendTriggerRequest()
        }
    }
    
    func stopTriggerRequestTimer() {
        triggerRequestTimer?.invalidate()
        triggerRequestTimer = nil
    }
}



// MARK: - H.264 硬件编码器 (终极修复版：AVCC 转 Annex B + 自动插入 SPS/PPS)
// ⚠️ 必须使用这个版本，否则后端无法解码，会直接断开连接 (TCP Reset)！

class H264Encoder {
    private var session: VTCompressionSession?
    var width: Int32 = 0
    var height: Int32 = 0
    var callback: ((Data, Bool) -> Void)? // 回调
    
    func configure(width: Int32, height: Int32) {
        self.width = width
        self.height = height

        // ✅ 必须指定像素格式，否则 VTCompressionSessionCreate 会失败
        let imageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,  // ✅ 关键修复
            compressedDataAllocator: nil,
            outputCallback: { (refCon, _, status, _, sampleBuffer) in
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon!).takeUnretainedValue()
                encoder.handleEncodedFrame(sampleBuffer)
            },
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("❌ H264: 创建会话失败 - status=\(status)")
            self.session = nil
            return
        }

        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        // ✅ 优化：设置码率限制到 500kbps 以减少网络压力
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 500000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("✅ H264: 编码器初始化成功 \(width)x\(height)")
    }
    
    func encode(_ pixelBuffer: CVPixelBuffer) {
//        print("[H264Encoder] encode called - sessionInitialized=\(session != nil), bufferWidth=\(CVPixelBufferGetWidth(pixelBuffer)), bufferHeight=\(CVPixelBufferGetHeight(pixelBuffer))")
        guard let session = session else { print("[H264Encoder] encode aborted - session nil"); return }
         let time = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000)
         
         let status = VTCompressionSessionEncodeFrame(
             session,
             imageBuffer: pixelBuffer,
             presentationTimeStamp: time,
             duration: .invalid,
             frameProperties: nil,
             sourceFrameRefcon: nil,
             infoFlagsOut: nil
         )
         
         if status != noErr {
             print("❌ H264: 编码帧失败 \(status)")
         }
     }
    // 在 H264Encoder 类中

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        // 1. 检查关键帧标识
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        
        var elementaryStream = Data()
        
        // 2. 关键帧必须先写入参数集 (SPS/PPS)
        if isKeyframe {
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var paramCount: Int = 0
                // 获取参数集数量
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil)
                
                for i in 0..<paramCount {
                    var parameterSetPointer: UnsafePointer<UInt8>?
                    var parameterSetLength: Int = 0
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    
                    if let pointer = parameterSetPointer {
                        // 标准 Annex B 起始码
                        elementaryStream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        elementaryStream.append(pointer, count: parameterSetLength)
                    }
                }
            }
        }
        
        // 3. 获取 AVCC 头的长度 (iOS 默认为 4 字节)
        var avccHeaderLength: Int32 = 4
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &avccHeaderLength)
        }
        let headerLen = Int(avccHeaderLength)

        // 4. 将 AVCC 包装的 NALU 转换为 Annex B
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr {
            var bufferOffset = 0
            while bufferOffset < totalLength - headerLen {
                var nalUnitLength: UInt32 = 0
                // 读取当前 NALU 的长度
                memcpy(&nalUnitLength, dataPointer! + bufferOffset, headerLen)
                // 大端转本机序 (关键一步)
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
                
                // 写入起始码
                elementaryStream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                
                // 写入真正的 NALU 数据
                let dataPtr = dataPointer! + bufferOffset + headerLen
                elementaryStream.append(Data(bytes: dataPtr, count: Int(nalUnitLength)))
                
                // 移动到下一个 NALU
                bufferOffset += headerLen + Int(nalUnitLength)
            }
        }
        
        // 5. 校验发送：如果数据太小（比如只有 4 字节起始码），则不发送
        if elementaryStream.count > 4 {
            callback?(elementaryStream, isKeyframe)
        }
    }
    
    

}
