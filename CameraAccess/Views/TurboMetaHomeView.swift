/*
 * TurboMeta Home View
 * 主页 - 功能入口
 */

import SwiftUI

struct TurboMetaHomeView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @StateObject private var quickVisionManager = QuickVisionManager.shared
    @StateObject private var liveAIManager = LiveAIManager.shared
    
    let apiKey: String
    
    @State private var selectedFeature: String?
    @State private var showEmotionAnalysis = false
    
    var body: some View {
        NavigationView {
            VStack {
                // Feature Grid
                ScrollView {
                    VStack(spacing: 16) {
                        // Live AI
                        FeatureCard(
                            title: "home.liveai.title".localized,
                            subtitle: "home.liveai.subtitle".localized,
                            icon: "waveform.circle.fill",
                            color: .blue
                        )
                        
                        // Quick Vision
                        FeatureCard(
                            title: "home.quickvision.title".localized,
                            subtitle: "home.quickvision.subtitle".localized,
                            icon: "eye.fill",
                            color: .green
                        )
                        
                        // Live Translate
                        FeatureCard(
                            title: "home.translate.title".localized,
                            subtitle: "home.translate.subtitle".localized,
                            icon: "translate",
                            color: .orange
                        )
                        
                        // LeanEat
                        FeatureCard(
                            title: "home.leaneat.title".localized,
                            subtitle: "home.leaneat.subtitle".localized,
                            icon: "fork.knife",
                            color: .red
                        )
                        
                        // Emotion Analysis
                        NavigationLink(destination: EmotionAnalysisView(
                            streamViewModel: streamViewModel,
                            wearablesViewModel: wearablesViewModel,
                            apiKey: apiKey
                        )) {
                            FeatureCard(
                                title: "Emotion Analysis",
                                subtitle: "Real-time Emotion Detection",
                                icon: "face.smiling.fill",
                                color: .purple
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("home.title".localized)
        }
    }
}

// MARK: - 情绪分析详情页 (专业仪表盘版)
struct EmotionAnalysisView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager = EmotionAnalysisManager.shared
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    let apiKey: String
    
    @State private var isAnalyzing = false
    @State private var frameTimer: Timer?
    
    // 情绪对应的 Emoji 映射
    let emotionEmojis: [String: String] = [
        "happy": "😄", "sad": "😢", "angry": "😡",
        "fearful": "😱", "surprised": "😲", "disgusted": "🤢",
        "neutral": "😐"
    ]
    
    // 情绪对应的颜色
    let emotionColors: [String: Color] = [
        "happy": .yellow, "sad": .blue, "angry": .red,
        "fearful": .purple, "surprised": .orange, "disgusted": .green,
        "neutral": .gray
    ]
    
    /// 是否已有后端返回的情绪数据（用于区分「正在检测」与展示结果）
    private var hasEmotionData: Bool {
        !manager.emotionScores.isEmpty && !manager.emotionScores.values.allSatisfy { $0 < 0.01 }
    }
    
    /// 用于饼图的切片数据：只取占比 > 5% 的情绪，并归一化
    private var pieSlices: [(key: String, value: Double, color: Color)] {
        let filtered = manager.emotionScores.filter { $0.value > 0.05 }
        let total = filtered.values.reduce(0, +)
        guard total > 0 else { return [] }
        return filtered.sorted { $0.value > $1.value }.map { key, value in
            (key: key, value: value / total, color: emotionColors[key] ?? .gray)
        }
    }

    var body: some View {
        ZStack {
            // --- 层级 1: 视频底图 ---
            if let frame = streamViewModel.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            
            // --- 层级 2: 黑色渐变遮罩 (让字看得清) ---
            VStack {
                LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 400)
            }
            .ignoresSafeArea()
            
            // --- 层级 3: 核心内容 ---
            VStack {
                if isAnalyzing {
                    if !hasEmotionData {
                        // 无数据：只显示「正在检测」
                        Spacer()
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.white)
                            Text("正在检测")
                                .font(.title2)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                            Text("等待情绪分析结果…")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    } else {
                        // 有数据：顶部当前情绪 + 下方滚动（饼图 + 解读 + 建议）
                        HStack(spacing: 15) {
                            Text(emotionEmojis[manager.dominantEmotion] ?? "🤖")
                                .font(.system(size: 50))
                                .shadow(radius: 10)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("当前情绪")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                Text(manager.dominantEmotion.capitalized)
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            Spacer()
                        }
                        .padding(.top, 60)
                        .padding(.horizontal, 20)
                        
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 20) {
                                // 1. 情绪成分 - 饼状图
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("情绪成分")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    
                                    if pieSlices.isEmpty {
                                        HStack {
                                            Spacer()
                                            Text("未检测到面部表情")
                                                .font(.caption)
                                                .foregroundColor(.white.opacity(0.6))
                                            Spacer()
                                        }
                                        .padding(.vertical, 16)
                                    } else {
                                        HStack(spacing: 24) {
                                            EmotionPieChart(slices: pieSlices, size: 140)
                                            VStack(alignment: .leading, spacing: 6) {
                                                ForEach(pieSlices, id: \.key) { item in
                                                    HStack(spacing: 8) {
                                                        Circle()
                                                            .fill(item.color)
                                                            .frame(width: 10, height: 10)
                                                        Text(item.key.capitalized)
                                                            .font(.caption)
                                                            .foregroundColor(.white)
                                                        Text("\(Int(item.value * 100))%")
                                                            .font(.caption)
                                                            .foregroundColor(.white.opacity(0.8))
                                                    }
                                                }
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 8)
                                    }
                                }
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(16)
                                
                                // 2. 后端返回的解读（AI 深度洞察）
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "sparkles")
                                            .foregroundColor(.yellow)
                                        Text("解读")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                    }
                                    Text(manager.aiReasoning)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.9))
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding()
                                .background(Color.blue.opacity(0.2))
                                .background(.ultraThinMaterial)
                                .cornerRadius(16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                )
                                
                                // 3. 后端返回的建议
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "heart.text.square.fill")
                                            .foregroundColor(.pink)
                                        Text("建议")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                    }
                                    if manager.aiAdvice == "正在分析..." {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                                .tint(.white)
                                            Text("正在等待…")
                                                .font(.subheadline)
                                                .foregroundColor(.white.opacity(0.7))
                                        }
                                        .padding(.vertical, 4)
                                    } else {
                                        Text(manager.aiAdvice)
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.9))
                                            .lineLimit(nil)
                                    }
                                }
                                .padding()
                                .background(Color.green.opacity(0.2))
                                .background(.ultraThinMaterial)
                                .cornerRadius(16)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 80)
                        }
                        .frame(maxHeight: 420)
                    }
                }
            }
            
            // 底部控制按钮
            VStack {
                Spacer()
                Button(action: toggleAnalysis) {
                    HStack {
                        Image(systemName: isAnalyzing ? "stop.fill" : "play.fill")
                        Text(isAnalyzing ? "停止检测" : "开始分析")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isAnalyzing ? Color.red : Color.blue)
                    .cornerRadius(15)
                    .shadow(radius: 10)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: {
                stopAnalysis()
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 50)
                    .padding(.trailing, 20)
            }
        }
        .onDisappear {
            stopAnalysis()
        }
        .onChange(of: isAnalyzing) { newValue in
            if newValue {
                startFrameForwarding()
            } else {
                stopFrameForwarding()
            }
        }
    }
    
    // 逻辑控制 (保持不变)
    private func toggleAnalysis() {
        if isAnalyzing { stopAnalysis() } else { startAnalysis() }
    }
    
    private func startAnalysis() {
        isAnalyzing = true
        manager.start()
        Task { await streamViewModel.handleStartStreaming() }
    }
    
    private func stopAnalysis() {
        isAnalyzing = false
        manager.stop()
        Task { await streamViewModel.stopSession() }
    }

    /// 定时将当前视频帧送入 EmotionAnalysisManager，仅在情绪分析开启时生效
    /// ✅ 优化：降低到 3fps (0.33s) 以减少网络压力
    private func startFrameForwarding() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.33, repeats: true) { _ in
            guard
                EmotionAnalysisManager.shared.isConnected,  // 已连上后端
                let frame = streamViewModel.currentVideoFrame
            else { return }
            EmotionAnalysisManager.shared.processUIImage(frame)
        }
    }

    private func stopFrameForwarding() {
        frameTimer?.invalidate()
        frameTimer = nil
    }
}

// MARK: - 情绪饼图
struct EmotionPieChart: View {
    let slices: [(key: String, value: Double, color: Color)]
    let size: CGFloat
    
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            
            var startAngle: Double = -90
            for slice in slices {
                let sweep = slice.value * 360
                let endAngle = startAngle + sweep
                let startRad = startAngle * .pi / 180
                let endRad = endAngle * .pi / 180
                var path = Path()
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: .radians(startRad), endAngle: .radians(endRad), clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(slice.color))
                startAngle = endAngle
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 功能卡片
struct FeatureCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
                .frame(width: 50)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}
