import SwiftUI
import UIKit
import ImageIO

@MainActor
final class CoveTravelAlbumModel: ObservableObject {
    @Published private(set) var album: CoveTravelAlbum?
    @Published private(set) var loading = false
    @Published private(set) var settingCover = false
    @Published private(set) var error: String?
    @Published private(set) var coverUnconfirmed = false
    private var epoch = UUID()
    private var readID = UUID()
    private var scope = ""
    private var dataScope = ""
    private var coverIDs: [String: String] = [:]
    private var pendingCoverID: String?

    func reset(scope: String, dataScope: String) {
        guard self.scope != scope || self.dataScope != dataScope else { return }
        if self.dataScope != dataScope {
            // Uncertainty belongs to one server/conversation/journey, not the next album.
            pendingCoverID = nil; coverUnconfirmed = false; coverIDs.removeAll()
            self.dataScope = dataScope
        }
        self.scope = scope; epoch = UUID(); readID = UUID()
        album = nil; loading = false; settingCover = false; error = nil
        // An interrupted cover write remains uncertain. Only a read verifies it.
    }
    func load(store: CoveStore, journey: CoveTravelJourney, more: Bool = false) async {
        guard !loading, !settingCover, store.isConnected, !store.previewMode,
              store.activeConversationID == journey.conversationID else { return }
        let stamp = epoch, token = UUID(), cursor = more ? (album?.nextCursor ?? 0) : 0
        if more && album?.hasMore != true { return }
        readID = token; loading = true
        defer { if stamp == epoch, token == readID { loading = false } }
        do {
            let page = try await store.travelAlbum(conversation: journey.conversationID, journeyID: journey.id, after: cursor)
            guard stamp == epoch, token == readID, !Task.isCancelled else { return }
            guard page.scenes.allSatisfy({ $0.journeyID == journey.id }), page.photos.allSatisfy({ $0.journeyID == journey.id }) else {
                throw CoveError.message("旅程内容不匹配，未显示。")
            }
            if let old = album?.revision, let next = page.revision, next < old { return }
            if let old = album?.albumRevision, let next = page.albumRevision, next < old { return }
            if more, let old = album {
                guard let combined = old.merging(page) else { throw CoveError.message("时间线分页未推进，请刷新后再试。") }
                album = combined
            } else { album = page }
            if let pendingCoverID, page.journey.coverPhoto?.id == pendingCoverID {
                self.pendingCoverID = nil; coverUnconfirmed = false
            }
            error = coverUnconfirmed ? "封面结果尚未确认。可以下拉核对，不会自动重复设置。" : nil
        } catch is CancellationError { }
        catch { if stamp == epoch, token == readID { self.error = error.localizedDescription } }
    }
    func setCover(_ photo: CoveTravelPhoto, store: CoveStore, travel: CoveTravelModel) async {
        guard let album, album.journey.id == photo.journeyID, album.photos.contains(where: { $0.id == photo.id }),
              !settingCover, !coverUnconfirmed, store.isConnected, store.activeConversationID == album.journey.conversationID else { return }
        let stamp = epoch, journey = album.journey
        let key = journey.id + ":" + photo.id
        let id = coverIDs[key] ?? UUID().uuidString
        coverIDs[key] = id; pendingCoverID = photo.id
        settingCover = true; coverUnconfirmed = true; error = nil
        readID = UUID(); loading = false
        do {
            let snapshot = try await store.travelAlbumCover(conversation: journey.conversationID, journeyID: journey.id, photoID: photo.id, requestID: id)
            guard stamp == epoch, !Task.isCancelled else { return }
            travel.receiveAlbumSnapshot(snapshot, conversation: journey.conversationID)
            if ([snapshot.journey].compactMap { $0 } + snapshot.archives).first(where: { $0.id == journey.id })?.coverPhoto?.id == photo.id {
                coverUnconfirmed = false; pendingCoverID = nil; coverIDs.removeValue(forKey: key)
            }
        } catch { if stamp == epoch { self.error = "封面设置结果未确认，正在只读核对。" } }
        guard stamp == epoch, !Task.isCancelled else { return }
        settingCover = false
        // Both success and failure read back; no automatic POST replay.
        await load(store: store, journey: journey)
        await travel.refresh(store: store)
    }
}

/// Static vector paper fibres: no image download, animation, or random redraw.
private struct CoveTravelPaper: View {
    @Environment(\.colorScheme) private var scheme
    private var paper: Color {
        scheme == .dark ? Color(red: 0.20, green: 0.185, blue: 0.17) : Color(red: 0.975, green: 0.952, blue: 0.905)
    }
    var body: some View {
        paper.overlay {
            Canvas { context, size in
                var fibres = Path()
                var flecks = Path()
                let count = min(1800, Int(size.width * size.height / 100))
                guard size.width > 0, size.height > 0 else { return }
                for i in 0..<count {
                    let x = CGFloat((i * 73 + 19) % 997) / 997 * size.width
                    let y = CGFloat((i * 137 + 43) % 991) / 991 * size.height
                    fibres.move(to: CGPoint(x: x, y: y))
                    fibres.addLine(to: CGPoint(x: x + CGFloat(i % 4 + 1) * 0.55, y: y + 0.35))
                    if i % 3 == 0 { flecks.addEllipse(in: CGRect(x: x, y: y, width: 0.7, height: 0.7)) }
                }
                context.stroke(fibres, with: .color(scheme == .dark ? .white.opacity(0.07) : .brown.opacity(0.10)), lineWidth: 0.45)
                context.fill(flecks, with: .color(scheme == .dark ? .black.opacity(0.17) : .brown.opacity(0.09)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Shared paper-like cover for the home entry and journey archive.
struct CoveTravelPostcard: View {
    let journey: CoveTravelJourney
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let photo = journey.coverPhoto {
                    CoveTravelPhotoImage(photo: photo, conversationID: journey.conversationID, thumbnail: true)
                        .frame(height: 190).clipped()
                } else {
                    CoveTravelPaper()
                        .overlay(Color.brown.opacity(scheme == .dark ? 0.10 : 0.035))
                    Image(systemName: "globe.europe.africa")
                        .font(.system(size: 150, weight: .ultraLight))
                        .foregroundStyle(CoveStyle.secondaryText.opacity(0.13))
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 22)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("沿途，慢慢收藏").font(.system(.title3, design: .serif, weight: .medium))
                        Text("留一处空白，给我们的第一张照片")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(22)
                }
            }.frame(height: 190).clipped()
                .overlay(Rectangle().strokeBorder(.black.opacity(scheme == .dark ? 0.20 : 0.07), lineWidth: 0.5))
                .padding([.top, .horizontal], 10)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(journey.destination).font(.system(.title3, design: .serif, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(journey.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "location.north.line")
                        .font(.title3.weight(.light)).foregroundStyle(CoveStyle.accentText)
                        .frame(width: 42, height: 48)
                        .overlay(Rectangle().strokeBorder(CoveStyle.secondaryText.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .rotationEffect(.degrees(7)).accessibilityHidden(true)
                }
                Rectangle().fill(CoveStyle.secondaryText.opacity(0.16)).frame(height: 0.5)
                HStack {
                    Text(String(journey.startedAt.prefix(10))).monospacedDigit()
                    Spacer()
                    Text("\(journey.photoCount ?? 0) 张影像")
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .background { CoveTravelPaper() }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.white.opacity(scheme == .dark ? 0.10 : 0.75), lineWidth: 0.7)
                .padding(0.5).allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: 3)
                .fill(scheme == .dark ? Color(white: 0.22) : Color(red: 0.85, green: 0.82, blue: 0.76))
                .offset(y: 1.5)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.12), radius: 1, x: 0, y: 2)
        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: 9, x: 0, y: 6)
        .accessibilityElement(children: .combine)
    }
}

struct CoveTravelAlbumDetail: View {
    let initialJourney: CoveTravelJourney
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var travel: CoveTravelModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CoveTravelAlbumModel()
    @State private var selectedPhoto: CoveTravelPhoto?
    @State private var confirmsEnd = false
    private var scope: String { "\(store.appActivityScopeID)|\(store.activeConversationID)|\(phase)|\(initialJourney.id)" }
    private var journey: CoveTravelJourney {
        // Current status from foreground snapshot takes precedence over old album metadata.
        if let current = travel.snapshot?.journey, current.id == initialJourney.id { return current }
        if let archived = travel.snapshot?.archives.first(where: { $0.id == initialJourney.id }) { return archived }
        return model.album?.journey ?? initialJourney
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(journey.destination).font(.title2.weight(.semibold))
                Text(journey.statusText).font(.subheadline).foregroundStyle(.secondary)
                CoveTravelMap(journey: journey).id(journey.id + journey.updatedAt)
                controls
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if let error = travel.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if model.loading || model.settingCover { ProgressView("正在读取旅程…") }
                Text("旅行影像").font(.headline)
                if let album = model.album {
                    if album.photos.isEmpty {
                        Text("这里还没有照片。可以在对话里请助手生成一张旅行影像，并收入这段旅程。").font(.body).foregroundStyle(.secondary)
                    }
                    ForEach(album.photos) { photo in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { selectedPhoto = photo } label: {
                                CoveTravelPhotoImage(photo: photo, conversationID: journey.conversationID, thumbnail: true).frame(height: 220).clipped()
                            }.buttonStyle(.plain).accessibilityLabel("查看旅行影像：\(photo.caption)")
                            if !photo.caption.isEmpty { Text(photo.caption).font(.body) }
                            Text(photo.sourceLabel).font(.caption).foregroundStyle(.secondary)
                            if journey.coverPhoto?.id == photo.id { Label("明信片封面", systemImage: "checkmark").font(.caption) }
                            else {
                                Button("设为这段旅程的封面") { Task { await model.setCover(photo, store: store, travel: travel) } }
                                    .frame(minHeight: 44).disabled(model.settingCover || model.coverUnconfirmed || !store.isConnected)
                            }
                        }
                    }
                    Divider()
                    Text("一路走过").font(.headline)
                    if album.scenes.isEmpty { Text("尚无已保存的场景。").foregroundStyle(.secondary) }
                    ForEach(album.scenes) { scene in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(scene.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(String(scene.createdAt.prefix(10))).font(.caption).foregroundStyle(.secondary)
                            }
                            if let note = scene.recoveryNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                            Text(scene.text).font(.body).textSelection(.enabled)
                            if let reply = scene.lastReply, !reply.text.isEmpty {
                                Text("你的回应 · \(reply.text)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    if album.hasMore {
                        Button("加载更多场景") { Task { await model.load(store: store, journey: initialJourney, more: true) } }
                            .frame(minHeight: 44).disabled(model.loading || model.settingCover)
                    }
                } else if !model.loading {
                    Button("读取旅程详情") { Task { await model.load(store: store, journey: initialJourney) } }.frame(minHeight: 44)
                }
            }.padding(20).frame(maxWidth: 680)
        }
        .navigationTitle("旅程详情").navigationBarTitleDisplayMode(.inline)
        .task(id: scope) {
            model.reset(scope: scope, dataScope: store.serverURL + "|" + initialJourney.conversationID + "|" + initialJourney.id); selectedPhoto = nil
            guard phase == .active, store.activeConversationID == initialJourney.conversationID else { return }
            await model.load(store: store, journey: initialJourney)
        }
        .refreshable { await model.load(store: store, journey: initialJourney); await travel.refresh(store: store) }
        .sheet(item: $selectedPhoto) { photo in CoveTravelPhotoViewer(photo: photo, conversationID: journey.conversationID) }
        .onChange(of: store.activeConversationID) { _, value in if value != initialJourney.conversationID { selectedPhoto = nil; dismiss() } }
        .confirmationDialog("结束这次旅行？路线、场景与照片会保留。", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("结束旅行", role: .destructive) { Task { await travel.control(journey, action: "end", store: store) } }
        }
    }
    @ViewBuilder private var controls: some View {
        if travel.snapshot?.journey?.id == journey.id {
            VStack(alignment: .leading, spacing: 8) {
                if journey.allowsControl("pause") || journey.allowsControl("resume") {
                    Button(journey.status == "paused" ? "继续同行" : "暂停旅行") {
                        Task { await travel.control(journey, action: journey.status == "paused" ? "resume" : "pause", store: store) }
                    }.frame(minHeight: 44).buttonStyle(.bordered)
                }
                if journey.allowsControl("end") { Button("结束这次旅行", role: .destructive) { confirmsEnd = true }.frame(minHeight: 44) }
            }.disabled(travel.acting || travel.mutationUnconfirmed || !store.isConnected)
        }
    }
}

struct CoveTravelPhotoImage: View {
    let photo: CoveTravelPhoto
    let conversationID: String
    var thumbnail = false
    @EnvironmentObject private var store: CoveStore
    @Environment(\.scenePhase) private var phase
    @State private var image: UIImage?
    @State private var error: String?
    private var scope: String { "\(store.appActivityScopeID)|\(store.activeConversationID)|\(photo.id)|\(phase)" }
    var body: some View {
        Group {
            if let image {
                if thumbnail { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(uiImage: image).resizable().scaledToFit() }
            } else if let error { VStack { Image(systemName: "photo.badge.exclamationmark"); Text(error).font(.caption) }.frame(maxWidth: .infinity) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
        .task(id: scope) {
            image = nil; error = nil
            guard phase == .active, store.isConnected, !store.previewMode, store.activeConversationID == conversationID else { return }
            let expectedScope = scope
            do {
                let bytes = try await store.attachmentData(photo.attachment.url)
                guard !Task.isCancelled, expectedScope == scope else { return }
                if thumbnail {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 900, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw CoveError.message("图片格式无法读取") }
                    image = UIImage(cgImage: cg)
                } else {
                    guard let decoded = UIImage(data: bytes) else { throw CoveError.message("图片格式无法读取") }
                    image = decoded
                }
            } catch { if !Task.isCancelled, expectedScope == scope { self.error = "照片暂未读取，请稍后重开。" } }
        }
    }
}

private struct CoveTravelPhotoViewer: View {
    let photo: CoveTravelPhoto
    let conversationID: String
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var shareImage: UIImage?
    @State private var preparing = false
    @State private var shareError: String?
    @State private var shareEpoch = UUID()
    private var shareScope: String { "\(store.appActivityScopeID)|\(store.activeConversationID)|\(photo.id)|\(phase)" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CoveTravelPhotoImage(photo: photo, conversationID: conversationID)
                    Text(photo.caption).font(.body)
                    Text(photo.sourceLabel).font(.caption).foregroundStyle(.secondary)
                    if let shareError { Text(shareError).font(.footnote).foregroundStyle(.secondary) }
                    Button {
                        Task {
                            guard !preparing, phase == .active, store.activeConversationID == conversationID else { return }; preparing = true
                            let stamp = shareEpoch
                            defer { if stamp == shareEpoch { preparing = false } }
                            let scope = shareScope
                            do {
                                let data = try await store.attachmentData(photo.attachment.url)
                                guard stamp == shareEpoch, scope == shareScope, !Task.isCancelled else { return }
                                guard let image = UIImage(data: data) else { throw CoveError.message("无法读取这张图片。") }
                                shareImage = image
                            } catch { if stamp == shareEpoch, scope == shareScope { shareError = "未能准备分享：\(error.localizedDescription)" } }
                        }
                    } label: { Label(preparing ? "正在读取…" : "分享或保存图片", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                    .disabled(preparing || !store.isConnected)
                }.padding(20)
            }
            .navigationTitle("旅行影像").navigationBarTitleDisplayMode(.inline)
            .onChange(of: shareScope) { _, _ in shareEpoch = UUID(); shareImage = nil; preparing = false; shareError = nil }
            .onDisappear { shareEpoch = UUID(); shareImage = nil; preparing = false }
            .onChange(of: store.activeConversationID) { _, value in if value != conversationID { shareImage = nil; dismiss() } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.frame(minHeight: 44) } }
            .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
                if let shareImage { CoveTravelImageShare(image: shareImage) }
            }
        }
    }
}
private struct CoveTravelImageShare: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
