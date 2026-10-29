import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum CoveAttachmentChoice: Identifiable {
    case prepared(UUID, CoveOutgoingFile)

    var id: String {
        switch self {
        case .prepared(let id, _): return id.uuidString
        }
    }
    var file: CoveOutgoingFile? {
        if case .prepared(_, let file) = self { return file }
        return nil
    }

}

/// One draft survives native photo/document browser round-trips. Only Send hands
/// bytes to the durable outbox; selecting, switching tabs do not.
@MainActor
final class CoveAttachmentComposer: ObservableObject {
    @Published var category = "photos"
    @Published var caption = ""
    @Published var choices: [CoveAttachmentChoice] = []
    @Published var failure: String?
    @Published var preparing = false
    private(set) var conversationID = ""
    private(set) var generation = UUID()
    var work: Task<Void, Never>?

    func reset(conversationID: String, caption: String) {
        cancel()
        self.conversationID = conversationID; self.caption = caption
        choices = []; failure = nil; category = "photos"
    }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; preparing = false
    }
    func add(_ files: [CoveOutgoingFile]) throws {
        guard choices.count + files.count <= 10 else { throw CoveAttachmentError.tooMany }
        choices += files.map { .prepared(UUID(), $0) }
    }

    /// Providers grant access to selected bytes only; no PHAsset lookup or library
    /// permission is needed. Stage the entire batch so a failure never silently
    /// drops one of the selected photos. Injected loaders keep tests synthetic.
    func importPhotos(_ loaders: [() async throws -> Data?]) {
        guard !preparing, !loaders.isEmpty else { return }
        guard choices.count + loaders.count <= 10 else {
            failure = CoveAttachmentError.tooMany.localizedDescription
            return
        }
        failure = nil
        preparing = true
        let generation = generation
        let firstOrdinal = choices.count + 1
        work = Task {
            defer { if generation == self.generation { self.preparing = false; self.work = nil } }
            do {
                var photos: [CoveOutgoingFile] = []
                for (index, load) in loaders.enumerated() {
                    try Task.checkCancellation()
                    guard let data = try await load(), !data.isEmpty else { throw CoveAttachmentError.unreadable }
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    photos.append(try await CoveAttachmentFiles.preparePhoto(data, ordinal: firstOrdinal + index))
                }
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                try self.add(photos)
            } catch is CancellationError { }
            catch {
                if generation == self.generation {
                    self.failure = "照片未添加：\(error.localizedDescription) 若原图在 iCloud，请稍后重选。已选附件和附言已保留。"
                }
            }
        }
    }
    func files() async throws -> [CoveOutgoingFile] {
        let selection = choices
        guard !selection.isEmpty else { throw CoveAttachmentError.empty }
        var files: [CoveOutgoingFile] = []
        for item in selection {
            try Task.checkCancellation()
            switch item {
            case .prepared(_, let file): files.append(file)
            }
        }
        try Task.checkCancellation()
        return files
    }
}

/// The sheet reviews selected attachments; browsing uses the same native
/// PhotosPicker API as CCC, including the system's album navigation.
struct CoveAttachmentPicker: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CoveAttachmentComposer
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photosPresented = false
    @State private var detent: PresentationDetent = .fraction(0.66)
    @FocusState private var captionFocused: Bool
    var onBrowseFiles: () -> Void
    var onSend: ([CoveOutgoingFile], String, String) async -> Bool

    init(model: CoveAttachmentComposer, onBrowseFiles: @escaping () -> Void,
         onSend: @escaping ([CoveOutgoingFile], String, String) async -> Bool) {
        self.model = model
        self.onBrowseFiles = onBrowseFiles; self.onSend = onSend
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure = model.failure {
                Text(failure).font(.footnote).foregroundStyle(CoveStyle.error)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if model.category == "photos" { photoContent }
            else { fileContent }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CoveStyle.background)
        .tint(CoveStyle.teal)
        .presentationDetents([.fraction(0.66), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(CoveStyle.background)
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled(model.preparing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachments.panel")
        .photosPicker(isPresented: $photosPresented, selection: $photoItems,
                      maxSelectionCount: max(1, 10 - model.choices.count),
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !store.previewMode, !items.isEmpty else { return }
            photoItems = []
            model.importPhotos(items.map { item in
                { try await item.loadTransferable(type: Data.self) }
            })
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.cancel(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 21, weight: .medium))
                    .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("关闭附件")
                .accessibilityIdentifier("attachments.close")
            Spacer(minLength: 8)
            Text(model.category == "photos" ? "照片" : "文件")
                .font(.headline).accessibilityIdentifier("attachments.title")
            Spacer(minLength: 8)
            Text(model.choices.isEmpty ? "" : "\(model.choices.count)/10")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("attachments.header")
    }

    private var photoContent: some View {
        GeometryReader { geometry in
            let side = max(1, (geometry.size.width - 4) / 3)
            ScrollView {
                if store.previewMode {
                    Text("界面预览 · 不读取或上传相册").font(.caption).padding(.vertical, 6)
                }
                Button { browsePhotos() } label: {
                    HStack {
                        Label("选择照片", systemImage: "photo.on.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote)
                    }.frame(minHeight: 48).padding(.horizontal, 16)
                }.disabled(store.previewMode || model.preparing || model.choices.count >= 10)
                    .accessibilityHint("打开系统照片选择器，按收藏或相册查找")
                    .accessibilityIdentifier("attachments.browsePhotos")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(model.choices.filter { $0.file?.mime.hasPrefix("image/") == true }) { item in
                        if let file = item.file {
                            Button { model.choices.removeAll { $0.id == item.id } } label: {
                                CovePreparedPhotoThumbnail(data: file.data)
                                    .frame(width: side, height: side).clipped()
                                    .overlay(alignment: .topTrailing) { selectionBadge(item.id) }
                            }.buttonStyle(.plain).disabled(model.preparing)
                                .accessibilityLabel("移除 \(file.filename)")
                        }
                    }
                    if store.previewMode {
                        ForEach(0..<11) { index in
                            Rectangle().fill(CoveStyle.teal.opacity(Double(index % 3 + 1) * 0.08))
                                .frame(width: side, height: side)
                                .overlay { Image(systemName: "photo").font(.title).foregroundStyle(CoveStyle.secondaryText) }
                                .accessibilityIdentifier("attachments.previewPhoto.\(index)")
                        }
                    }
                }
                if !store.previewMode, model.choices.isEmpty {
                    Text("从系统相册选择照片。")
                        .font(.subheadline).foregroundStyle(CoveStyle.secondaryText).padding(20)
                }
            }.scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("attachments.photoGrid")
        }
    }

    private func selectionBadge(_ id: String) -> some View {
        let index = model.choices.firstIndex { $0.id == id }
        return ZStack {
            Circle().fill(index == nil ? Color.black.opacity(0.18) : CoveStyle.teal)
            Circle().strokeBorder(.white, lineWidth: 2)
            if let index { Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white) }
        }.frame(width: 27, height: 27).padding(6)
    }

    private var fileContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if store.previewMode {
                    Text("界面预览 · 不读取文件").font(.caption).padding()
                }
                Button { browseFiles() } label: {
                    Label("添加文件 · iCloud Drive / 本机", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                }.disabled(store.previewMode || model.preparing).accessibilityIdentifier("attachments.browseFiles")
                ForEach(model.choices) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.file?.mime.hasPrefix("image/") == true || item.file == nil ? "photo" : "doc.fill")
                            .font(.title2).foregroundStyle(CoveStyle.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.file?.filename ?? "已选择的照片").lineLimit(2)
                            if let file = item.file {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                            }
                        }
                        Spacer()
                        Button { model.choices.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "checkmark.circle.fill").frame(width: 44, height: 44)
                        }.disabled(model.preparing).accessibilityLabel("移除 \(item.file?.filename ?? "照片")")
                    }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                    Divider().padding(.leading, 16)
                }
            }
        }.accessibilityIdentifier("attachments.fileList")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if model.preparing {
                Text("正在准备附件 · 点左上角 × 可取消")
                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            }
            if !model.choices.isEmpty || model.preparing {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("添加说明…", text: $model.caption, axis: .vertical)
                        .lineLimit(1...4).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .focused($captionFocused).disabled(model.preparing)
                        .accessibilityIdentifier("attachments.caption")
                    Button { send() } label: {
                        Group {
                            if model.preparing { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.up").font(.title3.weight(.semibold)) }
                        }.frame(width: 46, height: 46).foregroundStyle(.white)
                            .background(CoveStyle.teal, in: Circle())
                            .overlay(alignment: .topTrailing) {
                                if !model.preparing {
                                    Text("\(model.choices.count)").font(.caption2.bold()).foregroundStyle(CoveStyle.teal)
                                        .padding(3).background(.background, in: Circle())
                                }
                            }
                    }.disabled(model.preparing || store.previewMode || !store.canSendMessages)
                        .accessibilityLabel("发送 \(model.choices.count) 个附件")
                        .accessibilityIdentifier("attachments.confirmSend")
                }.padding(.horizontal, 12)
            }
            HStack(spacing: 4) {
                categoryButton("photos", title: "相册", symbol: "photo.on.rectangle")
                categoryButton("files", title: "文件", symbol: "doc.fill")
            }.padding(5).background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(CoveStyle.border.opacity(0.5), lineWidth: 0.5) }
                .padding(.horizontal, 16)
        }.padding(.top, 8).padding(.bottom, 8)
    }

    private func categoryButton(_ id: String, title: String, symbol: String) -> some View {
        Button {
            captionFocused = false
            model.category = id
            // Files is an action, not an intermediate "choose type / browse" page.
            let hasDocuments = model.choices.contains { $0.file?.mime.hasPrefix("image/") == false }
            if id == "photos" { browsePhotos() }
            if id == "files", !store.previewMode, !hasDocuments { browseFiles() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 23, weight: .medium))
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(model.category == id ? CoveStyle.teal : CoveStyle.secondaryText)
                .background { if model.category == id { Capsule().fill(CoveStyle.teal.opacity(0.12)) } }
        }.buttonStyle(.plain).disabled(model.preparing)
            .accessibilityIdentifier("attachments.\(id)")
            .accessibilityAddTraits(model.category == id ? .isSelected : [])
    }

    private func browseFiles() { onBrowseFiles(); dismiss() }
    private func browsePhotos() {
        guard !store.previewMode, !model.preparing else { return }
        guard model.choices.count < 10 else { model.failure = CoveAttachmentError.tooMany.localizedDescription; return }
        captionFocused = false
        photosPresented = true
    }
    private func send() {
        guard !model.preparing, !model.choices.isEmpty else { return }
        captionFocused = false; model.failure = nil; model.preparing = true
        let generation = model.generation
        model.work = Task {
            defer { if generation == model.generation { model.preparing = false } }
            do {
                let files = try await model.files()
                guard generation == model.generation else { return }
                if await onSend(files, model.caption, model.conversationID) { dismiss() }
                else { model.failure = store.errorMessage ?? "附件没有加入发件箱，请重试。" }
            } catch is CancellationError { }
            catch { if generation == model.generation { model.failure = error.localizedDescription } }
        }
    }
}

private struct CovePreparedPhotoThumbnail: View {
    let data: Data
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }.task {
            let decoded = try? await CoveStickerImages.decode(data, animate: false)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

/// This controller IS the initial sheet, not a second presentation from an empty
/// attachment panel. PHPicker grants access only to explicitly selected items.
struct CoveSystemPhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onFinish: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([PHPickerResult]) -> Void
        init(onFinish: @escaping ([PHPickerResult]) -> Void) { self.onFinish = onFinish }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onFinish(results)
        }
    }

    static func loadPhoto(_ result: PHPickerResult) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data) }
            }
        }
    }
}
