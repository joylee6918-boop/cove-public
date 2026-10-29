import SwiftUI
import XCTest
@testable import Cove

@MainActor
final class CoveVoiceBubbleTests: XCTestCase {
    private static let fixture: [Float] = (0..<128).map { index in
        let wave = abs(sin(Double(index) * 0.45))
        let envelope = 0.15 + 0.85 * abs(sin(Double(index) * 0.13))
        return Float(wave * envelope)
    }

    func testWaveformPeakResamplingAndInvalidSamples() {
        XCTAssertEqual(CoveVoiceWaveformBars.resample([0, 1, 0.2, 0.4], count: 2), [1, 0.4])
        XCTAssertEqual(CoveVoiceWaveformBars.resample([.nan, -.infinity, -1], count: 1), [0])
        XCTAssertEqual(CoveVoiceWaveformBars.resample([], count: 30), [])
        XCTAssertEqual(CoveVoiceWaveformBars.resample([1], count: 10000).count, 512)
    }

    func testSeekClampsToRealDuration() {
        XCTAssertTrue(CoveVoiceBubbleLabel.isHorizontalSeek(x: 20, y: 5))
        XCTAssertFalse(CoveVoiceBubbleLabel.isHorizontalSeek(x: 2, y: 20))
        XCTAssertFalse(CoveVoiceBubbleLabel.isHorizontalSeek(x: .nan, y: 0))
        XCTAssertEqual(CoveVoiceBubbleLabel.seekFraction(x: -10, width: 100), 0)
        XCTAssertEqual(CoveVoiceBubbleLabel.seekFraction(x: 500, width: 100), 1)
        XCTAssertEqual(CoveVoiceBubbleLabel.seekFraction(x: 25, width: 100), 0.25)
        XCTAssertEqual(CoveVoiceBubbleLabel.seekFraction(x: .nan, width: 100), 0)
        XCTAssertEqual(CoveVoiceBubbleLabel.seekFraction(x: 20, width: 0), 0)
    }

    func testSecondsAreActualRoundedDurationNotPlaceholderAudioLength() {
        XCTAssertEqual(CoveVoiceBubbleLabel.secondsLabel(4.97), "0:04")
        XCTAssertEqual(CoveVoiceBubbleLabel.secondsLabel(0), "—:—")
        XCTAssertEqual(CoveVoiceBubbleLabel.secondsLabel(.nan), "—:—")
        XCTAssertEqual(CoveVoiceBubbleLabel.secondsLabel(120), "2:00")
    }

    func testCompactWidthIsBoundedAndHandlesInvalidDuration() {
        XCTAssertEqual(CoveVoiceBubbleLabel.controlSize, 24)
        XCTAssertEqual(CoveVoiceBubbleLabel.waveformHeight, 18)
        XCTAssertEqual(CoveVoiceBubbleLabel.contentHeight, 34)
        XCTAssertEqual(CoveVoiceBubbleLabel.waveformX, 40)
        XCTAssertEqual(CoveVoiceBubbleLabel.playHitOffset.height + 22,
                       CoveVoiceBubbleLabel.contentHeight / 2)
        XCTAssertLessThan(CoveVoiceBubbleLabel.playHitOffset.width + 44,
                          CoveVoiceBubbleLabel.waveformX)
        XCTAssertEqual(CoveVoiceBubbleLabel.width(for: .infinity), 180)
        XCTAssertEqual(CoveVoiceBubbleLabel.width(for: 120), 276)
        XCTAssertGreaterThan(CoveVoiceBubbleLabel.width(for: 30), CoveVoiceBubbleLabel.width(for: 3))
    }

    func testCompactBubbleAppearanceInBothColorSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 24) {
                Text("24pt 播放键居中 · 合成波形与示例时长").font(.caption).foregroundStyle(.secondary)
                HStack {
                    CoveVoiceBubbleLabel(duration: 17, samples: Self.fixture, onPlay: {})
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(CoveStyle.incoming, in: RoundedRectangle(cornerRadius: 20))
                    Spacer()
                }
                HStack {
                    Spacer()
                    CoveVoiceBubbleLabel(duration: 24, isOutgoing: true, samples: Self.fixture, onPlay: {})
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(CoveStyle.outgoing(scheme == .dark), in: RoundedRectangle(cornerRadius: 20))
                }
                HStack {
                    Spacer()
                    CoveVoiceBubbleLabel(duration: 24, progress: 9, isPlaying: true, isOutgoing: true, samples: Self.fixture, onPlay: {})
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(CoveStyle.outgoing(scheme == .dark), in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(24).frame(width: 360)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 180)
            let shot = XCTAttachment(image: image)
            shot.name = "telegram-production-voice-bubbles-\(scheme == .light ? "light" : "dark")"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
}
