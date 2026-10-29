import Foundation
import Combine

struct CoveTravelPoint: Codable, Equatable {
    var lat: Double
    var lon: Double
    var isValid: Bool { lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon) }
}
struct CoveTravelInvitation: Codable, Identifiable, Equatable {
    var id: String
    var destination: String
    var status: String
    var createdAt: String
}
struct CoveTravelWeather: Codable, Equatable {
    var tempC: Double?
    var text: String?
    var source: String?
}
struct CoveTravelJourney: Codable, Identifiable, Equatable {
    var id: String
    var conversationID: String
    var destination: String
    var mode: String
    var status: String
    var waiting: Bool
    var sceneID: String
    var sceneText: String
    var position: CoveTravelPoint?
    var path: [CoveTravelPoint]
    var weather: CoveTravelWeather?
    var startedAt: String
    var updatedAt: String
    var outcomeUnknown: Bool? = nil
    var photoCount: Int? = nil
    var coverPhoto: CoveTravelPhoto? = nil
    var statusText: String {
        if outcomeUnknown == true { return "结果尚未确认，旅行已暂停" }
        switch status {
        case "paused": return "旅行已暂停"
        case "ended": return "旅行已结束"
        case "error": return "旅行遇到问题"
        case "active": return waiting ? "这一幕，等你回应" : "正在同行"
        default: return "旅行状态暂未确认"
        }
    }
    func allowsControl(_ action: String) -> Bool {
        switch action {
        case "pause": return status == "active" && outcomeUnknown != true
        case "resume": return status == "paused" && outcomeUnknown != true
        case "end": return ["active", "paused", "error"].contains(status)
        default: return false
        }
    }
    func replySceneID(conversation: String) -> String? {
        guard outcomeUnknown != true, conversationID == conversation, mode == "together", status == "active", waiting, !sceneID.isEmpty else { return nil }
        return sceneID
    }
}
struct CoveTravelSnapshot: Codable, Equatable {
    var available: Bool
    var conversationID: String
    var invitation: CoveTravelInvitation?
    var journey: CoveTravelJourney?
    var archives: [CoveTravelJourney]
    var revision: Int? = nil
    var albumRevision: Int? = nil
}

enum CoveTravelInvitationPresentation: Equatable {
    case hidden, pending, checking, unconfirmedDeparture, failedDeparture
    var showsInChat: Bool { self == .pending || self == .checking }
}

extension CoveTravelSnapshot {
    func invitationPresentation(checkingIDs: Set<String>) -> CoveTravelInvitationPresentation {
        guard let invitation else { return .hidden }
        if invitation.status == "declined" { return .hidden }
        if journey == nil && ["failed", "unknown"].contains(invitation.status) { return .hidden }
        if journey?.status == "ended" { return .hidden }
        if invitation.status == "failed" { return .failedDeparture }
        if invitation.status == "unknown" || journey?.outcomeUnknown == true { return .unconfirmedDeparture }
        if invitation.status == "accepted" {
            if let journey, journey.status == "active", journey.position == nil, journey.sceneText.isEmpty { return .checking }
            return .hidden
        }
        if checkingIDs.contains(invitation.id) || invitation.status == "accepting" { return .checking }
        // A reserved journey is never another invitation to dispatch.
        return invitation.status == "pending" && journey == nil ? .pending : .hidden
    }
}

struct CoveTravelPhoto: Codable, Identifiable, Equatable {
    var id: String
    var journeyID: String
    var sceneID: String
    var createdAt: String
    var caption: String
    var source: String
    var attachment: ChatAttachment
    var sourceLabel: String { source == "ai_generated" ? "AI 生成的旅行影像" : "旅行影像 · 来源未标明" }
}
struct CoveTravelSceneReply: Codable, Equatable {
    var messageID: String
    var sceneID: String
    var text: String
}
struct CoveTravelScene: Codable, Identifiable, Equatable {
    var id: String
    var sequence: Int
    var journeyID: String
    var createdAt: String
    var kind: String
    var text: String
    var position: CoveTravelPoint?
    var lastReply: CoveTravelSceneReply?
    var title: String {
        switch kind {
        case "resumed": return "重新同行"
        case "recovered": return "既有记录"
        default: return "这一幕"
        }
    }
    var recoveryNote: String? { kind == "recovered" ? "仅保留旧旅程最后一幕，不代表完整历史。" : nil }
}
struct CoveTravelAlbum: Codable, Equatable {
    var journey: CoveTravelJourney
    var scenes: [CoveTravelScene]
    var photos: [CoveTravelPhoto]
    var nextCursor: Int
    var hasMore: Bool
    var revision: Int? = nil
    var albumRevision: Int? = nil

    func merging(_ page: CoveTravelAlbum) -> CoveTravelAlbum? {
        guard journey.id == page.journey.id, journey.conversationID == page.journey.conversationID,
              page.scenes.allSatisfy({ $0.journeyID == journey.id }),
              page.photos.allSatisfy({ $0.journeyID == journey.id }),
              page.nextCursor >= nextCursor,
              !(page.hasMore && page.nextCursor == nextCursor) else { return nil }
        if let old = revision, let next = page.revision, next < old { return nil }
        if let old = albumRevision, let next = page.albumRevision, next < old { return nil }
        var value = page
        var rows = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for scene in page.scenes { rows[scene.id] = scene }
        value.scenes = rows.values.sorted { $0.sequence < $1.sequence }
        return value
    }
}

@MainActor
final class CoveTravelModel: ObservableObject {
    @Published private(set) var snapshot: CoveTravelSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var acting = false
    @Published private(set) var checkingInvitationIDs: Set<String> = []
    @Published private(set) var mutationUnconfirmed = false
    private var scope = ""
    private var epoch = UUID()
    private var fetchID = UUID()
    private var requestIDs: [String: String] = [:]

    func reset(scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        epoch = UUID()
        snapshot = nil; error = nil; loading = false; acting = false
    }
    var invitationPresentation: CoveTravelInvitationPresentation {
        snapshot?.invitationPresentation(checkingIDs: checkingInvitationIDs) ?? .hidden
    }
    var hasChatContent: Bool {
        invitationPresentation.showsInChat
    }
    func receiveAlbumSnapshot(_ incoming: CoveTravelSnapshot, conversation: String) {
        guard incoming.conversationID == conversation, snapshot?.conversationID == conversation, accepts(incoming) else { return }
        apply(incoming)
    }
    private func apply(_ incoming: CoveTravelSnapshot) {
        snapshot = incoming
        mutationUnconfirmed = false
        if let invitation = incoming.invitation, ["accepted", "declined", "failed", "unknown"].contains(invitation.status) {
            checkingInvitationIDs.remove(invitation.id)
        }
    }
    private func accepts(_ incoming: CoveTravelSnapshot) -> Bool {
        guard let old = snapshot, old.conversationID == incoming.conversationID else { return true }
        if let current = old.revision, let next = incoming.revision, next < current { return false }
        if let current = old.albumRevision, let next = incoming.albumRevision, next < current { return false }
        return true
    }
    func sceneID(conversation: String) -> String? {
        guard invitationPresentation != .checking, snapshot?.available == true, snapshot?.conversationID == conversation else { return nil }
        return snapshot?.journey?.replySceneID(conversation: conversation)
    }
    func refresh(store: CoveStore) async {
        guard !loading, !acting, store.isConnected, !store.previewMode, !store.activeConversationID.isEmpty else { return }
        let stamp = epoch, conversation = store.activeConversationID, id = UUID()
        fetchID = id; loading = true
        defer { if stamp == epoch, id == fetchID { loading = false } }
        do {
            let result = try await store.travelRequest(conversation: conversation)
            guard stamp == epoch, id == fetchID, !Task.isCancelled, result.conversationID == conversation else { return }
            guard accepts(result) else { return }
            apply(result); error = nil
        } catch is CancellationError { }
        catch {
            guard stamp == epoch, id == fetchID else { return }
            if let http = error as? CoveHTTPError, http.status == 404 {
                snapshot = .init(available: false, conversationID: conversation, archives: [])
                self.error = nil
            } else { self.error = "旅程暂未更新：\(error.localizedDescription)" }
        }
    }
    func respond(_ invitation: CoveTravelInvitation, decision: String, store: CoveStore) async {
        guard let current = snapshot?.invitation, current.id == invitation.id, current.status == "pending", invitationPresentation == .pending, !mutationUnconfirmed, ["accept", "decline"].contains(decision) else { return }
        await mutate(path: "v1/travel/invitations/\(invitation.id)/respond", target: invitation.id,
                     values: ["decision": decision], store: store)
    }
    func control(_ journey: CoveTravelJourney, action: String, store: CoveStore) async {
        guard let current = snapshot?.journey, current.id == journey.id, !mutationUnconfirmed, current.allowsControl(action) else { return }
        await mutate(path: "v1/travel/control", target: journey.id,
                     values: ["journeyID": journey.id, "action": action], store: store)
    }
    private func mutate(path: String, target: String, values: [String: String], store: CoveStore) async {
        guard !acting, store.isConnected, !store.previewMode, snapshot?.conversationID == store.activeConversationID else { return }
        let conversation = store.activeConversationID, stamp = epoch
        // Resume rotates sceneID server-side. Bind control retries to that scene
        // so a lost ACK cannot replay an earlier pause/resume in a later cycle.
        let controlScene = values["action"] == nil ? "" : (snapshot?.journey?.sceneID ?? "")
        let key = store.serverURL + ":" + conversation + ":" + target + ":" + (values["decision"] ?? values["action"] ?? "") + ":" + controlScene
        let requestID = requestIDs[key] ?? UUID().uuidString
        requestIDs[key] = requestID
        acting = true; error = nil; mutationUnconfirmed = true
        if values["decision"] != nil { checkingInvitationIDs.insert(target) }
        // Invalidate any GET begun before this mutation.
        fetchID = UUID(); loading = false
        defer { if stamp == epoch { acting = false } }
        do {
            var body = values
            body["conversationID"] = conversation; body["requestID"] = requestID
            let result = try await store.travelRequest(conversation: conversation, path: path, body: body)
            guard stamp == epoch, !Task.isCancelled, result.conversationID == conversation else { return }
            if accepts(result) { apply(result) }
            requestIDs.removeValue(forKey: key)
        } catch is CancellationError { }
        catch {
            guard stamp == epoch else { return }
            self.error = "操作结果尚未确认，正在只读核对旅程；不会重复出发。"
            // Do not call refresh(): its acting gate intentionally blocks polling
            // during writes. This recovery GET never dispatches another action.
            do {
                let authoritative = try await store.travelRequest(conversation: conversation)
                guard stamp == epoch, !Task.isCancelled, authoritative.conversationID == conversation,
                      accepts(authoritative) else { return }
                apply(authoritative)
                self.error = authoritative.journey?.outcomeUnknown == true
                    ? (values["decision"] == "accept" ? "已接受邀请，但出发未获可靠确认。旅程已暂停，可查看或结束；不会自动重试。" : "旅行操作未获可靠确认，已暂停；可查看或结束，不会自动重试。")
                    : (invitationPresentation == .checking ? "邀请结果仍待核对，请刷新旅程；不会重复提交。" : nil)
            } catch {
                guard stamp == epoch else { return }
                self.error = "操作结果尚未确认，旅程核对也未完成。请刷新旅程；不要重复出发。"
            }
        }
    }
}
