import AVFoundation
import Foundation

/// Offline, bounded decoding of the actual attachment. No audio session, player,
/// microphone or network is involved, so this can run in Task.detached.
enum CoveVoiceWaveform {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumDuration: Double = 300
    static let maximumSampleRate: Double = 96_000
    static let maximumChannels: AVAudioChannelCount = 8
    static let maximumBins = 128

    enum DecodeError: LocalizedError, Equatable {
        case empty, tooLarge, invalidAudio, unsupportedFormat, tooLong
        var errorDescription: String? {
            switch self {
            case .empty: "没有可读取的音频。"
            case .tooLarge: "音频超过 20 MiB，未生成波形。"
            case .invalidAudio: "音频格式损坏或无法解码，未生成波形。"
            case .unsupportedFormat: "音频采样率或声道数超出波形读取范围。"
            case .tooLong: "音频超过 5 分钟，未生成波形。"
            }
        }
    }

    static func decode(data: Data) throws -> [Float] {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DecodeError.empty }
        guard data.count <= maximumBytes else { throw DecodeError.tooLarge }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("cove-waveform-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.\(fileExtension(data))")
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Task.checkCancellation()
        return try decodeFile(url: url)
    }

    private static func decodeFile(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw DecodeError.invalidAudio }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= maximumSampleRate,
              channels > 0, channels <= maximumChannels,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw DecodeError.unsupportedFormat }
        let frameCount = file.length
        guard frameCount > 0 else { throw DecodeError.invalidAudio }
        let limit = AVAudioFramePosition(sampleRate * maximumDuration)
        guard frameCount <= limit else { throw DecodeError.tooLong }
        let binCount = min(maximumBins, Int(frameCount))
        var peaks = [Float](repeating: 0, count: binCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw DecodeError.unsupportedFormat }
        var position: AVAudioFramePosition = 0
        while position < frameCount {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), frameCount - position))
            // AVAudioFile may leave the prior frameLength intact at EOF. Never
            // probe past its declared decoded length or reuse a previous block.
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: requested) }
            catch { throw DecodeError.invalidAudio }
            let count = Int(buffer.frameLength)
            guard count > 0, count <= Int(requested) else { throw DecodeError.invalidAudio }
            guard position + AVAudioFramePosition(count) <= limit else { throw DecodeError.tooLong }
            // Never fill nonexistent tail time with invented silence or squash
            // unexpected extra frames into the last bar of a corrupt file.
            guard position + AVAudioFramePosition(count) <= frameCount,
                  let samples = buffer.floatChannelData else { throw DecodeError.invalidAudio }
            for frame in 0..<count {
                var peak: Float = 0
                for channel in 0..<Int(channels) {
                    let sample = samples[channel][frame]
                    guard sample.isFinite else { throw DecodeError.invalidAudio }
                    peak = max(peak, abs(sample))
                }
                let bin = Int((position + AVAudioFramePosition(frame)) * AVAudioFramePosition(binCount) / frameCount)
                peaks[bin] = max(peaks[bin], peak)
            }
            position += AVAudioFramePosition(count)
        }
        try Task.checkCancellation()
        guard position == frameCount else { throw DecodeError.invalidAudio }
        let maximum = peaks.max() ?? 0
        // A silent file is honestly all zeros, not a decorative minimum height.
        if maximum > 0 { for index in peaks.indices { peaks[index] /= maximum } }
        return peaks
    }

    private static func fileExtension(_ data: Data) -> String {
        // Data slices may retain a nonzero startIndex. Inspect a tiny normalized
        // header rather than indexing the original attachment as though it began at 0.
        let header = Array(data.prefix(12))
        if header.count >= 12, header[0..<4].elementsEqual("RIFF".utf8), header[8..<12].elementsEqual("WAVE".utf8) { return "wav" }
        if header.count >= 8, header[4..<8].elementsEqual("ftyp".utf8) { return "m4a" }
        if header.starts(with: "ID3".utf8) || (header.count >= 2 && header[0] == 0xff && header[1] & 0xe0 == 0xe0) { return "mp3" }
        if header.starts(with: "caff".utf8) { return "caf" }
        return "audio"
    }
}
