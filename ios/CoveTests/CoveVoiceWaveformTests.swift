import Foundation
import XCTest
@testable import Cove

final class CoveVoiceWaveformTests: XCTestCase {
    /// Hand-built PCM WAV; all audio in this suite is synthetic, never captured.
    private func wav(sampleRate: UInt32 = 16_000, channels: UInt16 = 1, samples: [Int16]) -> Data {
        var data = Data()
        func bytes(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        let pcmBytes = UInt32(samples.count * 2)
        bytes("RIFF"); u32(36 + pcmBytes); bytes("WAVEfmt "); u32(16)
        u16(1); u16(channels); u32(sampleRate); u32(sampleRate * UInt32(channels) * 2)
        u16(channels * 2); u16(16); bytes("data"); u32(pcmBytes)
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }

    func testPeaksComeFromSoundAndPauseAndNormalizeToOne() throws {
        // Four equally long sections: positive sound, true silence, louder
        // negative sound, silence. Peak magnitude must retain the distinction.
        let samples = [Int16](repeating: 4000, count: 4000)
            + [Int16](repeating: 0, count: 4000)
            + [Int16](repeating: -16000, count: 4000)
            + [Int16](repeating: 0, count: 4000)
        let peaks = try CoveVoiceWaveform.decode(data: wav(samples: samples))
        XCTAssertEqual(peaks.count, 128)
        XCTAssertTrue(peaks[0..<32].allSatisfy { abs($0 - 0.25) < 0.001 })
        XCTAssertTrue(peaks[32..<64].allSatisfy { $0 == 0 })
        XCTAssertTrue(peaks[64..<96].allSatisfy { $0 == 1 })
        XCTAssertTrue(peaks[96..<128].allSatisfy { $0 == 0 })
    }

    func testSilentAudioReturnsActualZeros() throws {
        let peaks = try CoveVoiceWaveform.decode(data: wav(samples: [Int16](repeating: 0, count: 1000)))
        XCTAssertEqual(peaks.count, 128)
        XCTAssertTrue(peaks.allSatisfy { $0 == 0 })
    }

    func testVeryShortValidFileDoesNotInventExtraBars() throws {
        let peaks = try CoveVoiceWaveform.decode(data: wav(samples: [0, 1000, -2000, 0]))
        XCTAssertEqual(peaks, [0, 0.5, 1, 0])
    }

    func testDataSliceWithNonzeroStartIndexDecodesWithoutIndexingOutsideIt() throws {
        var prefixed = Data([0x11, 0x22, 0x33])
        prefixed.append(wav(samples: [0, 1000, -2000, 0]))
        let sliced = prefixed.dropFirst(3)
        XCTAssertEqual(try CoveVoiceWaveform.decode(data: sliced), [0, 0.5, 1, 0])
    }

    func testStereoUsesRealPeakAcrossBothChannels() throws {
        let peaks = try CoveVoiceWaveform.decode(data: wav(channels: 2, samples: [0, 1000, -2000, 0, 0, 0]))
        XCTAssertEqual(peaks, [0.5, 1, 0])
    }

    func testEmptyAndOversizedBytesAreRejectedBeforeDecode() {
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: Data())) { XCTAssertEqual($0 as? CoveVoiceWaveform.DecodeError, .empty) }
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: Data(repeating: 0, count: CoveVoiceWaveform.maximumBytes + 1))) {
            XCTAssertEqual($0 as? CoveVoiceWaveform.DecodeError, .tooLarge)
        }
    }

    func testMalformedAndNoFrameAudioAreRejected() {
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: Data("not an audio file".utf8))) {
            XCTAssertEqual($0 as? CoveVoiceWaveform.DecodeError, .invalidAudio)
        }
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: wav(samples: [])))
    }

    func testSampleRateBoundIsEnforced() {
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: wav(sampleRate: 192_000, samples: [0, 1, 2, 3]))) {
            XCTAssertEqual($0 as? CoveVoiceWaveform.DecodeError, .unsupportedFormat)
        }
    }

    func testChannelBoundIsEnforced() {
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: wav(channels: 9, samples: [Int16](repeating: 1, count: 90)))) {
            // Some platform decoders reject unsupported WAV channel layouts
            // before exposing a processing format, which is also honest failure.
            XCTAssertTrue([CoveVoiceWaveform.DecodeError.unsupportedFormat, .invalidAudio].contains($0 as? CoveVoiceWaveform.DecodeError ?? .empty))
        }
    }

    func testDurationBoundIsEnforcedWithoutLargeAllocation() {
        let data = wav(sampleRate: 8000, samples: [Int16](repeating: 0, count: 8000 * 301))
        XCTAssertThrowsError(try CoveVoiceWaveform.decode(data: data)) {
            XCTAssertEqual($0 as? CoveVoiceWaveform.DecodeError, .tooLong)
        }
    }

    func testDecodingCanRunOffMainActorAndCancellationIsObserved() async throws {
        let data = wav(samples: [Int16](repeating: 1000, count: 1000))
        let peaks = try await Task.detached { try CoveVoiceWaveform.decode(data: data) }.value
        XCTAssertEqual(peaks.count, 128)
        let cancelled = Task.detached { () throws -> [Float] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try CoveVoiceWaveform.decode(data: data)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled decoding must not succeed.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
