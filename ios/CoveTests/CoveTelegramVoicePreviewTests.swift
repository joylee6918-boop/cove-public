import SwiftUI
import XCTest
@testable import Cove

/// Visual proposal only, NOT wired into the shipped voice message view.
/// Measurements checked against Telegram-iOS commit
/// 6ad963e5b62d354da79040f388ae2b9132fb17b8:
/// ChatMessageInteractiveFileNode: 44pt control, waveform x57/y1/h18,
/// duration x56/y22/font11. AudioWaveformComponent: bars2 + gap2, bottom gravity.
/// Cove retains the user's external timestamp row and its own pink palette.
@MainActor
final class CoveTelegramVoicePreviewTests: XCTestCase {
    func testSourceReferencedVoiceBubblePreview() throws {
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("语音条 · 新预览").font(.headline)
                    Text("Telegram iOS 布局 · Cove 配色")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ProposedVoiceBubble(duration: 17, playback: nil, outgoing: false, scheme: scheme)
                    Text("收到的语音").font(.caption2).foregroundStyle(.secondary).padding(.leading, 3)
                }
                HStack {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 5) {
                        ProposedVoiceBubble(duration: 24, playback: nil, outgoing: true, scheme: scheme)
                        Text("发出的语音").font(.caption2).foregroundStyle(.secondary).padding(.trailing, 3)
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 5) {
                        ProposedVoiceBubble(duration: 24, playback: 9, outgoing: true, scheme: scheme)
                        Text("播放时，波形随进度变色").font(.caption2).foregroundStyle(.secondary).padding(.trailing, 3)
                    }
                }
                Text("示例波形与时长，仅用于外观预览；未更新手机。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(22).frame(width: 390)
            .background(scheme == .dark ? Color(red: 0.13, green: 0.09, blue: 0.12) : Color(red: 0.99, green: 0.93, blue: 0.96))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let shot = XCTAttachment(image: image)
            shot.name = "telegram-source-voice-preview-\(scheme == .light ? "light" : "dark")"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertGreaterThan(image.size.height, 300)
        }
    }
}

private struct ProposedVoiceBubble: View {
    let duration: Double
    let playback: Double?
    let outgoing: Bool
    let scheme: ColorScheme
    private var accent: Color {
        scheme == .dark ? Color(red: 0.92, green: 0.62, blue: 0.76) : Color(red: 0.62, green: 0.25, blue: 0.43)
    }
    private var width: CGFloat { 120 + (276 - 120) * CGFloat((min(30, max(2, duration)) - 2) / 28) }
    private var fill: Color { outgoing ? CoveStyle.outgoing(scheme == .dark) : CoveStyle.incoming }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(accent).frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: playback == nil ? "play.fill" : "pause.fill")
                        .font(.system(size: 19, weight: .regular))
                        .offset(x: playback == nil ? 1 : 0)
                        .foregroundStyle(fill)
                }
                .offset(x: 3, y: 0)
            ExampleWaveform(fraction: (playback ?? 0) / duration, accent: accent)
                .frame(width: width - 60, height: 18)
                .offset(x: 57, y: 4)
            Text(playback.map { "\(coveVoiceTime($0)) / \(coveVoiceTime(duration))" } ?? coveVoiceTime(duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(accent)
                .offset(x: 56, y: 25)
        }
        .frame(width: width, height: 44, alignment: .topLeading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(fill, in: RoundedRectangle(cornerRadius: 17))
    }
}

/// Deliberately labelled example data; never used as a user's measured waveform.
private struct ExampleWaveform: View {
    let fraction: Double
    let accent: Color
    var body: some View {
        Canvas { context, size in
            let count = Int(size.width / 4)
            let example: [CGFloat] = [0.2,0.3,0.55,0.8,0.63,1,0.68,0.38,0.23,0.16,0.12,0.42,0.74,0.96,0.65,0.9,0.56,0.26,0.18,0.12,0.22,0.44,0.72,0.94,0.81,0.52,0.72,0.32,0.2,0.12,0.27,0.52,0.85,0.6,0.92,0.5,0.36,0.18,0.14,0.35,0.67,0.96,0.58,0.28]
            for index in 0..<count {
                let sample = example[index * example.count / max(1, count)]
                let height = max(2, sample * 18 - 3)
                let rect = CGRect(x: CGFloat(index) * 4, y: size.height - height, width: 2, height: height)
                let color = Double(index) / Double(max(1, count)) < fraction ? accent : accent.opacity(0.38)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }
}
