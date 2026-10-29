import XCTest
@testable import Cove

final class CoveTravelTests: XCTestCase {
    private var journey: CoveTravelJourney {
        .init(id: "journey", conversationID: "chat", destination: "京都", mode: "together", status: "active",
              waiting: true, sceneID: "scene-1", sceneText: "走进小巷。", path: [], startedAt: "2026-10-09T12:00:00Z", updatedAt: "2026-10-09T12:01:00Z")
    }
    func testReplyBindsOnlyWaitingTogetherActiveScene() {
        XCTAssertEqual(journey.replySceneID(conversation: "chat"), "scene-1")
        XCTAssertNil(journey.replySceneID(conversation: "other"))
        var value = journey
        value.mode = "solo"; XCTAssertNil(value.replySceneID(conversation: "chat"))
        value = journey; value.status = "paused"; XCTAssertNil(value.replySceneID(conversation: "chat"))
        value = journey; value.status = "error"; XCTAssertNil(value.replySceneID(conversation: "chat"))
        value = journey; value.waiting = false; XCTAssertNil(value.replySceneID(conversation: "chat"))
        value = journey; value.sceneID = ""; XCTAssertNil(value.replySceneID(conversation: "chat"))
    }
    func testLegacyMessageHasNoInventedTravelReply() throws {
        let data = Data(#"{"id":"old","conversationID":"chat","role":"user","text":"hello","createdAt":"2026-09-13T00:00:00Z","status":"sent"}"#.utf8)
        XCTAssertNil(try CoveJSON.decoder().decode(ChatMessage.self, from: data).travelSceneID)
    }
    func testDurableOutboxKeepsSceneAtEnqueueTime() throws {
        let message = ChatMessage(id: "reply", conversationID: "chat", role: "user", text: "一起走", createdAt: Date(), status: "pending", travelSceneID: "scene-1")
        let cached = try JSONEncoder().encode(message)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: cached)
        XCTAssertEqual(restored.travelSceneID, "scene-1")
        var ack = restored; ack.status = "sent"; ack.travelSceneID = nil
        XCTAssertEqual(restored.mergingServerUpdate(ack).travelSceneID, "scene-1")
    }
    func testSnapshotDecodesOptionalWeatherAndAbsentRevision() throws {
        let data = Data(#"{"available":true,"conversationID":"chat","archives":[]}"#.utf8)
        let value = try JSONDecoder().decode(CoveTravelSnapshot.self, from: data)
        XCTAssertTrue(value.available); XCTAssertNil(value.journey); XCTAssertNil(value.invitation); XCTAssertNil(value.revision)
    }
    func testJourneyRoundTripWithVirtualRoute() throws {
        var value = journey
        value.position = .init(lat: 35, lon: 135)
        value.path = [.init(lat: 35, lon: 135), .init(lat: 35.01, lon: 135.02)]
        value.weather = .init(tempC: 22, text: "晴", source: "测试数据")
        XCTAssertEqual(try JSONDecoder().decode(CoveTravelJourney.self, from: JSONEncoder().encode(value)), value)
    }
    func testMapRejectsInvalidCoordinates() {
        XCTAssertTrue(CoveTravelPoint(lat: 90, lon: -180).isValid)
        XCTAssertFalse(CoveTravelPoint(lat: 91, lon: 0).isValid)
        XCTAssertFalse(CoveTravelPoint(lat: 0, lon: .infinity).isValid)
        XCTAssertFalse(CoveTravelPoint(lat: .nan, lon: 0).isValid)
    }
    func testStatusUsesExplicitNonSuccessStates() {
        var value = journey
        XCTAssertEqual(value.statusText, "这一幕，等你回应")
        value.status = "paused"; XCTAssertEqual(value.statusText, "旅行已暂停")
        value.status = "error"; XCTAssertEqual(value.statusText, "旅行遇到问题")
        value.status = "ended"; XCTAssertEqual(value.statusText, "旅行已结束")
    }
    func testUnknownOutcomeCannotResumeOrBindReply() {
        var value = journey
        value.outcomeUnknown = true
        XCTAssertNil(value.replySceneID(conversation: "chat"))
        XCTAssertFalse(value.allowsControl("pause"))
        value.status = "paused"
        XCTAssertFalse(value.allowsControl("resume"))
        XCTAssertTrue(value.allowsControl("end"))
        XCTAssertEqual(value.statusText, "结果尚未确认，旅行已暂停")
    }
    func testNormalPauseResumeAndUnknownStatusAreDistinct() {
        var value = journey
        XCTAssertTrue(value.allowsControl("pause"))
        XCTAssertFalse(value.allowsControl("resume"))
        value.status = "paused"
        XCTAssertTrue(value.allowsControl("resume"))
        XCTAssertNil(value.replySceneID(conversation: "chat"))
        value.status = "future-status"
        XCTAssertEqual(value.statusText, "旅行状态暂未确认")
        XCTAssertFalse(value.allowsControl("resume"))
        XCTAssertNil(value.replySceneID(conversation: "chat"))
    }

    private func invitationSnapshot(status: String, journey: CoveTravelJourney? = nil) -> CoveTravelSnapshot {
        .init(available: true, conversationID: "chat",
              invitation: .init(id: "invite", destination: "京都", status: status, createdAt: "2026-10-09T12:00:00Z"),
              journey: journey, archives: [])
    }
    func testDispatchedInvitationNeverOffersAcceptWhileChecking() {
        let value = invitationSnapshot(status: "pending")
        XCTAssertEqual(value.invitationPresentation(checkingIDs: []), .pending)
        XCTAssertEqual(value.invitationPresentation(checkingIDs: ["invite"]), .checking)
        // A GET still showing pending does not prove a dispatched POST failed.
        XCTAssertEqual(value.invitationPresentation(checkingIDs: ["invite"]), .checking)
    }
    func testAcceptedUnknownDepartureIsNotAnotherInvitation() {
        var value = journey
        value.status = "paused"; value.outcomeUnknown = true
        let snapshot = invitationSnapshot(status: "accepted", journey: value)
        XCTAssertEqual(snapshot.invitationPresentation(checkingIDs: ["invite"]), .unconfirmedDeparture)
        XCTAssertTrue(value.allowsControl("end"))
        XCTAssertFalse(value.allowsControl("resume"))
    }
    func testTerminalInvitationCannotLeaveEmptyInvitationCard() {
        for status in ["accepted", "declined"] {
            let value = invitationSnapshot(status: status)
            XCTAssertEqual(value.invitationPresentation(checkingIDs: ["invite"]), .hidden)
        }
    }
    func testFailedAndAcceptingInvitationOnlyOfferReadOnlyChecking() {
        for status in ["accepting"] {
            XCTAssertEqual(invitationSnapshot(status: status).invitationPresentation(checkingIDs: []), .checking)
        }
    }
    func testReservedJourneyNeverOffersInvitationAgain() {
        XCTAssertEqual(invitationSnapshot(status: "pending", journey: journey).invitationPresentation(checkingIDs: []), .hidden)
        var uncertain = journey; uncertain.outcomeUnknown = true
        XCTAssertEqual(invitationSnapshot(status: "pending", journey: uncertain).invitationPresentation(checkingIDs: []), .unconfirmedDeparture)
    }

    func testAcceptedReservationWithoutLandingIsStillChecking() {
        var reserved = journey
        reserved.position = nil; reserved.sceneText = ""
        XCTAssertEqual(invitationSnapshot(status: "accepted", journey: reserved).invitationPresentation(checkingIDs: []), .checking)
        reserved.position = .init(lat: 35, lon: 135)
        XCTAssertEqual(invitationSnapshot(status: "accepted", journey: reserved).invitationPresentation(checkingIDs: []), .hidden)
    }

    func testKnownFailureDoesNotWaitOrOfferAcceptAgain() {
        XCTAssertEqual(invitationSnapshot(status: "failed", journey: journey).invitationPresentation(checkingIDs: ["invite"]), .failedDeparture)
    }
    func testLegacyUnknownShowsUnconfirmedInsteadOfPending() {
        var value = journey; value.status = "paused"; value.outcomeUnknown = true
        XCTAssertEqual(invitationSnapshot(status: "unknown", journey: value).invitationPresentation(checkingIDs: ["invite"]), .unconfirmedDeparture)
        XCTAssertEqual(invitationSnapshot(status: "unknown").invitationPresentation(checkingIDs: []), .hidden)
        XCTAssertEqual(invitationSnapshot(status: "failed").invitationPresentation(checkingIDs: []), .hidden)
        value.status = "ended"
        XCTAssertEqual(invitationSnapshot(status: "unknown", journey: value).invitationPresentation(checkingIDs: []), .hidden)
    }

    func testChatCardOnlyShowsActionableOrInFlightInvitation() {
        XCTAssertTrue(CoveTravelInvitationPresentation.pending.showsInChat)
        XCTAssertTrue(CoveTravelInvitationPresentation.checking.showsInChat)
        for state in [CoveTravelInvitationPresentation.hidden, .unconfirmedDeparture, .failedDeparture] {
            XCTAssertFalse(state.showsInChat)
        }
    }

    private func albumPage(sequence: Int, revision: Int = 1, albumRevision: Int = 1, hasMore: Bool = true) -> CoveTravelAlbum {
        .init(journey: journey,
              scenes: [.init(id: "scene-\(sequence)", sequence: sequence, journeyID: journey.id, createdAt: "2026-10-09T12:00:00Z", kind: "walk", text: "沿街走过")],
              photos: [], nextCursor: sequence, hasMore: hasMore, revision: revision, albumRevision: albumRevision)
    }
    func testLegacyJourneyDecodesWithoutAlbumFields() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journey)) as? [String: Any])
        object.removeValue(forKey: "photoCount"); object.removeValue(forKey: "coverPhoto")
        let restored = try JSONDecoder().decode(CoveTravelJourney.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.photoCount); XCTAssertNil(restored.coverPhoto)
    }
    func testAlbumPaginationMergesScenesWithoutDuplicates() throws {
        let first = albumPage(sequence: 1)
        var second = albumPage(sequence: 2, hasMore: false)
        second.scenes.insert(first.scenes[0], at: 0)
        let result = try XCTUnwrap(first.merging(second))
        XCTAssertEqual(result.scenes.map(\.sequence), [1, 2])
        var scene = result.scenes[0]
        scene.sequence = 9876 // Global cursor is not a per-journey scene number.
        XCTAssertEqual(scene.title, "这一幕"); XCTAssertNil(scene.recoveryNote)
        scene.kind = "resumed"; XCTAssertEqual(scene.title, "重新同行"); XCTAssertNil(scene.recoveryNote)
        scene.kind = "recovered"; XCTAssertEqual(scene.title, "既有记录")
        XCTAssertEqual(scene.recoveryNote, "仅保留旧旅程最后一幕，不代表完整历史。")
        XCTAssertFalse(result.hasMore); XCTAssertEqual(result.nextCursor, 2)
    }
    func testAlbumRejectsWrongJourneyAndStaleRevisions() {
        let first = albumPage(sequence: 1, revision: 5, albumRevision: 8)
        XCTAssertNil(first.merging(albumPage(sequence: 2, revision: 4, albumRevision: 8)))
        XCTAssertNil(first.merging(albumPage(sequence: 2, revision: 5, albumRevision: 7)))
        var other = albumPage(sequence: 2, revision: 5, albumRevision: 8)
        other.journey.id = "other"
        XCTAssertNil(first.merging(other))
    }
    func testAlbumRejectsNonAdvancingPageAndCrossJourneyScene() {
        let first = albumPage(sequence: 1)
        XCTAssertNil(first.merging(albumPage(sequence: 1)))
        var next = albumPage(sequence: 2)
        next.scenes[0].journeyID = "other"
        XCTAssertNil(first.merging(next))
    }
    func testTravelPhotoCarriesRealAttachmentAndExplicitSource() throws {
        let photo = CoveTravelPhoto(id: "photo", journeyID: journey.id, sceneID: "scene-1", createdAt: "2026-10-09T12:00:00Z", caption: "巷口", source: "ai_generated",
                                    attachment: .init(id: "attachment", filename: "travel.png", mime: "image/png", size: 42, url: "/v1/attachments/attachment"))
        let decoded = try JSONDecoder().decode(CoveTravelPhoto.self, from: JSONEncoder().encode(photo))
        XCTAssertEqual(decoded, photo)
        XCTAssertEqual(decoded.sourceLabel, "AI 生成的旅行影像")
        XCTAssertEqual(decoded.attachment.url, "/v1/attachments/attachment")
    }

}
