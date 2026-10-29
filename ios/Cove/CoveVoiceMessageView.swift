import AVFoundation
import SwiftUI
import UIKit

func coveVoiceTime(_ seconds: TimeInterval) -> String {
    let value = seconds.isFinite ? Int(min(Double(Int.max / 2), max(0, seconds)).rounded(.down)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

@MainActor
final class CoveVoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private static weak var activePlayer: CoveVoicePlayer?
    static var recordingIsActive = false
    static func stopActivePlayback() { activePlayer?.pause() }
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published var errorMessage: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var ownsSession = false

    func prepare(data: Data) throws {
        stop()
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw CoveVoiceError.tooLarge }
        player = try AVAudioPlayer(data: data)
        player?.delegate = self
        guard let player, player.duration.isFinite, player.duration > 0 else { throw CoveVoiceError.unavailable }
        duration = player.duration; currentTime = 0
    }
    func play(data: Data) throws { try prepare(data: data); try resume() }
    func resume() throws {
        guard let player else { throw CoveVoiceError.unavailable }
        guard !Self.recordingIsActive else { throw CoveError.message("请先停止录音，再播放语音。") }
        if Self.activePlayer !== self { Self.activePlayer?.pause() }
        Self.activePlayer = self
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true); ownsSession = true
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { releaseSession(); throw CoveVoiceError.unavailable }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.currentTime = self.player?.currentTime ?? 0 }
        }
    }
    func pause() {
        player?.pause(); currentTime = player?.currentTime ?? 0
        timer?.invalidate(); timer = nil; isPlaying = false; releaseSession()
        if Self.activePlayer === self { Self.activePlayer = nil }
    }
    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        player?.currentTime = min(duration, max(0, seconds)); currentTime = player?.currentTime ?? 0
    }
    func stop() {
        player?.stop(); player = nil; timer?.invalidate(); timer = nil
        isPlaying = false; duration = 0; currentTime = 0; releaseSession()
        if Self.activePlayer === self { Self.activePlayer = nil }
    }
    private func releaseSession() {
        if ownsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); ownsSession = false }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.pause(); self.seek(to: 0)
            if !flag { self.errorMessage = "语音播放中断，请重试。" }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.errorMessage = error?.localizedDescription ?? "无法播放这段语音。"; self.stop()
        }
    }
}

/// The same original-audio draft controls are used in the inline composer and
/// accessible tap-to-record sheet. Transcription is an optional local preview.
struct CoveVoiceComposer: View {
    @ObservedObject var recorder: CoveVoiceRecorder
    @StateObject private var player = CoveVoicePlayer()
    let send: (Data, String, String, String) async throws -> Void
    @State private var sending = false
    @State private var transcriptionVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = recorder.preview {
                HStack(spacing: 8) {
                    Button {
                        do { player.isPlaying ? player.pause() : try player.play(data: preview) }
                        catch { recorder.errorMessage = error.localizedDescription }
                    } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(player.isPlaying ? "暂停试听" : "试听原声")
                        .accessibilityIdentifier("voice.preview")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("原声语音").font(.subheadline.weight(.medium))
                        Text(coveVoiceTime(recorder.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) { player.stop(); recorder.cancel(); transcriptionVisible = false } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }.accessibilityLabel("删除录音").accessibilityIdentifier("voice.delete").disabled(sending)
                    Button {
                        player.stop(); sending = true
                        Task {
                            do {
                                // Do not silently send the optional transcript as
                                // the user's words. The attachment is the message.
                                try await send(preview, "voice-\(UUID().uuidString).m4a", "audio/mp4", "")
                                if recorder.preview == preview { _ = recorder.consumePreview() }
                            } catch { recorder.errorMessage = error.localizedDescription }
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView().frame(width: 44, height: 44) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44) }
                    }.disabled(sending).accessibilityLabel("发送原声语音").accessibilityIdentifier("voice.send")
                }
                if transcriptionVisible {
                    if recorder.isTranscribing { ProgressView("正在本机转写…").font(.caption) }
                    else if !recorder.transcript.isEmpty {
                        Text(recorder.transcript).font(.subheadline).textSelection(.enabled)
                        Text("仅供查看，不作为文字消息发送").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Button("查看本机转写（可选）") {
                        transcriptionVisible = true
                        Task { await recorder.transcribeFromExplicitTap() }
                    }.font(.caption).frame(minHeight: 44).disabled(sending)
                        .accessibilityIdentifier("voice.transcribe")
                }
            } else if recorder.isRecording || recorder.isRequestingPermission {
                HStack(spacing: 8) {
                    if recorder.isRequestingPermission { ProgressView() }
                    else { Image(systemName: recorder.isLocked ? "lock.fill" : "mic.fill").foregroundStyle(.red) }
                    Text(coveVoiceTime(recorder.duration)).monospacedDigit().font(.subheadline)
                    CoveVoiceMeter(levels: recorder.levels).frame(maxWidth: .infinity).frame(height: 24)
                    Button(role: .destructive) { recorder.cancel() } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }.accessibilityLabel("取消录音").accessibilityIdentifier("voice.cancel")
                    Button { recorder.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2).frame(width: 44, height: 44)
                    }.accessibilityLabel("停止并试听").accessibilityIdentifier("voice.stop")
                }
                Text(recorder.isRequestingPermission ? "等待麦克风权限；松手会取消" : (recorder.isLocked ? "已锁定录音 · 点停止后试听发送" : "← 左滑取消 · ↑ 上滑锁定 · 松手试听"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button { recorder.startFromExplicitAction(locked: true) } label: {
                    Label("开始录制原声", systemImage: "mic.fill").frame(minHeight: 44)
                }.accessibilityIdentifier("voice.start")
                Text("最长 2 分钟。停止后可以试听、删除或发送，不需要先转写。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = recorder.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer(minLength: 4)
                    Button("关闭") { recorder.errorMessage = nil }.font(.caption).frame(minHeight: 44)
                }.accessibilityIdentifier("voice.error")
            }
        }
        .onDisappear { player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in recorder.cancel(); player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            recorder.cancel(); player.stop()
        }
    }
}

/// Real amplitude samples only. Empty means no measured waveform yet.
private struct CoveVoiceMeter: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Color.accentColor).frame(width: 2, height: max(2, min(1, level) * 24))
            }
            Spacer(minLength: 0)
        }.accessibilityLabel("实时录音音量")
    }
}

struct CoveVoiceRecordingControls: View {
    @ObservedObject var recorder: CoveVoiceRecorder
    let sending: Bool
    let sendLocked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if recorder.isRequestingPermission { ProgressView() }
                else { Image(systemName: recorder.isLocked ? "lock.fill" : "mic.fill").foregroundStyle(.red) }
                Text(coveVoiceTime(recorder.duration)).font(.subheadline.monospacedDigit())
                CoveVoiceMeter(levels: recorder.levels).frame(maxWidth: .infinity).frame(height: 24)
                Button(role: .destructive) { recorder.cancel() } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }.accessibilityLabel("取消录音").accessibilityIdentifier("voice.cancel")
                if recorder.isLocked && !recorder.isRequestingPermission {
                    Button(action: sendLocked) {
                        Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44)
                    }.disabled(sending).accessibilityLabel("发送录制的语音").accessibilityIdentifier("voice.lockedSend")
                }
            }
            Text(recorder.isRequestingPermission ? "等待麦克风权限；松手会取消" : (recorder.isLocked ? "录音已锁定 · 点箭头发送，点垃圾桶取消" : "松开发送 · ← 左滑取消 · ↑ 上滑锁定"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Telegram-style direct microphone. Touch stays on this stable button while
/// recording controls appear above the composer; there is no input-mode toggle.
struct CoveVoiceRecordButton: UIViewRepresentable {
    let disabled: Bool
    // New touches are blocked while a draft/locked recording exists, without
    // disabling UIKit's recognizer underneath its current recording gesture.
    let allowsNewRecording: Bool
    let tap: () -> Void
    let begin: () -> Void
    let cancel: () -> Void
    let lock: () -> Bool
    let end: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        button.accessibilityLabel = "录制语音消息"
        button.accessibilityHint = "长按录音，松开发送，左滑取消，上滑锁定。轻点可打开录音试听窗口。"
        button.accessibilityIdentifier = "chat.voice"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.2; hold.allowableMovement = 100
        button.addGestureRecognizer(hold)
        return button
    }
    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.parent = self
        uiView.isEnabled = !disabled; uiView.alpha = disabled ? 0.4 : 1
        if disabled { uiView.accessibilityTraits.insert(.notEnabled) }
        else { uiView.accessibilityTraits.remove(.notEnabled) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: CoveVoiceRecordButton
        var origin = CGPoint.zero
        var cancelled = false
        var locked = false
        var active = false
        init(_ parent: CoveVoiceRecordButton) { self.parent = parent }
        @objc func tap() { guard !parent.disabled, parent.allowsNewRecording, !active else { return }; parent.tap() }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard !parent.disabled, parent.allowsNewRecording, !active else { return }
                origin = recognizer.location(in: nil); cancelled = false; locked = false; active = true; parent.begin()
            case .changed:
                guard active, !cancelled, !locked else { return }
                let position = recognizer.location(in: nil)
                switch CoveVoiceDragAction.resolve(x: position.x - origin.x, y: position.y - origin.y) {
                case .cancel: cancelled = true; parent.cancel()
                case .lock: locked = parent.lock()
                case .none: break
                }
            case .ended:
                let shouldSend = active && !cancelled && !locked
                active = false
                if shouldSend { parent.end() }
            case .cancelled, .failed:
                if active && !cancelled && !locked { parent.cancel() }
                active = false
            default: break
            }
        }
    }
}

enum CoveVoiceDragAction: Equatable {
    case none, cancel, lock
    static func resolve(x: CGFloat, y: CGFloat) -> Self {
        // Cancellation wins a diagonal drag that crosses both thresholds.
        if x <= -80 { return .cancel }
        if y <= -70 { return .lock }
        return .none
    }
}

/// Authenticated original audio. Decoding the waveform never blocks playback
/// or the main actor, and a stale attachment cannot replace the current samples.
struct CoveVoiceMessageView: View {
    let attachment: ChatAttachment
    var isOutgoing: Bool = false
    let loadData: (ChatAttachment) async throws -> Data
    @StateObject private var player = CoveVoicePlayer()
    @State private var loading = false
    @State private var waveformLoading = false
    @State private var samples: [Float] = []
    @State private var waveformTask: Task<[Float], Error>?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoveVoiceBubbleLabel(duration: player.duration, progress: player.currentTime,
                isPlaying: player.isPlaying, isLoading: loading, isOutgoing: isOutgoing,
                samples: samples, waveformLoading: waveformLoading,
                onPlay: {
                    do { player.isPlaying ? player.pause() : try player.resume() }
                    catch { player.errorMessage = error.localizedDescription }
                }, onSeek: { player.seek(to: $0) })
                .accessibilityIdentifier("voice.bubble")
            if let error = player.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重新加载") { Task { await prepare() } }
                    .font(.caption).frame(minHeight: 44).disabled(loading)
            }
        }
        .task(id: attachment.id) { await prepare() }
        .onDisappear {
            generation = UUID(); waveformTask?.cancel(); waveformTask = nil
            loading = false; waveformLoading = false; player.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { player.pause() }
        }
    }

    @MainActor private func prepare() async {
        let current = UUID(); generation = current
        waveformTask?.cancel(); waveformTask = nil; samples = []
        loading = true; waveformLoading = true; player.stop(); player.errorMessage = nil
        do {
            let data = try await loadData(attachment)
            guard generation == current, !Task.isCancelled else { return }
            try player.prepare(data: data)
            loading = false
            let worker = Task.detached(priority: .utility) { try CoveVoiceWaveform.decode(data: data) }
            waveformTask = worker
            do {
                let measured = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                guard generation == current, !Task.isCancelled else { return }
                samples = measured
            } catch {
                // A failed waveform is unavailable, not fabricated. Original
                // audio can still play if AVAudioPlayer decoded it successfully.
            }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            player.errorMessage = error.localizedDescription
        }
        if generation == current {
            loading = false; waveformLoading = false; waveformTask = nil
        }
    }
}

/// Telegram-referenced geometry; Cove owns its colours and outer chat bubble.
/// This is the production view also rendered by the appearance tests.
struct CoveVoiceBubbleLabel: View {
    static let controlSize: CGFloat = 24
    static let waveformHeight: CGFloat = 18
    static let contentHeight: CGFloat = 34
    static let waveformX: CGFloat = 40
    static let playHitOffset = CGSize(width: 3 - (44 - controlSize) / 2,
                                      height: (contentHeight - 44) / 2)
    let duration: TimeInterval
    var progress: TimeInterval = 0
    var isPlaying = false
    var isLoading = false
    var isOutgoing = false
    var samples: [Float] = []
    var waveformLoading = false
    var onPlay: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.92, green: 0.62, blue: 0.76) : Color(red: 0.62, green: 0.25, blue: 0.43)
    }
    private var bubbleFill: Color { isOutgoing ? CoveStyle.outgoing(colorScheme == .dark) : CoveStyle.incoming }
    private var validDuration: Bool { duration.isFinite && duration > 0 }
    private var fraction: Double { Self.seekFraction(x: progress, width: duration) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button { onPlay?() } label: {
                Circle().fill(accent).frame(width: Self.controlSize, height: Self.controlSize)
                    .overlay {
                        if isLoading { ProgressView().controlSize(.mini).scaleEffect(0.8).tint(bubbleFill) }
                        else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .offset(x: isPlaying ? 0 : 0.5)
                                .foregroundStyle(bubbleFill)
                        }
                    }
                    // Keep the visible circle small without requiring precise taps.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading || !validDuration || onPlay == nil)
            .accessibilityLabel(isPlaying ? "暂停语音" : "播放语音")
            .accessibilityValue(Self.secondsLabel(duration))
            .accessibilityIdentifier("voice.play")
            // Center against waveform AND duration, not the waveform row alone.
            .offset(Self.playHitOffset)

            VStack(alignment: .leading, spacing: 3) {
                if !samples.isEmpty {
                    CoveVoiceWaveformBars(samples: samples, fraction: fraction, accent: accent)
                        .frame(height: Self.waveformHeight).accessibilityHidden(true)
                } else {
                    Text(waveformLoading || isLoading ? "" : "波形暂不可用")
                        .font(.system(size: 11)).foregroundStyle(accent.opacity(0.7))
                        .frame(height: Self.waveformHeight).accessibilityHidden(true)
                }
                Text(validDuration ? (isPlaying || progress > 0 ? "\(coveVoiceTime(progress)) / \(coveVoiceTime(duration))" : coveVoiceTime(duration)) : "—:—")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(accent)
            }
            .frame(width: Self.width(for: duration) - Self.waveformX - 3, height: Self.contentHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                guard validDuration, !isLoading, !samples.isEmpty,
                      Self.isHorizontalSeek(x: value.translation.width, y: value.translation.height) else { return }
                onSeek?(Self.seekFraction(x: value.location.x, width: Self.width(for: duration) - Self.waveformX - 3) * duration)
            })
            .onTapGesture(coordinateSpace: .local) { location in
                guard validDuration, !isLoading, !samples.isEmpty else { return }
                onSeek?(Self.seekFraction(x: location.x, width: Self.width(for: duration) - Self.waveformX - 3) * duration)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("语音播放进度")
            .accessibilityValue(validDuration ? "\(coveVoiceTime(progress))，共 \(coveVoiceTime(duration))" : "时长未读取")
            .accessibilityAdjustableAction { direction in
                guard validDuration, !isLoading else { return }
                switch direction {
                case .increment: onSeek?(min(duration, progress + 5))
                case .decrement: onSeek?(max(0, progress - 5))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("voice.waveform")
            .offset(x: Self.waveformX, y: 0)
        }
        .frame(width: Self.width(for: duration), height: Self.contentHeight, alignment: .topLeading)
    }

    static func secondsLabel(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "—:—" }
        return coveVoiceTime(duration)
    }
    static func width(for duration: TimeInterval) -> CGFloat {
        guard duration.isFinite, duration > 0 else { return 180 }
        return 120 + (276 - 120) * CGFloat((min(30, max(2, duration)) - 2) / 28)
    }
    static func isHorizontalSeek(x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite && abs(x) > abs(y)
    }
    static func seekFraction(x: Double, width: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return min(1, max(0, x / width))
    }
}

/// Peaks are measured from the original audio; never synthesize decorative bars.
struct CoveVoiceWaveformBars: View {
    let samples: [Float]
    let fraction: Double
    let accent: Color
    var body: some View {
        Canvas { context, size in
            let peaks = Self.resample(samples, count: Int(size.width / 4))
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let height = max(2, CGFloat(peak) * 18 - 3)
                path.addRoundedRect(in: CGRect(x: CGFloat(index) * 4, y: size.height - height, width: 2, height: height), cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(accent.opacity(0.38)))
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)))
            played.fill(path, with: .color(accent))
        }
    }
    static func resample(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let count = min(count, 512)
        return (0..<count).map { index in
            let first = min(samples.count - 1, index * samples.count / count)
            let end = min(samples.count, max(first + 1, (index + 1) * samples.count / count))
            return samples[first..<end].reduce(Float.zero) { current, sample in
                max(current, sample.isFinite ? min(1, max(0, sample)) : 0)
            }
        }
    }
}
