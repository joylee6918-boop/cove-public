import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

private enum CoveStickerError: LocalizedError {
    case unsupported, dimensions
    var errorDescription: String? {
        switch self {
        case .unsupported: "请选择 PNG、JPEG、WebP 或 GIF 图片，大小不超过 20 MiB。"
        case .dimensions: "这张图片尺寸异常，无法作为表情包预览。"
        }
    }
}

enum CoveStickerImages {
    /// Validate original bytes; never transcode GIF or flatten transparency.
    static func validatedFile(_ file: CoveOutgoingFile) async throws -> CoveOutgoingFile {
        try await Task.detached(priority: .userInitiated) {
            guard !file.data.isEmpty, file.data.count <= CoveAttachmentFiles.maximumBytes,
                  let source = CGImageSourceCreateWithData(file.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let rawType = CGImageSourceGetType(source), let type = UTType(rawType as String),
                  let mime = type.preferredMIMEType,
                  ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mime) else { throw CoveStickerError.unsupported }
            try validateDimensions(source)
            var result = file
            result.mime = mime
            return result
        }.value
    }

    private static func validateDimensions(_ source: CGImageSource) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width <= 32_768, height <= 32_768, width * height <= 120_000_000 else {
            throw CoveStickerError.dimensions
        }
    }

    static func decode(_ data: Data, animate: Bool) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard data.count <= CoveAttachmentFiles.maximumBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw CoveStickerError.unsupported
            }
            try validateDimensions(source)
            let count = CGImageSourceGetCount(source)
            guard count > 0, count <= 10_000 else { throw CoveStickerError.unsupported }
            // Bound decoded memory, even for an unusually long or large GIF.
            // Library thumbnails are static; chat animates at most 200 sampled frames.
            let frameCount = animate ? min(count, 200) : 1
            let pixels = min(480, Int(sqrt(Double(8 * 1024 * 1024) / Double(max(1, frameCount) * 4))))
            var frames: [UIImage] = []
            var delays: [Double] = []
            for slot in 0..<frameCount {
                try Task.checkCancellation()
                let index = slot * count / frameCount
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    throw CoveStickerError.unsupported
                }
                frames.append(UIImage(cgImage: cgImage))
                if frameCount == 1 { continue }
                var delay = 0.0
                let next = (slot + 1) * count / frameCount
                for frameIndex in index..<next {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any]
                    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                        ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                    delay += raw.isFinite ? min(10, max(0.02, raw)) : 0.1
                }
                delays.append(delay)
            }
            guard let first = frames.first else { throw CoveStickerError.unsupported }
            guard frames.count > 1 else { return first }
            // Repeated references preserve GIF frame timing without duplicating pixels.
            let duration = delays.reduce(0, +)
            let quantum = max(0.02, duration / 1_000)
            var timed: [UIImage] = []
            for (index, frame) in frames.enumerated() {
                timed.append(contentsOf: repeatElement(frame, count: max(1, Int((delays[index] / quantum).rounded()))))
            }
            return UIImage.animatedImage(with: timed, duration: duration) ?? first
        }.value
    }
}

private struct CoveAnimatedSticker: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) { view.image = image }
    static func dismantleUIView(_ view: UIImageView, coordinator: ()) { view.stopAnimating(); view.image = nil }
}

struct CoveStickerView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attachment: ChatAttachment
    var maximumSide: CGFloat = 160
    var animate = true
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let image { CoveAnimatedSticker(image: image) }
            else if let failure {
                Button { retry += 1 } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("点此重试").font(.caption)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("表情包未加载：\(failure)，轻点重试")
            } else { ProgressView().accessibilityLabel("正在加载表情包") }
        }
        .frame(width: maximumSide, height: maximumSide)
        .accessibilityLabel(attachment.filename)
        .task(id: "\(attachment.url)|\(animate && !reduceMotion)|\(retry)") {
            image = nil; failure = nil
            do {
                let data = try await store.attachmentData(attachment.url)
                let result = try await CoveStickerImages.decode(data, animate: animate && !reduceMotion)
                try Task.checkCancellation()
                image = result
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct CoveStickerImport: Identifiable {
    let id = UUID()
    let file: CoveOutgoingFile
}

struct CoveStickerPicker: View {
    var onSend: () -> Void = {}
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @State private var owner = "user"
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var preparing = false
    @State private var sending = false
    @State private var failure: String?
    @State private var imported: CoveStickerImport?
    private var visible: [CoveSticker] { store.stickers.filter { $0.owner == owner } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("表情包归属", selection: $owner) {
                    Text("我的").tag("user")
                    Text("助手 的").tag("assistant")
                }.pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("stickers.owner")
                if store.previewMode {
                    Label("界面预览 · 不会读取或上传真实表情包", systemImage: "eye")
                        .font(.caption).foregroundStyle(CoveStyle.secondaryText).padding(.horizontal)
                }
                if let error = failure ?? store.stickerError {
                    VStack(spacing: 4) {
                        Text(error).font(.footnote).foregroundStyle(CoveStyle.error)
                        if store.stickerError != nil {
                            Button("重新加载") { Task { await store.reloadStickers() } }.frame(minHeight: 44)
                        }
                    }.padding(.horizontal)
                }
                ScrollView {
                    if visible.isEmpty {
                        ContentUnavailableView(owner == "user" ? "还没有表情包" : "助手 还没有保存表情包",
                            systemImage: "face.smiling", description: Text(owner == "user"
                                ? "从照片或文件添加，也可以长按聊天里的图片保存。"
                                : "发图片给 助手，请他保存后，就会出现在这里。"))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                            ForEach(visible) { sticker in
                                Button {
                                    guard !sending else { return }
                                    sending = true
                                    Task {
                                        if await store.sendSticker(sticker) { onSend(); dismiss() }
                                        else { failure = store.errorMessage }
                                        sending = false
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        CoveStickerView(attachment: sticker.attachment, maximumSide: 84, animate: false)
                                        Text(sticker.label).font(.caption).foregroundStyle(CoveStyle.text).lineLimit(2)
                                    }.frame(maxWidth: .infinity, minHeight: 116).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(sending || store.previewMode)
                                    .accessibilityLabel("发送表情包：\(sticker.label)")
                                    .accessibilityIdentifier("stickers.send.\(sticker.id)")
                            }
                        }.padding(.horizontal)
                    }
                }.refreshable { await store.reloadStickers() }
                if preparing || store.isLoadingStickers { ProgressView(preparing ? "正在读取原图…" : "正在刷新…").font(.footnote) }
                HStack(spacing: 12) {
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                        Label("从照片添加", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Button { showFiles = true } label: {
                        Label("从文件添加", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }.font(.subheadline).buttonStyle(.bordered).padding(.horizontal).padding(.bottom, 12)
                    .disabled(preparing || store.previewMode || !store.canSendMessages)
            }
            .background(CoveStyle.background)
            .navigationTitle("表情包").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.frame(minHeight: 44) } }
            .task { await store.reloadStickers() }
            .onChange(of: photo) { _, selected in
                guard let selected else { return }
                preparing = true; failure = nil
                Task {
                    defer { preparing = false; photo = nil }
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self) else { throw CoveStickerError.unsupported }
                        let type = selected.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                        let file = CoveOutgoingFile(data: data, filename: "表情包.\(type?.preferredFilenameExtension ?? "png")", mime: type?.preferredMIMEType ?? "image/png")
                        imported = CoveStickerImport(file: try await CoveStickerImages.validatedFile(file))
                    } catch { failure = error.localizedDescription }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.png, .jpeg, .gif, .webP], allowsMultipleSelection: false) { result in
                preparing = true; failure = nil
                Task {
                    defer { preparing = false }
                    do {
                        let files = try await CoveAttachmentFiles.readSelected(result.get())
                        guard let file = files.first else { return }
                        imported = CoveStickerImport(file: try await CoveStickerImages.validatedFile(file))
                    } catch { failure = error.localizedDescription }
                }
            }
            .sheet(item: $imported) { item in
                CoveStickerImportSheet(file: item.file) { owner = "user" }
            }
        }.tint(CoveStyle.accent)
    }
}

private struct CoveStickerImportSheet: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    let file: CoveOutgoingFile
    var onSaved: () -> Void
    @State private var name = ""
    @State private var image: UIImage?
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 160) }
                    TextField("表情包名字", text: $name).accessibilityIdentifier("stickers.import.name")
                } footer: { Text("原图保留，GIF 不会变成静态图片。添加到「我的」之后，点表情包即可发送。") }
                if let failure { Section { Text(failure).foregroundStyle(CoveStyle.error) } }
            }.navigationTitle("添加表情包").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving).frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            saving = true; failure = nil
                            Task {
                                defer { saving = false }
                                do { try await store.importSticker(file: file, name: name); onSaved(); dismiss() }
                                catch { failure = error.localizedDescription }
                            }
                        } label: { if saving { ProgressView() } else { Text("添加") } }
                            .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .frame(minHeight: 44).accessibilityIdentifier("stickers.import.save")
                    }
                }
                .task {
                    name = String((file.filename as NSString).deletingPathExtension.prefix(120))
                    image = try? await CoveStickerImages.decode(file.data, animate: false)
                }
        }.interactiveDismissDisabled(saving).tint(CoveStyle.accent)
    }
}

struct CoveSaveStickerSheet: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    let attachment: ChatAttachment
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CoveStickerView(attachment: attachment).frame(maxWidth: .infinity)
                    TextField("表情包名字", text: $name)
                } footer: { Text("保存到「我的」表情包；重复保存不会生成两份。助手 可以另外保存到他自己的库。") }
                if let failure { Section { Text(failure).foregroundStyle(CoveStyle.error) } }
            }.navigationTitle("保存表情包").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving).frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            saving = true; failure = nil
                            Task {
                                defer { saving = false }
                                do { try await store.saveSticker(attachment: attachment, name: name); dismiss() }
                                catch { failure = error.localizedDescription }
                            }
                        } label: { if saving { ProgressView() } else { Text("保存") } }
                            .disabled(saving || store.previewMode || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
                    }
                }.onAppear { name = String((attachment.filename as NSString).deletingPathExtension.prefix(120)) }
        }.interactiveDismissDisabled(saving).tint(CoveStyle.accent)
    }
}
