import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import ImageIO
import WebKit

// A single cap is shared by photo and security-scoped file imports.
enum CoveAttachmentError: LocalizedError {
    case tooLarge, unreadable, tooMany, empty, unsafePreview
    var errorDescription: String? {
        switch self {
        case .tooLarge: "每个附件最多 20 MiB，请选择小一些的文件。"
        case .unreadable: "这个附件暂时无法读取，请重新选择。"
        case .tooMany: "一次最多发送 10 个附件。"
        case .empty: "这个文件是空的，请重新选择。"
        case .unsafePreview: "暂时无法打开预览，可以查看源码或保存原文件。"
        }
    }
}

enum CoveAttachmentFiles {
    static let maximumBytes = 20 * 1024 * 1024

    // File-provider coordination and disk IO run off the main actor. Access is
    // relinquished only after all bytes have been copied out of the provider.
    static func readSelected(_ urls: [URL]) async throws -> [CoveOutgoingFile] {
        try await Task.detached(priority: .userInitiated) {
            guard urls.count <= 10 else { throw CoveAttachmentError.tooMany }
            return try urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var result: Result<CoveOutgoingFile, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    result = Result {
                        let values = try readable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
                        guard values.isRegularFile == true else { throw CoveAttachmentError.unreadable }
                        guard (values.fileSize ?? 0) <= maximumBytes else { throw CoveAttachmentError.tooLarge }
                        let data = try Data(contentsOf: readable)
                        guard !data.isEmpty else { throw CoveAttachmentError.empty }
                        guard data.count <= maximumBytes else { throw CoveAttachmentError.tooLarge }
                        let type = values.contentType ?? UTType(filenameExtension: readable.pathExtension)
                        return CoveOutgoingFile(data: data, filename: url.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream")
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw CoveAttachmentError.unreadable }
                return try result.get()
            }
        }.value
    }

    static func cache(_ data: Data, filename: String, mime: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard data.count <= maximumBytes else { throw CoveAttachmentError.tooLarge }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CoveAttachments", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var name = (filename as NSString).lastPathComponent
                .components(separatedBy: .controlCharacters).joined()
                .replacingOccurrences(of: ":", with: "_")
            if name.isEmpty || name == "." || name == ".." { name = "附件" }
            name = String(name.prefix(180))
            if (name as NSString).pathExtension.isEmpty, let ext = UTType(mimeType: mime)?.preferredFilenameExtension { name += "." + ext }
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }.value
    }
}

enum CoveAttachmentImageError: LocalizedError {
    case abnormalDimensions, unreadable
    var errorDescription: String? {
        switch self {
        case .abnormalDimensions: "图片尺寸过大，可以分享或保存原文件。"
        case .unreadable: "暂时无法预览这张图片，可以分享或保存原文件。"
        }
    }
}

enum CoveAttachmentImages {
    static let thumbnailPixelLimit = 768
    static let previewPixelLimit = 4_096

    static func downsample(_ url: URL, maximumPixelSize: Int) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard maximumPixelSize > 0, maximumPixelSize <= previewPixelLimit,
                      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
                    throw CoveAttachmentImageError.unreadable
                }
                // Inspect metadata before any pixel decoding. This admits ordinary
                // high-resolution photos but avoids pathological dimensions.
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      width <= 32_768, height <= 32_768, width * height <= 120_000_000 else {
                    throw CoveAttachmentImageError.abnormalDimensions
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      image.width <= maximumPixelSize, image.height <= maximumPixelSize else {
                    throw CoveAttachmentImageError.unreadable
                }
                try Task.checkCancellation()
                return UIImage(cgImage: image)
            }
        }.value
    }
}

private struct CovePresentedAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let image: UIImage?
    let imageFailure: String?
}

struct CoveAttachmentView: View {
    @EnvironmentObject private var store: CoveStore
    let attachment: ChatAttachment
    @State private var localURL: URL?
    @State private var thumbnail: UIImage?
    @State private var isLoading = false
    @State private var isPreparingPreview = false
    @State private var imageFailure: String?
    @State private var failure: String?
    @State private var presentedFile: CovePresentedAttachment?
    private var isImage: Bool { attachment.mime.lowercased().hasPrefix("image/") && !attachment.mime.lowercased().contains("svg") }
    private var isHTML: Bool {
        attachment.mime.lowercased().contains("html") || ["html", "htm", "xhtml"].contains((attachment.filename as NSString).pathExtension.lowercased())
    }
    private var typeLabel: String {
        if isHTML { return "HTML 网页" }
        return UTType(mimeType: attachment.mime)?.localizedDescription ?? attachment.mime
    }
    private var sizeLabel: String {
        attachment.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) : ""
    }

    var body: some View {
        Button {
            Task { await openAttachment() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if isImage {
                    Group {
                        if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
                        else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                    .frame(width: 240, height: 180)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 10) {
                    Image(systemName: isHTML ? "chevron.left.forwardslash.chevron.right" : isImage ? "photo" : "doc")
                        .font(.title3).foregroundStyle(.tint).frame(width: 30, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.filename).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Text([typeLabel, sizeLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if isLoading { ProgressView() }
                    else { Image(systemName: localURL == nil ? "arrow.down.circle" : "arrow.up.right.square").foregroundStyle(.tint) }
                }
                if isLoading { Text(isPreparingPreview ? "正在准备预览…" : "正在下载…").font(.caption).foregroundStyle(.secondary) }
                else if let failure { Label(failure + " · 点此重试", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
                else if let imageFailure { Text(imageFailure).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: 280, alignment: .leading).padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                // Plain buttons otherwise leave gaps between the label's text,
                // icons and spacer outside the tappable area.
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(isLoading)
            .accessibilityLabel("\(attachment.filename)，\(typeLabel)，\(sizeLabel)")
            .accessibilityValue(isPreparingPreview ? "正在准备预览" : isLoading ? "正在下载" : localURL == nil ? "未下载" : "已下载")
            .accessibilityHint(failure == nil ? "下载并预览附件" : "下载失败，轻点重试")
            .accessibilityIdentifier("chat.attachment.\(attachment.id)")
            .task(id: attachment.url) {
                localURL = nil
                thumbnail = nil
                imageFailure = nil
                failure = nil
                if isImage { await download(openAfter: false) }
            }
            .sheet(item: $presentedFile) { file in
                CoveAttachmentPreview(url: file.url, filename: attachment.filename, isHTML: isHTML, image: file.image, imageFailure: file.imageFailure)
            }
    }

    @MainActor private func openAttachment() async {
        guard !isLoading else { return }
        guard let localURL else { await download(openAfter: true); return }
        isLoading = true
        defer { isLoading = false }
        await presentAttachment(localURL)
    }

    @MainActor private func presentAttachment(_ url: URL) async {
        guard isImage else {
            presentedFile = CovePresentedAttachment(url: url, image: nil, imageFailure: nil)
            return
        }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        do {
            let image = try await CoveAttachmentImages.downsample(url, maximumPixelSize: CoveAttachmentImages.previewPixelLimit)
            try Task.checkCancellation()
            presentedFile = CovePresentedAttachment(url: url, image: image, imageFailure: nil)
        } catch is CancellationError { return }
        catch {
            // Keep the original URL for saving, but never ask UIImage or Quick Look
            // to decode a source rejected by the bounded image path.
            presentedFile = CovePresentedAttachment(url: url, image: nil, imageFailure: error.localizedDescription)
        }
    }

    @MainActor private func download(openAfter: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let path = attachment.url
            let data = try await store.attachmentData(path)
            try Task.checkCancellation()
            let cached = try await CoveAttachmentFiles.cache(data, filename: attachment.filename, mime: attachment.mime)
            try Task.checkCancellation()
            guard path == attachment.url else { return }
            localURL = cached
            if isImage {
                do {
                    thumbnail = try await CoveAttachmentImages.downsample(cached, maximumPixelSize: CoveAttachmentImages.thumbnailPixelLimit)
                } catch is CancellationError { throw CancellationError() }
                catch { imageFailure = error.localizedDescription }
            }
            if openAfter { await presentAttachment(cached) }
        } catch is CancellationError {
            // Scrolling away cancels a thumbnail load; its next task can retry.
        } catch { failure = "附件暂时无法下载" }
    }
}

private struct CoveAttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let filename: String
    let isHTML: Bool
    let image: UIImage?
    let imageFailure: String?
    @State private var showShare = false
    @State private var showSource = false

    var body: some View {
        NavigationStack {
            Group {
                if isHTML { CoveHTMLPreview(url: url, showSource: showSource) }
                else if let image { CoveZoomableImage(image: image).background(.black) }
                else if let imageFailure {
                    ContentUnavailableView("图片暂时无法预览", systemImage: "photo", description: Text(imageFailure))
                }
                else if QLPreviewController.canPreview(url as NSURL) { CoveQuickLook(url: url) }
                else { ContentUnavailableView("暂不支持直接预览", systemImage: "doc", description: Text("可以通过分享保存到“文件”，或用其他 App 打开。")) }
            }
            .navigationTitle(filename).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() }.accessibilityIdentifier("attachment.done") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isHTML {
                        Button { showSource.toggle() } label: {
                            Text(showSource ? "网页" : "源码")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                            .accessibilityIdentifier("attachment.source")
                    }
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("分享或保存到文件").accessibilityIdentifier("attachment.share")
                }
            }
        }.sheet(isPresented: $showShare) { CoveShareSheet(url: url) }
    }
}

private struct CoveShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct CoveQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct CoveZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ZoomImageScrollView { ZoomImageScrollView(image: image) }
    func updateUIView(_ view: ZoomImageScrollView, context: Context) {}
}

private final class ZoomImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var lastBounds: CGSize = .zero
    init(image: UIImage) {
        super.init(frame: .zero)
        picture.image = image
        picture.frame = CGRect(origin: .zero, size: image.size)
        addSubview(picture)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        accessibilityLabel = "图片预览，可双指缩放或双击放大"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds, bounds.width > 0, bounds.height > 0, let image = picture.image {
            lastBounds = bounds.size
            minimumZoomScale = min(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
            maximumZoomScale = max(minimumZoomScale * 5, 3)
            zoomScale = minimumZoomScale
        }
        centerPicture()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPicture() }
    private func centerPicture() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 { setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
            let center = tap.location(in: picture)
            zoom(to: CGRect(x: center.x - bounds.width / scale / 2, y: center.y - bounds.height / scale / 2, width: bounds.width / scale, height: bounds.height / scale), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}

private struct CoveHTMLPreview: View {
    let url: URL
    let showSource: Bool
    @State private var source: String?
    @State private var previewURL: URL?
    @State private var failure: String?
    @State private var isWebReady = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本地网页 · 外部资源不会加载")
                Spacer(minLength: 8)
                if isWebReady && !showSource {
                    Text("已就绪").accessibilityIdentifier("attachment.htmlReady")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
            Divider()
            if showSource, let source {
                ScrollView([.horizontal, .vertical]) {
                    Text(source).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(16)
                        .accessibilityIdentifier("attachment.htmlSource")
                }
            } else if let failure {
                ContentUnavailableView("网页暂时无法预览", systemImage: "doc", description: Text(failure))
            } else if let previewURL {
                CoveLocalHTMLWebView(url: previewURL, onReadyChange: { isWebReady = $0 }, onFailure: { failure = "可以查看源码，或分享并保存原文件。" })
                    .allowsHitTesting(isWebReady)
                    .accessibilityIdentifier("attachment.htmlPreview")
                    .overlay {
                        if !isWebReady {
                            ProgressView("正在加载网页…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(uiColor: .systemBackground))
                        }
                    }
            } else { ProgressView("正在准备网页…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.onChange(of: showSource) { isWebReady = false }
        .task(id: url) {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url)
                    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
                    let directory = url.deletingLastPathComponent().appendingPathComponent("Preview-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let preview = directory.appendingPathComponent("index.html")
                    // An independent policy added ahead of any untrusted markup cannot
                    // be relaxed by a second policy in the original file.
                    let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
                    let prefix = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                    try (prefix + text).write(to: preview, atomically: true, encoding: .utf8)
                    return (text, preview)
                }.value
                source = result.0
                previewURL = result.1
            } catch { failure = "文件读取失败，请返回后重新下载。" }
        }
    }
}

private struct CoveLocalHTMLWebView: UIViewRepresentable {
    let url: URL
    let onReadyChange: (Bool) -> Void
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(url: url, onReadyChange: onReadyChange, onFailure: onFailure) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // No message handlers, app credentials, or app storage are exposed. Block
        // peer/worker APIs too: peer connections are not governed by connect-src.
        let lockdown = """
        (() => {
          for (const key of ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','WebSocket','WebTransport','Worker','SharedWorker']) {
            try { Object.defineProperty(window, key, {value: undefined, writable: false, configurable: false}); } catch (_) {}
          }
          try { Object.defineProperty(navigator, 'serviceWorker', {value: undefined, configurable: false}); } catch (_) {}
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: lockdown, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isInspectable = false
        webView.allowsLinkPreview = false
        // WebKit content filters accept only a subset of regular expressions;
        // alternatives such as (file|data|blob) fail to compile. Keep each local
        // scheme in its own rule (webkit.org/blog/3476/content-blockers-first-look/).
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "CoveLocalHTMLOnly-v2", encodedContentRuleList: rules) { [weak webView] list, _ in
            guard let webView else { return }
            guard let list else { onFailure(); return }
            webView.configuration.userContentController.add(list)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let url: URL
        let onReadyChange: (Bool) -> Void
        let onFailure: () -> Void
        init(url: URL, onReadyChange: @escaping (Bool) -> Void, onFailure: @escaping () -> Void) {
            self.url = url; self.onReadyChange = onReadyChange; self.onFailure = onFailure
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            webView.isUserInteractionEnabled = false
            onReadyChange(false)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.isUserInteractionEnabled = true
            onReadyChange(true)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame == true,
                  let destination = navigationAction.request.url, destination.isFileURL,
                  destination.standardizedFileURL.path == url.standardizedFileURL.path else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }
    }
}
