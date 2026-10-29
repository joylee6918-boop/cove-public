import XCTest
import UIKit
@testable import Cove

@MainActor
final class CoveAttachmentComposerTests: XCTestCase {
    private func file(_ name: String) -> CoveOutgoingFile {
        .init(data: Data(name.utf8), filename: name, mime: "text/plain")
    }

    func testFilesAndCaptionSurviveCategoryRoundTripWithoutSending() async throws {
        let composer = CoveAttachmentComposer()
        composer.reset(conversationID: "conversation-a", caption: "保留附言")
        try composer.add([file("first.txt"), file("second.txt")])
        composer.category = "files"
        composer.category = "photos"
        composer.category = "files"
        XCTAssertEqual(composer.caption, "保留附言")
        XCTAssertEqual(composer.conversationID, "conversation-a")
        let prepared = try await composer.files()
        XCTAssertEqual(prepared.map(\.filename), ["first.txt", "second.txt"])
        XCTAssertEqual(prepared.map(\.data), [Data("first.txt".utf8), Data("second.txt".utf8)])
    }

    func testSelectionLimitRejectsWholeImportWithoutLosingEarlierSelection() throws {
        let composer = CoveAttachmentComposer()
        try composer.add((0..<9).map { file("\($0).txt") })
        XCTAssertThrowsError(try composer.add([file("10.txt"), file("11.txt")]))
        XCTAssertEqual(composer.choices.count, 9)
        try composer.add([file("photo.jpg")])
        XCTAssertEqual(composer.choices.count, 10)
    }

    func testNewSheetInvalidatesOldAsyncImportAndClearsSelection() throws {
        let composer = CoveAttachmentComposer()
        composer.reset(conversationID: "old", caption: "old draft")
        let previous = composer.generation
        try composer.add([file("old.txt")])
        composer.preparing = true
        composer.reset(conversationID: "new", caption: "new draft")
        XCTAssertNotEqual(previous, composer.generation)
        XCTAssertEqual(composer.conversationID, "new")
        XCTAssertEqual(composer.caption, "new draft")
        XCTAssertTrue(composer.choices.isEmpty)
        XCTAssertFalse(composer.preparing)
    }

    private func photo(_ color: UIColor = .red) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }

    func testNativePhotoImportPreservesOrderCaptionAndExistingFiles() async throws {
        let composer = CoveAttachmentComposer()
        composer.reset(conversationID: "photos", caption: "保留配文")
        try composer.add([file("first.txt")])
        let red = photo(), blue = photo(.blue)
        composer.importPhotos([{ red }, { blue }])
        XCTAssertTrue(composer.preparing)
        await composer.work?.value
        let files = try await composer.files()
        XCTAssertEqual(files.map(\.filename), ["first.txt", "照片-2.jpg", "照片-3.jpg"])
        XCTAssertEqual(files[1].mime, "image/jpeg")
        XCTAssertNotEqual(files[1].data, files[2].data)
        XCTAssertNotNil(UIImage(data: files[1].data))
        XCTAssertEqual(composer.caption, "保留配文")
        XCTAssertEqual(composer.conversationID, "photos")
        XCTAssertFalse(composer.preparing)
        XCTAssertNil(composer.failure)
    }

    func testFailedPhotoBatchIsAtomicAndKeepsEarlierDraft() async throws {
        let composer = CoveAttachmentComposer()
        composer.reset(conversationID: "photos", caption: "不能丢")
        try composer.add([file("keep.txt")])
        let valid = photo()
        composer.importPhotos([{ valid }, { nil }])
        await composer.work?.value
        XCTAssertEqual(composer.choices.compactMap(\.file).map(\.filename), ["keep.txt"])
        XCTAssertEqual(composer.caption, "不能丢")
        XCTAssertNotNil(composer.failure)
        XCTAssertFalse(composer.preparing)
    }

    func testEmptyPickerResultPreservesSelectionAndCaption() throws {
        let composer = CoveAttachmentComposer()
        composer.reset(conversationID: "photos", caption: "取消不清空")
        try composer.add([file("keep.txt")])
        composer.importPhotos([])
        XCTAssertEqual(composer.choices.count, 1)
        XCTAssertEqual(composer.caption, "取消不清空")
        XCTAssertFalse(composer.preparing)
        XCTAssertNil(composer.work)
    }

    func testPhotoLimitRejectsBeforeReadingProviders() throws {
        let composer = CoveAttachmentComposer()
        try composer.add((0..<10).map { file("\($0).txt") })
        var loaded = false
        composer.importPhotos([{ loaded = true; return nil }])
        XCTAssertFalse(loaded)
        XCTAssertEqual(composer.choices.count, 10)
        XCTAssertNotNil(composer.failure)
        XCTAssertFalse(composer.preparing)
    }

    func testLatePhotoResultCannotEnterNewDraft() async {
        let composer = CoveAttachmentComposer()
        composer.reset(conversationID: "old", caption: "old")
        let started = expectation(description: "provider started")
        var continuation: CheckedContinuation<Data?, Never>?
        composer.importPhotos([{
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }])
        let oldWork = composer.work
        await fulfillment(of: [started], timeout: 2)
        composer.reset(conversationID: "new", caption: "new")
        continuation?.resume(returning: photo())
        await oldWork?.value
        XCTAssertEqual(composer.conversationID, "new")
        XCTAssertEqual(composer.caption, "new")
        XCTAssertTrue(composer.choices.isEmpty)
        XCTAssertFalse(composer.preparing)
        XCTAssertNil(composer.failure)
    }

    func testUnreadablePhotoDoesNotCreateAttachment() async {
        let composer = CoveAttachmentComposer()
        composer.importPhotos([{ Data("not an image".utf8) }])
        await composer.work?.value
        XCTAssertTrue(composer.choices.isEmpty)
        XCTAssertNotNil(composer.failure)
        XCTAssertFalse(composer.preparing)
    }
}
