import AVFoundation
import Speech
import SwiftUI

enum CoveVoiceError: LocalizedError {
    case permissionDenied, speechPermissionDenied, onDeviceSpeechUnavailable, unavailable, empty, tooLarge
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "需要麦克风权限才能录制语音。可在系统设置中为 Cove 开启。"
        case .speechPermissionDenied: "尚未允许本机转写；仍然可以直接发送原声。"
        case .onDeviceSpeechUnavailable: "本机转写暂不可用；仍然可以直接发送原声，不会转交 Apple 云端。"
        case .unavailable: "暂时无法录音，请稍后重试。"
        case .empty: "这段录音太短，请重新录制。"
        case .tooLarge: "语音最长 2 分钟且不能超过 20 MiB。"
        }
    }
}

/// Small injection seam: tests use synthetic bytes and never open the microphone.
protocol CoveAudioRecording: AnyObject {
    var url: URL { get }
    var currentTime: TimeInterval { get }
    var isMeteringEnabled: Bool { get set }
    func record() -> Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}
extension AVAudioRecorder: CoveAudioRecording {}

@MainActor
final class CoveVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isLocked = false
    private(set) var isHolding = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var levels: [CGFloat] = []
    @Published private(set) var preview: Data?
    @Published var transcript = ""
    @Published private(set) var isTranscribing = false
    @Published var errorMessage: String?
    var hasDraft: Bool { isRequestingPermission || isRecording || preview != nil }
    private var recorder: (any CoveAudioRecording)?
    private var timer: Timer?
    private var ownsSession = false
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation = UUID()
    private let maximumDuration: TimeInterval = 120
    private let maximumBytes = 20 * 1024 * 1024
    private let requestPermission: () async -> Bool
    private let makeRecorder: (URL) throws -> any CoveAudioRecording
    private let activateSession: () throws -> Void
    private let deactivateSession: () -> Void

    init(requestPermission: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         makeRecorder: @escaping (URL) throws -> any CoveAudioRecording = { url in
             try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
             ])
         }, activateSession: @escaping () throws -> Void = {
             let session = AVAudioSession.sharedInstance()
             try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
             try session.setActive(true)
         }, deactivateSession: @escaping () -> Void = {
             try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
         }) {
        self.requestPermission = requestPermission; self.makeRecorder = makeRecorder
        self.activateSession = activateSession; self.deactivateSession = deactivateSession
        super.init()
    }

    /// Only a deliberate record action asks for microphone access. Speech
    /// recognition permission is unrelated and never blocks an original voice note.
    func startFromExplicitAction(locked: Bool = false) {
        guard let current = beginStart(locked: locked) else { return }
        Task { await performStart(generation: current) }
    }

    func startFromExplicitTap() async {
        guard let current = beginStart(locked: false) else { return }
        await performStart(generation: current)
    }

    private func beginStart(locked: Bool) -> UUID? {
        guard !isRecording, !isRequestingPermission, preview == nil else { return nil }
        errorMessage = nil
        let current = UUID(); generation = current; isRequestingPermission = true; isLocked = locked; isHolding = !locked
        return current
    }

    private func performStart(generation current: UUID) async {
        guard generation == current else { return }
        let allowed = await requestPermission()
        guard generation == current else { return }
        isRequestingPermission = false
        guard allowed else { isLocked = false; isHolding = false; errorMessage = CoveVoiceError.permissionDenied.localizedDescription; return }
        do {
            CoveVoicePlayer.stopActivePlayback()
            ownsSession = true
            try activateSession()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cove-voice-\(UUID().uuidString).m4a")
            let recording = try makeRecorder(url)
            recorder = recording
            (recording as? AVAudioRecorder)?.delegate = self
            recording.isMeteringEnabled = true
            guard recording.record() else { throw CoveVoiceError.unavailable }
            transcript = ""; duration = 0; levels = []; isRecording = true
            CoveVoicePlayer.recordingIsActive = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateRecording() }
            }
        } catch { fail(error) }
    }

    @discardableResult func lock() -> Bool {
        // A drag while the microphone permission prompt is pending must not
        // turn a later approval into an unattended locked recording.
        guard isRecording else { return false }
        isLocked = true; isHolding = false
        return true
    }

    /// Finalize bytes only. Pending permission is invalidated rather than
    /// starting a surprise recording after the user's finger has lifted.
    func endHold() {
        guard !isLocked else { return }
        if isRequestingPermission { cancel() }
        else { stop() }
    }

    /// The microphone gesture calls this once on an unlocked completed hold. A cancelled,
    /// duplicate, locked or permission-pending gesture cannot send audio.
    func finishHoldForSending() -> Data? {
        guard isHolding, !isLocked else { return nil }
        isHolding = false
        endHold()
        return preview
    }

    func updateRecording() {
        guard isRecording, let recorder else { return }
        duration = recorder.currentTime
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = power.isFinite ? CGFloat(pow(10, min(0, max(-60, power)) / 20)) : 0
        levels.append(normalized)
        if levels.count > 36 { levels.removeFirst(levels.count - 36) }
        if duration >= maximumDuration { stop() }
    }

    func stop() {
        if isRequestingPermission { cancel(); return }
        guard isRecording, let recorder else { return }
        duration = recorder.currentTime
        isRecording = false; isLocked = false; CoveVoicePlayer.recordingIsActive = false
        recorder.stop(); timer?.invalidate(); timer = nil
        do {
            let data = try Data(contentsOf: recorder.url)
            guard duration >= 0.25, data.count > 512 else { throw CoveVoiceError.empty }
            guard data.count <= maximumBytes else { throw CoveVoiceError.tooLarge }
            preview = data
        } catch { fail(error) }
        releaseSession()
    }

    /// Optional, user-invoked local helper. Its result never becomes a required
    /// caption and does not substitute for transmitting the original m4a bytes.
    func transcribeFromExplicitTap() async {
        guard preview != nil, let url = recorder?.url, !isTranscribing else { return }
        errorMessage = nil; isTranscribing = true
        let current = generation
        let allowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard generation == current, preview != nil else { return }
        guard allowed else {
            isTranscribing = false; errorMessage = CoveVoiceError.speechPermissionDenied.localizedDescription; return
        }
        await transcribeOnDevice(url: url, generation: current)
    }

    func cancel() {
        let old = recorder; recorder = nil
        generation = UUID(); timer?.invalidate(); timer = nil
        recognitionTask?.cancel(); recognitionTask = nil; isTranscribing = false
        isRequestingPermission = false; isRecording = false; isLocked = false; isHolding = false
        if old != nil { CoveVoicePlayer.recordingIsActive = false }
        preview = nil; transcript = ""; duration = 0; levels = []
        old?.stop()
        if let url = old?.url { try? FileManager.default.removeItem(at: url) }
        releaseSession()
    }

    private func releaseSession() {
        if ownsSession { deactivateSession(); ownsSession = false }
    }

    func consumePreview() -> Data? { defer { cancel() }; return preview }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.isRecording else { return }
            self.fail(error ?? CoveVoiceError.unavailable)
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.isRecording else { return }
            if flag { self.stop() } else { self.fail(CoveVoiceError.unavailable) }
        }
    }
    private func fail(_ error: Error) { cancel(); errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    private func transcribeOnDevice(url: URL, generation current: UUID) async {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.supportsOnDeviceRecognition else {
            if generation == current { isTranscribing = false; errorMessage = CoveVoiceError.onDeviceSpeechUnavailable.localizedDescription }
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        do {
            let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                var resumed = false
                recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    guard !resumed else { return }
                    if let error { resumed = true; continuation.resume(throwing: error) }
                    else if let result, result.isFinal { resumed = true; continuation.resume(returning: result.bestTranscription.formattedString) }
                }
            }
            guard generation == current, preview != nil else { return }
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            isTranscribing = false; recognitionTask = nil
        } catch {
            guard generation == current, preview != nil else { return }
            isTranscribing = false; recognitionTask = nil
            errorMessage = CoveVoiceError.onDeviceSpeechUnavailable.localizedDescription
        }
    }
}
