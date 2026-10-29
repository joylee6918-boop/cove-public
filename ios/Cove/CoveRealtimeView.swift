import AVFoundation
import AVKit
import SwiftUI

struct CoveRealtimeView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var realtime = CoveRealtimeModel()

    var body: some View {
        NavigationStack {
            ZStack {
                CoveStyle.background.ignoresSafeArea()
                VStack(spacing: 22) {
                    callStatus
                    audioRouteControls
                    transcriptPanel
                    Spacer(minLength: 8)
                    if let error = realtime.error { errorPanel(error) }
                    primaryButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
            .navigationTitle("语音")
            .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await realtime.stop(); dismiss() } } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭") } }
        }
        .interactiveDismissDisabled(realtime.inProgress)
        .onChange(of: scenePhase) { if scenePhase == .background { Task { await realtime.stop() } } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            realtime.refreshAudioRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { await realtime.stop() }
        }
        .onDisappear { Task { await realtime.stop() } }
    }

    private var callStatus: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(CoveStyle.softAccent).frame(width: 112, height: 112)
                Circle().stroke(CoveStyle.border, lineWidth: 1).frame(width: 112, height: 112)
                Image(systemName: realtime.phase == .connected ? "waveform" : statusSymbol)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(CoveStyle.accentText)
                    .symbolEffect(.variableColor.iterative, options: reduceMotion || realtime.phase != .connected ? .nonRepeating : .repeating)
                if realtime.starting || [.negotiating, .connecting, .reconnecting].contains(realtime.phase) {
                    ProgressView().controlSize(.large).offset(y: 72)
                }
            }
            Text(statusTitle).font(.title2.weight(.semibold)).foregroundStyle(CoveStyle.text)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusDetail(at: context.date))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(CoveStyle.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("realtime.status")
    }

    private var audioRouteControls: some View {
        VStack(spacing: 12) {
            HStack {
                Label("当前输出", systemImage: "speaker.wave.2")
                Spacer()
                Text(realtime.routeLabel).foregroundStyle(CoveStyle.secondaryText)
            }.font(.subheadline)
            HStack(spacing: 10) {
                routeButton("听筒", systemImage: "iphone", selected: realtime.usingReceiver) {
                    realtime.selectBuiltInRoute(.receiver)
                }
                routeButton("扬声器", systemImage: "speaker.wave.3.fill", selected: realtime.usingSpeaker) {
                    realtime.selectBuiltInRoute(.speaker)
                }
                VStack(spacing: 2) {
                    CoveAudioRoutePicker(enabled: realtime.audioControlsEnabled)
                        .frame(width: 44, height: 28)
                    Text("其他设备").font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("选择蓝牙或 AirPlay 设备")
            }
        }
        .padding(16)
        .covePearlCard()
        .opacity(realtime.audioControlsEnabled ? 1 : 0.58)
        .accessibilityIdentifier("realtime.routes")
    }

    private var transcriptPanel: some View {
        ScrollView {
            Text(realtime.transcript.isEmpty ? transcriptPlaceholder : realtime.transcript)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(realtime.transcript.isEmpty ? CoveStyle.secondaryText : CoveStyle.text)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 180)
        .padding(16)
        .covePearlCard()
        .accessibilityIdentifier("realtime.transcript")
    }

    private var primaryButton: some View {
        Button {
            Task {
                if realtime.inProgress { await realtime.stop() }
                else { await realtime.start(store: store, conversationID: store.activeConversationID) }
            }
        } label: {
            Label(primaryTitle, systemImage: realtime.inProgress ? "phone.down.fill" : "waveform.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(realtime.inProgress ? CoveStyle.error : CoveStyle.accent)
        .disabled(store.previewMode)
        .accessibilityIdentifier("realtime.toggle")
    }

    private func routeButton(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.body)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(selected ? CoveStyle.accent : CoveStyle.secondaryText)
        .disabled(!realtime.audioControlsEnabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func errorPanel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(CoveStyle.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(CoveStyle.error.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("realtime.error")
    }

    private var statusTitle: String {
        switch realtime.phase {
        case .idle: "和 Assistant 语音对话"
        case .requestingMicrophone: "等待麦克风权限"
        case .preparingAudio: "正在准备音频"
        case .negotiating: "正在连接当前会话"
        case .connecting: "正在建立语音链路"
        case .connected: "正在和 Assistant 通话"
        case .reconnecting: "语音连接正在恢复"
        case .stopping: "正在结束通话"
        case .ended: "通话已结束"
        case .failed: "语音未连接"
        }
    }

    private var statusSymbol: String {
        switch realtime.phase {
        case .failed: "exclamationmark.waveform"
        case .ended: "phone.down"
        default: "waveform.circle"
        }
    }

    private func statusDetail(at date: Date) -> String {
        if let started = realtime.callStartedAt {
            let total = max(0, Int(date.timeIntervalSince(started)))
            return String(format: "%02d:%02d  ·  %@", total / 60, total % 60, realtime.routeLabel)
        }
        return switch realtime.phase {
        case .idle, .ended: "沿用当前 Cove 对话，通话期间屏幕保持常亮"
        case .failed: "请检查下方提示后重试"
        default: "\(realtime.routeLabel)  ·  连接中"
        }
    }

    private var primaryTitle: String {
        if realtime.active { return "结束通话" }
        if realtime.starting || realtime.inProgress { return "取消连接" }
        return "开始语音"
    }

    private var transcriptPlaceholder: String {
        realtime.inProgress ? "说话后，实时字幕会出现在这里。" : "开始后才会请求麦克风；实时通话与 MiniMax 语音条彼此独立。"
    }
}

private struct CoveAudioRoutePicker: UIViewRepresentable {
    let enabled: Bool

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = UIColor(CoveStyle.accent)
        picker.tintColor = UIColor(CoveStyle.secondaryText)
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.isUserInteractionEnabled = enabled
        picker.alpha = enabled ? 1 : 0.45
        picker.activeTintColor = UIColor(CoveStyle.accent)
        picker.tintColor = UIColor(CoveStyle.secondaryText)
    }
}
