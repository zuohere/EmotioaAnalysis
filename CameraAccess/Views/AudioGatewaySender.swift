import Foundation
import AVFoundation

/// 简化版音频网关发送器
/// 只负责：从手机麦克风采集 → AAC(ADTS) 编码 → 通过 WebSocket 发送 `message_type: "audio"`。
final class AudioGatewaySender: NSObject, ObservableObject {
  static let shared = AudioGatewaySender()

  // MARK: - WebSocket & 状态

  private let session = URLSession(configuration: .default)
  private var webSocketTask: URLSessionWebSocketTask?

  @Published private(set) var isConnected: Bool = false

  private var isRunning = false
  private var audioChunkIndex = 0

  // iOS 端与 Python client 对齐的网关地址（请根据需要改成配置项）
  private let wsURL: URL = {
    let token = "25942d659fd81c3a4faa8deae5d3e278.CwjYQzIEqF1uHX0f7EG9CiBfZN14qRimke4lixE9dzw"
    let urlStr = "wss://api.finnox.cn/gateway/v1/proxy/ws?token=\(token)"
    return URL(string: urlStr) ?? URL(string: "wss://localhost")!
  }()

  // MARK: - 音频相关

  private let audioEngine = AVAudioEngine()
  private var audioConverter: AVAudioConverter?

  // 24000Hz / 1ch / 64kbps，对齐后端 AAC 设置
  private let aacSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 24000,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 64000,
  ]

  private lazy var aacFormat: AVAudioFormat = {
    AVAudioFormat(settings: aacSettings)!
  }()

  // MARK: - Public API

  func start() {
    guard !isRunning else { return }
    isRunning = true
    audioChunkIndex = 0
    connectWebSocket()
    checkMicrophonePermissionAndStartAudio()
  }

  func stop() {
    isRunning = false
    stopAudioCapture()
    disconnectWebSocket()
  }

  // MARK: - WebSocket

  private func connectWebSocket() {
    webSocketTask = session.webSocketTask(with: wsURL)
    webSocketTask?.resume()
    receiveMessage()
    print("[AudioGateway] WebSocket connecting...")
  }

  private func disconnectWebSocket() {
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    DispatchQueue.main.async {
      self.isConnected = false
    }
  }

  private func receiveMessage() {
    webSocketTask?.receive { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let message):
        if !self.isConnected {
          DispatchQueue.main.async { self.isConnected = true }
        }
        if case .string(let text) = message {
          print("[AudioGateway] recv:", text)
        }
        // 继续监听
        self.receiveMessage()
      case .failure(let error):
        print("[AudioGateway] WebSocket error:", error)
        self.disconnectWebSocket()
      }
    }
  }

  private func sendMessage(type: String, payload: Any) {
    var finalPayload = payload
    if var dict = payload as? [String: Any], let dataStr = dict["data"] as? String {
      dict["data"] = dataStr.components(separatedBy: .newlines).joined()
      finalPayload = dict
    }

    let msg: [String: Any] = [
      "message_type": type,
      "payload": finalPayload,
    ]

    guard
      let data = try? JSONSerialization.data(withJSONObject: msg),
      let json = String(data: data, encoding: .utf8)
    else {
      return
    }

    guard let task = webSocketTask else { return }
    task.send(.string(json)) { error in
      if let e = error {
        print("[AudioGateway] send error:", e)
      }
    }
  }

  // MARK: - 权限 & AudioSession

  private func configureAudioSession() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.duckOthers, .defaultToSpeaker]
      )
      try audioSession.setActive(true)
      if let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
        try audioSession.setPreferredInput(builtInMic)
      }
    } catch {
      print("[AudioGateway] audio session error:", error.localizedDescription)
    }
  }

  private func checkMicrophonePermissionAndStartAudio() {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { [weak self] granted in
        guard let self = self else { return }
        DispatchQueue.main.async {
          if granted {
            self.configureAudioSession()
            self.startAudioCapture()
          } else {
            print("[AudioGateway] mic permission denied (iOS 17+)")
          }
        }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
        guard let self = self else { return }
        DispatchQueue.main.async {
          if granted {
            self.configureAudioSession()
            self.startAudioCapture()
          } else {
            print("[AudioGateway] mic permission denied (<=iOS 16)")
          }
        }
      }
    }
  }

  // MARK: - 音频采集 & 编码

  private func adtsHeader(aacLength: Int, sampleRate: Int, channels: UInt8, profile: UInt8 = 2)
    -> Data
  {
    let adtsLength = aacLength + 7
    let freqIdxLookup: [Int: UInt8] = [
      96_000: 0, 88_200: 1, 64_000: 2, 48_000: 3, 44_100: 4, 32_000: 5,
      24_000: 6, 22_050: 7, 16_000: 8, 12_000: 9, 11_025: 10, 8_000: 11, 7_350: 12,
    ]
    let freqIdx: UInt8 = freqIdxLookup[sampleRate] ?? 6

    var packet = [UInt8](repeating: 0, count: 7)
    packet[0] = 0xFF
    packet[1] = 0xF1
    packet[2] = ((profile - 1) << 6) | (freqIdx << 2) | (channels >> 2)
    packet[3] = ((channels & 3) << 6) | UInt8((adtsLength >> 11) & 0x03)
    packet[4] = UInt8((adtsLength >> 3) & 0xFF)
    packet[5] = UInt8(((adtsLength & 0x7) << 5) | 0x1F)
    packet[6] = 0xFC
    return Data(packet)
  }

  private func startAudioCapture() {
    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)

    audioConverter = AVAudioConverter(from: recordingFormat, to: aacFormat)
    audioConverter?.bitRate = 64_000

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
      [weak self] buffer, _ in
      guard
        let self = self,
        let converter = self.audioConverter,
        self.isRunning,
        self.webSocketTask != nil
      else { return }

      let aacBuffer = AVAudioCompressedBuffer(
        format: self.aacFormat,
        packetCapacity: 8,
        maximumPacketSize: converter.maximumOutputPacketSize
      )
      var error: NSError?
      let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }
      let status = converter.convert(to: aacBuffer, error: &error, withInputFrom: inputBlock)
      guard status == .haveData, aacBuffer.packetCount > 0 else {
        return
      }

      var outData = Data()
      let sampleRate = Int(self.aacFormat.sampleRate)
      let channelCount = UInt8(self.aacFormat.channelCount)

      if let packetDescPtr = aacBuffer.packetDescriptions {
        let packetDescBuffer = UnsafeBufferPointer(
          start: packetDescPtr,
          count: Int(aacBuffer.packetCount)
        )
        for desc in packetDescBuffer {
          let start = Int(desc.mStartOffset)
          let size = Int(desc.mDataByteSize)
          if size <= 0 { continue }
          let packetBytes = Data(bytes: aacBuffer.data.advanced(by: start), count: size)
          let header = self.adtsHeader(
            aacLength: size,
            sampleRate: sampleRate,
            channels: channelCount
          )
          outData.append(header)
          outData.append(packetBytes)
        }
      } else {
        let aacData = Data(bytes: aacBuffer.data, count: Int(aacBuffer.byteLength))
        let header = self.adtsHeader(
          aacLength: aacData.count,
          sampleRate: sampleRate,
          channels: channelCount
        )
        outData.append(header)
        outData.append(aacData)
      }

      guard outData.count > 0 else { return }

      let payload: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "chunk_index": self.audioChunkIndex,
        "codec": "AAC",
        "sample_rate": sampleRate,
        "channels": Int(channelCount),
        "data": outData.base64EncodedString(),
        "size": outData.count,
      ]
      print("[AudioGateway] send audio chunk index=\(self.audioChunkIndex), size=\(outData.count)")
      self.sendMessage(type: "audio", payload: payload)
      self.audioChunkIndex += 1
    }

    do {
      try audioEngine.start()
      print("[AudioGateway] audio engine started")
    } catch {
      print("[AudioGateway] audio engine start error:", error.localizedDescription)
    }
  }

  private func stopAudioCapture() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
  }
}

