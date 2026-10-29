import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

enum CoveWallpaperChoice: String, CaseIterable, Identifiable {
    case blush, cream, rose, gradient, photo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blush: "浅粉"
        case .cream: "奶油"
        case .rose: "玫瑰"
        case .gradient: "柔光"
        case .photo: "我的照片"
        }
    }
}

@MainActor
final class CoveWallpaperStore: ObservableObject {
    static let shared = CoveWallpaperStore()
    @Published private(set) var selection: CoveWallpaperChoice
    @Published private(set) var photo: UIImage?
    @Published private(set) var brightness: Double
    @Published private(set) var hasPhoto: Bool
    @Published private(set) var isWorking = false
    @Published var error: String?
    private let defaults: UserDefaults
    let photoURL: URL
    private static let preferenceKey = "cove.wallpaper.choice"
    private static let brightnessKey = "cove.wallpaper.brightness"

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        brightness = min(0.3, max(-0.3, defaults.double(forKey: Self.brightnessKey)))
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CoveAppearance", isDirectory: true)
        photoURL = directory.appendingPathComponent("wallpaper.jpg")
        let photoExists = FileManager.default.fileExists(atPath: photoURL.path)
        hasPhoto = photoExists
        let saved = CoveWallpaperChoice(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .blush
        selection = saved == .photo && !photoExists ? .blush : saved
    }

    func select(_ choice: CoveWallpaperChoice) {
        guard choice != .photo || hasPhoto else { return }
        selection = choice
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
    }

    func loadPhotoIfNeeded() async {
        guard hasPhoto, photo == nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { photo = try await CoveWallpaperFiles.read(photoURL) }
        catch {
            self.error = "照片壁纸暂时无法读取，请重新选择。"
            if selection == .photo { select(.blush) }
        }
    }

    // Called only by the preview's Apply button. Choosing or cancelling a draft
    // never mutates the current wallpaper or its persisted preferences.
    func apply(_ choice: CoveWallpaperChoice, brightness: Double, photoData: Data? = nil, removeSavedPhoto: Bool = false) async throws {
        guard !isWorking else { throw CoveWallpaperFiles.WallpaperError.busy }
        isWorking = true
        defer { isWorking = false }
        if choice == .photo, photoData == nil, !hasPhoto { throw CoveWallpaperFiles.WallpaperError.unreadable }
        if let photoData {
            photo = try await CoveWallpaperFiles.persist(photoData, at: photoURL)
            hasPhoto = true
        } else if removeSavedPhoto {
            let url = photoURL
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }.value
            photo = nil
            hasPhoto = false
        }
        self.brightness = min(0.3, max(-0.3, brightness))
        defaults.set(self.brightness, forKey: Self.brightnessKey)
        error = nil
        select(choice)
    }

}

enum CoveWallpaperFiles {
    static let maximumPixelSize = 2_048
    static let maximumInputBytes = 20 * 1024 * 1024

    static func persist(_ data: Data, at url: URL) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard !data.isEmpty, data.count <= maximumInputBytes else { throw WallpaperError.tooLarge }
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw WallpaperError.unreadable }
                let image = try thumbnail(source)
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { throw WallpaperError.unreadable }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw WallpaperError.unreadable }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Commit only after decoding/encoding succeeds; a bad new image
                // must never overwrite the previous wallpaper.
                try (encoded as Data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var resources = URLResourceValues()
                resources.isExcludedFromBackup = true
                var savedURL = url
                try? savedURL.setResourceValues(resources)
                return UIImage(cgImage: image)
            }
        }.value
    }

    static func preview(_ data: Data) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard !data.isEmpty, data.count <= maximumInputBytes else { throw WallpaperError.tooLarge }
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw WallpaperError.unreadable }
                return UIImage(cgImage: try thumbnail(source))
            }
        }.value
    }

    static func read(_ url: URL) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw WallpaperError.unreadable }
                return UIImage(cgImage: try thumbnail(source))
            }
        }.value
    }

    private static func thumbnail(_ source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 32_768, height <= 32_768, width * height <= 120_000_000 else { throw WallpaperError.tooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= maximumPixelSize, image.height <= maximumPixelSize else { throw WallpaperError.unreadable }
        return image
    }

    enum WallpaperError: LocalizedError {
        case tooLarge, unreadable, busy
        var errorDescription: String? {
            switch self {
            case .tooLarge: "这张照片太大了，请选择 20 MiB 以内的普通照片。"
            case .unreadable: "这张照片暂时无法读取，请重新选择。"
            case .busy: "正在准备照片，请稍后再试。"
            }
        }
    }
}

private struct CoveWallpaperFrameKey: EnvironmentKey {
    static let defaultValue = CGRect.zero
}

extension EnvironmentValues {
    var coveWallpaperFrame: CGRect {
        get { self[CoveWallpaperFrameKey.self] }
        set { self[CoveWallpaperFrameKey.self] = newValue }
    }
}

struct CoveChatWallpaperView: View {
    @ObservedObject private var wallpaper = CoveWallpaperStore.shared
    @Environment(\.coveWallpaperFrame) private var canvas
    var body: some View {
        GeometryReader { geometry in
            let local = geometry.frame(in: .global)
            let bounds = canvas.isEmpty ? local : canvas
            CoveWallpaperSurface(choice: wallpaper.selection, image: wallpaper.photo, brightness: wallpaper.brightness)
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX - local.minX, y: bounds.minY - local.minY)
        }
            .clipped()
            .allowsHitTesting(false).accessibilityHidden(true)
            .task { await wallpaper.loadPhotoIfNeeded() }
    }
}

enum CoveLivingWallpaperScene {
    case home
    case pulse
}

/// A quieter treatment of the selected chat wallpaper for Cove's living spaces.
/// It shares the same persisted choice/photo/brightness, while adding a static
/// readability veil instead of an expensive live blur.
struct CoveLivingWallpaperView: View {
    @ObservedObject private var wallpaper = CoveWallpaperStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let scene: CoveLivingWallpaperScene

    init(scene: CoveLivingWallpaperScene = .home) {
        self.scene = scene
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CoveWallpaperSurface(
                    choice: wallpaper.selection,
                    image: wallpaper.photo,
                    brightness: wallpaper.brightness
                )
                .frame(width: geometry.size.width, height: geometry.size.height)

                if reduceTransparency || contrast == .increased {
                    accessibleBackdrop
                } else {
                    readabilityVeil
                    pearlLight
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await wallpaper.loadPhotoIfNeeded() }
    }

    private var readabilityVeil: some View {
        LinearGradient(
            colors: veilColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var pearlLight: some View {
        ZStack {
            RadialGradient(
                colors: [iceHighlight, .clear],
                center: scene == .home ? .topTrailing : .topLeading,
                startRadius: 8,
                endRadius: 430
            )
            RadialGradient(
                colors: [roseHighlight, .clear],
                center: scene == .home ? .bottomLeading : .bottomTrailing,
                startRadius: 10,
                endRadius: 520
            )
        }
    }

    /// Accessibility modes deliberately trade the photo texture for a fully
    /// opaque pearl-colored field, so text never depends on transparency.
    private var accessibleBackdrop: some View {
        LinearGradient(
            colors: accessibleColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var veilColors: [Color] {
        switch (scene, scheme) {
        case (.home, .light):
            [Color(red: 1.00, green: 0.98, blue: 0.98).opacity(0.12),
             Color(red: 0.96, green: 0.98, blue: 1.00).opacity(0.16),
             Color(red: 1.00, green: 0.96, blue: 0.98).opacity(0.14)]
        case (.pulse, .light):
            [Color(red: 0.95, green: 0.98, blue: 1.00).opacity(0.10),
             Color(red: 0.98, green: 0.96, blue: 1.00).opacity(0.12),
             Color(red: 1.00, green: 0.97, blue: 0.99).opacity(0.14)]
        case (.home, .dark):
            [Color(red: 0.12, green: 0.10, blue: 0.14).opacity(0.64),
             Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.60),
             Color(red: 0.17, green: 0.11, blue: 0.15).opacity(0.66)]
        case (.pulse, .dark):
            [Color(red: 0.09, green: 0.13, blue: 0.18).opacity(0.62),
             Color(red: 0.15, green: 0.12, blue: 0.20).opacity(0.64),
             Color(red: 0.16, green: 0.11, blue: 0.16).opacity(0.66)]
        default:
            [CoveStyle.background.opacity(0.14), CoveStyle.background.opacity(0.10)]
        }
    }

    private var accessibleColors: [Color] {
        switch (scene, scheme) {
        case (.home, .light):
            [Color(red: 1.00, green: 0.98, blue: 0.99),
             Color(red: 0.96, green: 0.98, blue: 1.00),
             Color(red: 1.00, green: 0.96, blue: 0.98)]
        case (.pulse, .light):
            [Color(red: 0.95, green: 0.98, blue: 1.00),
             Color(red: 0.98, green: 0.96, blue: 1.00),
             Color(red: 1.00, green: 0.97, blue: 0.99)]
        case (.home, .dark):
            [Color(red: 0.13, green: 0.10, blue: 0.14),
             Color(red: 0.11, green: 0.14, blue: 0.18),
             Color(red: 0.17, green: 0.11, blue: 0.15)]
        case (.pulse, .dark):
            [Color(red: 0.09, green: 0.13, blue: 0.18),
             Color(red: 0.15, green: 0.12, blue: 0.20),
             Color(red: 0.16, green: 0.11, blue: 0.16)]
        default:
            [CoveStyle.background, CoveStyle.card]
        }
    }

    private var iceHighlight: Color {
        Color(red: 0.67, green: 0.84, blue: 1.00)
            .opacity(scheme == .dark ? 0.06 : 0.05)
    }

    private var roseHighlight: Color {
        Color(red: 1.00, green: 0.70, blue: 0.84)
            .opacity(scheme == .dark ? 0.05 : 0.04)
    }
}

private struct CoveWallpaperSurface: View {
    @Environment(\.colorScheme) private var scheme
    let choice: CoveWallpaperChoice
    var image: UIImage?
    var brightness: Double = 0
    var body: some View {
        GeometryReader { geometry in
            Group {
                switch choice {
                case .blush: CoveStyle.chatBackground
                case .cream: CoveStyle.adaptive(0xFFF5ED, 0x2A211F)
                case .rose: CoveStyle.adaptive(0xF8E0E9, 0x35212D)
                case .gradient:
                    LinearGradient(colors: [CoveStyle.adaptive(0xFFE6F0, 0x392335), CoveStyle.adaptive(0xFFF4EB, 0x292023), CoveStyle.adaptive(0xF5E5F0, 0x302332)], startPoint: .topLeading, endPoint: .bottomTrailing)
                case .photo:
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            .brightness(brightness)
                            .overlay(CoveStyle.chatBackground.opacity(0.08))
                            // Display-only veil: preserve the saved photo and the
                            // user's brightness setting; previews share this surface.
                            .overlay(Color.black.opacity(scheme == .dark ? 0.38 : 0))
                    } else { CoveStyle.chatBackground }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct CoveWallpaperSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wallpaper = CoveWallpaperStore.shared
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isReading = false
    @State private var photoError: String?
    @State private var draftChoice: CoveWallpaperChoice = .blush
    @State private var draftBrightness = 0.0
    @State private var draftPhotoData: Data?
    @State private var draftPhoto: UIImage?
    @State private var removeSavedPhoto = false
    @State private var initialized = false
    private var previewImage: UIImage? { draftPhoto ?? (removeSavedPhoto ? nil : wallpaper.photo) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack {
                    CoveWallpaperSurface(choice: draftChoice, image: previewImage, brightness: draftBrightness)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("把日常留在 Cove。").padding(12).background(CoveStyle.incoming, in: RoundedRectangle(cornerRadius: 16))
                        HStack {
                            Spacer()
                            Text("这里是我们的小天地。").padding(12).background(CoveStyle.outgoing(scheme == .dark), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }.font(.subheadline).foregroundStyle(CoveStyle.text).padding(20)
                }.frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("wallpaper.preview")
                Text("先看看效果，喜欢再应用。").font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 14) {
                    ForEach(CoveWallpaperChoice.allCases.filter { $0 != .photo || previewImage != nil }) { choice in
                        Button { draftChoice = choice } label: {
                            VStack(spacing: 8) {
                                CoveWallpaperSurface(choice: choice, image: previewImage, brightness: draftBrightness).frame(height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(draftChoice == choice ? CoveStyle.accentText : CoveStyle.border, lineWidth: draftChoice == choice ? 2 : 1))
                                HStack(spacing: 4) {
                                    Text(choice.title)
                                    if draftChoice == choice { Image(systemName: "checkmark.circle.fill") }
                                }.font(.caption).foregroundStyle(CoveStyle.accentText)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(isReading || wallpaper.isWorking)
                            .accessibilityLabel(choice.title).accessibilityAddTraits(draftChoice == choice ? .isSelected : [])
                            .accessibilityIdentifier("wallpaper.choice.\(choice.rawValue)")
                    }
                }
                if draftChoice == .photo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("照片明暗").font(.subheadline).foregroundStyle(CoveStyle.text)
                        Slider(value: $draftBrightness, in: -0.3...0.3) { Text("照片明暗") }
                            .tint(CoveStyle.accentText).accessibilityIdentifier("wallpaper.brightness")
                        HStack { Text("调暗"); Spacer(); Text("调亮") }.font(.caption).foregroundStyle(CoveStyle.secondaryText)
                        Text("照片会居中铺满聊天区域，边缘可能裁切。").font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("从照片选择壁纸", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).tint(CoveStyle.accentText).disabled(isReading || wallpaper.isWorking)
                        .accessibilityIdentifier("wallpaper.photos")
                    if isReading || wallpaper.isWorking { ProgressView("正在准备壁纸…").tint(CoveStyle.accentText) }
                    if (wallpaper.hasPhoto || draftPhoto != nil) && !removeSavedPhoto {
                        Button("移除照片，恢复浅粉", role: .destructive) {
                            draftPhoto = nil; draftPhotoData = nil; removeSavedPhoto = true; draftChoice = .blush
                        }.frame(minHeight: 44).disabled(isReading || wallpaper.isWorking).accessibilityIdentifier("wallpaper.remove")
                    }
                    Text("壁纸只保存在这台设备上，不会发送或上传。")
                        .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    if let error = photoError ?? wallpaper.error { Text(error).font(.footnote).foregroundStyle(CoveStyle.error) }
                }
            }.padding(20).frame(maxWidth: 680)
        }.frame(maxWidth: .infinity).background(CoveStyle.background)
            .navigationTitle("聊天壁纸").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("wallpaper.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        Task {
                            do {
                                try await wallpaper.apply(draftChoice, brightness: draftBrightness, photoData: draftPhotoData, removeSavedPhoto: removeSavedPhoto)
                                dismiss()
                            } catch { photoError = error.localizedDescription }
                        }
                    }.disabled(isReading || wallpaper.isWorking).accessibilityIdentifier("wallpaper.apply")
                }
            }
            .onAppear {
                if !initialized { draftChoice = wallpaper.selection; draftBrightness = wallpaper.brightness; initialized = true }
            }
            .task { await wallpaper.loadPhotoIfNeeded() }
            .onChange(of: selectedPhoto) {
                guard let selectedPhoto else { return }
                Task {
                    isReading = true
                    photoError = nil
                    defer { isReading = false; self.selectedPhoto = nil }
                    do {
                        guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else { throw CoveWallpaperFiles.WallpaperError.unreadable }
                        let image = try await CoveWallpaperFiles.preview(data)
                        draftPhotoData = data; draftPhoto = image; draftChoice = .photo; removeSavedPhoto = false
                    } catch { photoError = error.localizedDescription }
                }
            }
    }
}
