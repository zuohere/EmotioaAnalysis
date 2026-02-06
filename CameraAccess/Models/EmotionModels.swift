import Foundation

// 对应 Python 中的 send_initial_text
struct EmotionAnalysisRequest: Codable {
    let user_id: String
    let messages: [ChatMessage]
    let prep_data: PrepData
    let snapshot_window_sec: Double
    let is_last: Bool
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

// 对应 Python 中的 prep_data
struct PrepData: Codable {
    let user_prompt: UserPrompt
}

struct UserPrompt: Codable {
    let scene: String
    let intention: String
    let analysis: String
}

// 对应 Python 中的 "video" payload
struct VideoPayload: Codable {
    var message_type: String = "video"
    var payload: VideoFrameData // 修改为 var
}

struct VideoFrameData: Codable {
    let timestamp: String
    let frame_index: Int
    var codec: String = "H264"
    var width: Int // 修改为 var
    let height: Int
    let data: String // Base64 String
    let size: Int
}

// 对应 Python 中的 "vital" payload
struct VitalPayload: Codable {
    var message_type: String = "vital"
    var payload: VitalData // 修改为 var
}

struct VitalData: Codable {
    let timestamp: String
    let heart_rate: Double
    let breath_rate: Double
    let breath_amp: Double
    let conf: Double
    let init_stat: Int
    let presence_status: Int
}
