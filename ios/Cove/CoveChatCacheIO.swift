import Foundation

/// Small draft sidecar. A revision fence prevents stale drafts from undoing a
/// newer durable send/clear saved in the main cache, including after a crash.
struct CoveDraftSnapshot: Codable {
    let revision: UInt64
    let drafts: [String: String]

    func restoring(over drafts: [String: String], cacheRevision: UInt64) -> [String: String] {
        revision > cacheRevision ? self.drafts : drafts
    }
}

/// One ordered writer for both files; encoding never runs on the UI executor.
/// Sending still waits for its durable outbox checkpoint before any network IO.
final class CoveChatCacheIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cove.chat-cache.io", qos: .utility)

    func write<T: Encodable>(_ value: T, to url: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            do { try Self.save(value, to: url); completion(nil) }
            catch { completion(error) }
        }
    }

    func writeSynchronously<T: Encodable>(_ value: T, to url: URL) throws {
        // DispatchQueue.sync may execute on the calling (main) thread.
        // Use an async worker plus an explicit durability fence for sends.
        let done = DispatchSemaphore(value: 0)
        let result = WriteResult()
        write(value, to: url) { error in result.error = error; done.signal() }
        done.wait()
        if let error = result.error { throw error }
    }

    func read(_ url: URL) -> Data? { queue.sync { try? Data(contentsOf: url) } }
    func flush() { queue.sync {} }

    private final class WriteResult: @unchecked Sendable { var error: Error? }

    private static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
