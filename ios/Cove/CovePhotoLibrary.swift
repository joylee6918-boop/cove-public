import SwiftUI
import Photos
import UIKit

@MainActor
final class CovePhotoLibrary: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var assets: [PHAsset] = []

    private let pageSize: Int
    private var result: PHFetchResult<PHAsset>?
    private var visibleCount = 0

    init(pageSize: Int = 120) {
        self.pageSize = max(120, pageSize)
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var canRead: Bool { authorizationStatus == .authorized || authorizationStatus == .limited }
    var hasMore: Bool { visibleCount < (result?.count ?? 0) }

    /// Called only from the user's attachment action. Limited access remains limited;
    /// Cove never opens the limited-library expansion prompt automatically.
    func requestAccess() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            authorizationStatus = current
        }
        reload()
    }

    func reload() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            result = nil
            visibleCount = 0
            assets = []
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetched = PHAsset.fetchAssets(with: options)
        result = fetched
        visibleCount = min(pageSize, fetched.count)
        assets = (0..<visibleCount).map { fetched.object(at: $0) }
    }

    func loadMore() {
        guard canRead, let result, visibleCount < result.count else { return }
        visibleCount = min(result.count, visibleCount + pageSize)
        assets = (0..<visibleCount).map { result.object(at: $0) }
    }

    static func loadPhoto(asset: PHAsset, ordinal: Int) async throws -> CoveOutgoingFile {
        let data = try await CovePhotoRequest.loadOriginal(asset)
        try Task.checkCancellation()
        return try await CoveAttachmentFiles.preparePhoto(data, ordinal: ordinal)
    }
}

private enum CovePhotoLibraryError: LocalizedError {
    case unavailable, cancelled
    var errorDescription: String? {
        switch self {
        case .unavailable: "这张照片暂时无法从照片图库或 iCloud 下载，请稍后重试。"
        case .cancelled: "已取消读取照片。"
        }
    }
}

private final class CovePhotoRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    static func loadOriginal(_ asset: PHAsset) async throws -> Data {
        let request = CovePhotoRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(asset, continuation: continuation)
            }
        } onCancel: {
            request.cancel()
        }
    }

    private func start(_ asset: PHAsset, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.finish(.failure(CovePhotoLibraryError.unavailable), cancelImageRequest: true)
        }
        lock.unlock()

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            // A degraded callback explicitly promises a later high-quality result.
            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
            let isCancelled = info?[PHImageCancelledKey] as? Bool == true
            let error = info?[PHImageErrorKey] as? Error
            if isCancelled { self.finish(.failure(CancellationError())) }
            else if let error { self.finish(.failure(error)) }
            else if let data, !data.isEmpty { self.finish(.success(data)) }
            else { self.finish(.failure(CovePhotoLibraryError.unavailable)) }
        }
        lock.lock()
        requestID = id
        let shouldCancel = finished
        lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }

    private func cancel() {
        finish(.failure(CancellationError()), cancelImageRequest: true)
    }

    private func finish(_ result: Result<Data, Error>, cancelImageRequest: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let id = requestID
        let continuation = self.continuation
        self.continuation = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        if cancelImageRequest, id != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(id) }
        continuation?.resume(with: result)
    }
}

struct CovePhotoThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var unavailable = false
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var generation = 0

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if unavailable {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: asset.localIdentifier) { requestThumbnail() }
        .onDisappear { cancelThumbnail() }
    }

    private func requestThumbnail() {
        cancelThumbnail()
        image = nil
        unavailable = false
        generation += 1
        let expectedGeneration = generation
        let expectedAsset = asset.localIdentifier
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(for: asset,
            targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFill, options: options) { result, info in
                guard info?[PHImageCancelledKey] as? Bool != true else { return }
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                DispatchQueue.main.async {
                    guard generation == expectedGeneration, asset.localIdentifier == expectedAsset else { return }
                    if let result { image = result }
                    else if !degraded { unavailable = true }
                }
            }
    }

    private func cancelThumbnail() {
        generation += 1
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

