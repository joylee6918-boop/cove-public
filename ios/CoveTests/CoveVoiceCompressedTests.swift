import Foundation
import XCTest
@testable import Cove

@MainActor
final class CoveVoiceCompressedTests: XCTestCase {
    // Generated electronic-tone fixture, explicitly synthetic. Does not play sound or
    // activate a microphone/audio session, and never enters a user conversation.
    func testOriginalAACAndMP3ProduceWaveformAndSupportPlaybackSeeking() async throws {
        for ext in ["m4a", "mp3"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "voice-synthetic", withExtension: ext))
            let data = try Data(contentsOf: url)
            let peaks = try await Task.detached { try CoveVoiceWaveform.decode(data: data) }.value
            XCTAssertEqual(peaks.count, 128)
            XCTAssertEqual(peaks.max(), 1)
            XCTAssertGreaterThan(Set(peaks).count, 20)
            XCTAssertTrue(peaks.contains { $0 < 0.1 }, "Synthetic tone contains a one-second pause")
            let player = CoveVoicePlayer()
            try player.prepare(data: data)
            XCTAssertGreaterThan(player.duration, 4)
            XCTAssertLessThan(player.duration, 6)
            XCTAssertFalse(player.isPlaying)
            player.seek(to: 2)
            XCTAssertEqual(player.currentTime, 2, accuracy: 0.02)
            player.seek(to: -1)
            XCTAssertEqual(player.currentTime, 0)
            player.stop()
        }
    }
}
