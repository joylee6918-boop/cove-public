import SwiftUI
import UIKit

/// The entire input field is the recording target. There is no independent
/// microphone/send control in voice mode and a short ordinary tap records nothing.
struct CoveVoiceHoldButton: UIViewRepresentable {
    let title: String
    let recording: Bool
    let disabled: Bool
    let allowsNewRecording: Bool
    let begin: () -> Void
    let cancel: () -> Void
    let end: () -> Void
    let accessibleRecord: () -> Void

    func makeUIView(context: Context) -> HoldButton {
        let button = HoldButton(type: .system)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.accessibilityLabel = "按住说话"
        button.accessibilityHint = "按住录音，松开发送，上滑取消。使用辅助功能激活可进入免按住录音。"
        button.accessibilityIdentifier = "chat.voiceHold"
        button.activate = { [weak coordinator = context.coordinator] in coordinator?.accessibleTap() ?? false }
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.2; hold.allowableMovement = 100
        button.addGestureRecognizer(hold)
        return button
    }
    func updateUIView(_ button: HoldButton, context: Context) {
        context.coordinator.parent = self
        button.setTitle(title, for: .normal)
        button.setTitleColor(recording ? .label : .secondaryLabel, for: .normal)
        button.isEnabled = !disabled
        if disabled { button.accessibilityTraits.insert(.notEnabled) }
        else { button.accessibilityTraits.remove(.notEnabled) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class HoldButton: UIButton {
        var activate: (() -> Bool)?
        override func accessibilityActivate() -> Bool { activate?() ?? false }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: CoveVoiceHoldButton
        var origin = CGPoint.zero
        var active = false
        var cancelled = false
        init(_ parent: CoveVoiceHoldButton) { self.parent = parent }
        func accessibleTap() -> Bool {
            guard !parent.disabled, parent.allowsNewRecording, !active else { return false }
            parent.accessibleRecord(); return true
        }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard !parent.disabled, parent.allowsNewRecording, !active else { return }
                origin = recognizer.location(in: nil); active = true; cancelled = false
                parent.begin()
            case .changed:
                guard active, !cancelled else { return }
                if Self.shouldCancel(translationY: recognizer.location(in: nil).y - origin.y) {
                    cancelled = true; parent.cancel()
                }
            case .ended:
                let shouldSend = active && !cancelled; active = false
                if shouldSend { parent.end() }
            case .cancelled, .failed:
                if active && !cancelled { parent.cancel() }
                active = false
            default: break
            }
        }
        static func shouldCancel(translationY: CGFloat) -> Bool { translationY <= -60 }
    }
}

/// Measured input levels only, used adjacent to the hold field while recording.
struct CoveVoiceHoldFeedback: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Color.primary.opacity(0.45))
                    .frame(width: 2, height: max(2, min(1, level) * 16))
            }
            Spacer(minLength: 0)
        }.frame(height: 18).accessibilityLabel("录音实际音量")
    }
}

/// A real 44pt native button owns its accessibility and touch bounds; the small
/// neutral symbol must not shrink the accessible target to the glyph's frame.
struct CoveVoiceModeButton: UIViewRepresentable {
    let voiceMode: Bool
    let disabled: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "chat.voiceMode"
        button.imageView?.isAccessibilityElement = false
        button.tintColor = .secondaryLabel
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.setImage(UIImage(systemName: voiceMode ? "keyboard" : "waveform",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        button.accessibilityLabel = voiceMode ? "切回文字输入" : "切换语音输入"
        button.accessibilityTraits = disabled ? [.button, .notEnabled] : [.button]
        button.isEnabled = !disabled
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: CoveVoiceModeButton
        init(_ parent: CoveVoiceModeButton) { self.parent = parent }
        @objc func tap() { if !parent.disabled { parent.action() } }
    }
}
