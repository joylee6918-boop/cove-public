import AVFoundation
import Foundation
import UIKit
import WebRTC

struct CoveRealtimeAck: Decodable { let ok: Bool; let sessionID: String? }
struct CoveRealtimeEvent: Decodable, Identifiable {
    let id: Int
    let method: String
    let role: String?
    let delta: String?
    let text: String?
    let message: String?
    let reason: String?
    let sdp: String?
}
struct CoveRealtimeEvents: Decodable { let cursor: Int; let events: [CoveRealtimeEvent]; let closed: Bool }

enum CoveRealtimePhase: Equatable {
    case idle
    case requestingMicrophone
    case preparingAudio
    case negotiating
    case connecting
    case connected
    case reconnecting
    case stopping
    case ended
    case failed
}

enum CoveBuiltInAudioRoute {
    case receiver
    case speaker
}

/// Owns the phone side of Codex's app-server WebRTC transport. Audio stays on
/// WebRTC; Cove's authenticated HTTP API only carries the SDP offer/answer and
/// bounded public transcript events.
@MainActor
final class CoveRealtimeModel: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var starting = false
    @Published private(set) var phase: CoveRealtimePhase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var error: String?
    @Published private(set) var routeLabel = "iPhone"
    @Published private(set) var usingSpeaker = false
    @Published private(set) var usingReceiver = false
    @Published private(set) var callStartedAt: Date?

    private var store: CoveStore?
    private var conversationID = ""
    private var sessionID: String?
    private var cursor = 0
    private var pollTask: Task<Void, Never>?
    private var startToken = UUID()
    private var peer: CoveRealtimePeer?
    private var previousIdleTimerDisabled: Bool?

    var inProgress: Bool { active || starting || sessionID != nil }
    var audioControlsEnabled: Bool { active || starting }

    func start(store: CoveStore, conversationID: String) async {
        guard !inProgress, !conversationID.isEmpty else { return }
        let token = UUID(); startToken = token
        starting = true; phase = .requestingMicrophone; error = nil
        defer { starting = false }
        guard await microphoneAllowed() else {
            error = "需要麦克风权限才能开始语音。"
            phase = .failed
            return
        }
        guard startToken == token, !Task.isCancelled else { return }
        self.store = store; self.conversationID = conversationID

        do {
            keepScreenAwake()
            phase = .preparingAudio
            try configureAudioSession()
            let candidate = try await CoveRealtimePeer.make()
            candidate.onICEStateChange = { [weak self] state in
                Task { @MainActor [weak self] in self?.receiveICEState(state) }
            }
            guard startToken == token, !Task.isCancelled else { candidate.close(); return }
            peer = candidate
            let offer = try await candidate.offer()
            guard startToken == token, !Task.isCancelled else { candidate.close(); return }
            phase = .negotiating
            let ack: CoveRealtimeAck = try await store.terminalRequest(
                "v1/realtime/start", method: "POST",
                body: ["conversationID": conversationID, "sdp": offer]
            )
            guard ack.ok, let id = ack.sessionID, !id.isEmpty else { throw VoiceError.unconfirmed }
            guard startToken == token, !Task.isCancelled else {
                let _: CoveRealtimeAck? = try? await store.terminalRequest(
                    "v1/realtime/stop", method: "POST",
                    body: ["conversationID": conversationID, "sessionID": id]
                )
                candidate.close(); return
            }
            sessionID = id; cursor = 0; transcript = ""
            let ready = try await waitUntilReady(id: id, token: token)
            guard sessionID == id, startToken == token, !Task.isCancelled else { return }
            phase = .connecting
            try await candidate.accept(answer: ready.sdp)
            active = true
            for event in ready.remaining { consume(event) }
            pollTask = Task { await poll(id: id) }
        } catch is CancellationError {
            await finish(sendRequest: sessionID != nil, finalPhase: .ended)
        } catch {
            let message = error.localizedDescription
            await finish(sendRequest: sessionID != nil, finalPhase: .failed)
            self.error = message
        }
    }

    func stop(sendRequest: Bool = true) async {
        await finish(sendRequest: sendRequest, finalPhase: .ended)
    }

    private func finish(sendRequest: Bool, finalPhase: CoveRealtimePhase) async {
        let id = sessionID; let cid = conversationID; let service = store
        startToken = UUID()
        if active || starting || id != nil { phase = .stopping }
        active = false; sessionID = nil; pollTask?.cancel(); pollTask = nil
        callStartedAt = nil
        peer?.close(); peer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        restoreIdleTimer()
        if sendRequest, let id, let service {
            do {
                let _: CoveRealtimeAck = try await service.terminalRequest(
                    "v1/realtime/stop", method: "POST",
                    body: ["conversationID": cid, "sessionID": id]
                )
            } catch {
                if self.error == nil {
                    self.error = "通话已在本机停止，但服务端未确认：\(error.localizedDescription)"
                }
            }
        }
        phase = finalPhase
    }

    private func microphoneAllowed() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        if AVAudioApplication.shared.recordPermission == .denied { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)
        let hasExternalOutput = session.currentRoute.outputs.contains { output in
            ![AVAudioSession.Port.builtInReceiver, .builtInSpeaker].contains(output.portType)
        }
        if !hasExternalOutput {
            try session.overrideOutputAudioPort(.speaker)
        }
        refreshAudioRoute()
    }

    func selectBuiltInRoute(_ route: CoveBuiltInAudioRoute) {
        guard audioControlsEnabled else { return }
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(route == .speaker ? .speaker : .none)
            refreshAudioRoute()
        } catch {
            self.error = "无法切换声音输出：\(error.localizedDescription)"
        }
    }

    func refreshAudioRoute() {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            routeLabel = "iPhone"
            usingSpeaker = false
            usingReceiver = false
            return
        }
        usingSpeaker = output.portType == .builtInSpeaker
        usingReceiver = output.portType == .builtInReceiver
        switch output.portType {
        case .builtInSpeaker: routeLabel = "扬声器"
        case .builtInReceiver: routeLabel = "听筒"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: routeLabel = output.portName.isEmpty ? "蓝牙" : output.portName
        case .airPlay: routeLabel = output.portName.isEmpty ? "AirPlay" : output.portName
        case .headphones, .headsetMic: routeLabel = output.portName.isEmpty ? "耳机" : output.portName
        default: routeLabel = output.portName.isEmpty ? "其他设备" : output.portName
        }
    }

    private func keepScreenAwake() {
        if previousIdleTimerDisabled == nil {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func restoreIdleTimer() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
    }

    private func receiveICEState(_ state: RTCIceConnectionState) {
        guard sessionID != nil else { return }
        switch state {
        case .checking:
            phase = .connecting
        case .connected, .completed:
            phase = .connected
            if callStartedAt == nil { callStartedAt = Date() }
            refreshAudioRoute()
        case .disconnected:
            phase = .reconnecting
        case .failed:
            error = "实时语音连接失败，请重试。"
            Task { await finish(sendRequest: true, finalPhase: .failed) }
        case .closed:
            if active { Task { await finish(sendRequest: false, finalPhase: .ended) } }
        case .new, .count:
            break
        @unknown default:
            break
        }
    }

    private func poll(id: String) async {
        while !Task.isCancelled, active, sessionID == id, let store {
            do {
                let result: CoveRealtimeEvents = try await store.terminalRequest(
                    "v1/realtime/events", query: [
                        URLQueryItem(name: "conversationID", value: conversationID),
                        URLQueryItem(name: "sessionID", value: id),
                        URLQueryItem(name: "after", value: String(cursor))
                    ]
                )
                guard sessionID == id else { return }
                cursor = max(cursor, result.cursor)
                for event in result.events { consume(event) }
                if result.closed { await finish(sendRequest: false, finalPhase: .ended); return }
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError { return }
            catch {
                self.error = "语音连接中断：\(error.localizedDescription)"
                await finish(sendRequest: true, finalPhase: .failed); return
            }
        }
    }

    private func waitUntilReady(id: String, token: UUID) async throws -> (sdp: String, remaining: [CoveRealtimeEvent]) {
        guard let store else { throw VoiceError.unconfirmed }
        let deadline = Date().addingTimeInterval(20)
        var didStart = false
        var answer: String?
        var retained: [CoveRealtimeEvent] = []
        while Date() < deadline, sessionID == id, startToken == token, !Task.isCancelled {
            let result: CoveRealtimeEvents = try await store.terminalRequest(
                "v1/realtime/events", query: [
                    URLQueryItem(name: "conversationID", value: conversationID),
                    URLQueryItem(name: "sessionID", value: id),
                    URLQueryItem(name: "after", value: String(cursor))
                ]
            )
            cursor = max(cursor, result.cursor)
            for event in result.events {
                switch event.method {
                case "thread/realtime/started": didStart = true
                case "thread/realtime/sdp": if let sdp = event.sdp, !sdp.isEmpty { answer = sdp }
                case "thread/realtime/error": throw VoiceError.server(event.message ?? "Codex 语音启动失败")
                case "thread/realtime/closed": throw VoiceError.unconfirmed
                default: retained.append(event)
                }
            }
            if didStart, let answer { return (answer, retained) }
            if result.closed { throw VoiceError.unconfirmed }
            try await Task.sleep(for: .milliseconds(200))
        }
        if startToken != token || Task.isCancelled { throw CancellationError() }
        throw VoiceError.startedTimeout
    }

    private func consume(_ event: CoveRealtimeEvent) {
        if let delta = event.delta { transcript += delta }
        if let message = event.message { error = message; phase = .failed }
    }

    private enum VoiceError: LocalizedError {
        case unconfirmed, startedTimeout, server(String)
        var errorDescription: String? {
            switch self {
            case .unconfirmed: "服务没有确认语音会话"
            case .startedTimeout: "Codex 语音启动超时"
            case .server(let value): value
            }
        }
    }
}

private final class CoveRealtimePeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private static let factory = RTCPeerConnectionFactory()
    private let connection: RTCPeerConnection
    private var audioTrack: RTCAudioTrack?
    private var events: RTCDataChannel?
    var onICEStateChange: ((RTCIceConnectionState) -> Void)?

    private init(connection: RTCPeerConnection) {
        self.connection = connection
        super.init()
    }

    @MainActor static func make() async throws -> CoveRealtimePeer {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw CoveError.message("无法创建 WebRTC 语音连接。")
        }
        let peer = CoveRealtimePeer(connection: connection)
        connection.delegate = peer
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "cove-audio")
        peer.audioTrack = track
        _ = connection.add(track, streamIds: ["cove-stream"])
        let channelConfiguration = RTCDataChannelConfiguration()
        guard let channel = connection.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
            connection.close()
            throw CoveError.message("无法创建实时语音事件通道。")
        }
        peer.events = channel; channel.delegate = peer
        return peer
    }

    func offer() async throws -> String {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let error { continuation.resume(throwing: error) }
                else if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: CoveError.message("WebRTC 没有生成通话提议。")) }
            }
        }
        try await setLocal(description)
        return connection.localDescription?.sdp ?? description.sdp
    }

    func accept(answer: String) async throws {
        let description = RTCSessionDescription(type: .answer, sdp: answer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func setLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func close() {
        audioTrack?.isEnabled = false
        events?.close(); events?.delegate = nil
        connection.close(); connection.delegate = nil
        events = nil; audioTrack = nil; onICEStateChange = nil
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onICEStateChange?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        events = dataChannel; dataChannel.delegate = self
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
