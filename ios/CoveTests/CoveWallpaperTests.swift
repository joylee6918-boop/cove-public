import XCTest
import ImageIO
import UIKit
@testable import Cove

@MainActor
final class CoveWallpaperTests: XCTestCase {
    func testPreviewCanBeCancelledWithoutChangingSavedWallpaper() async throws {
        let fixture = try storage()
        defer { fixture.clean() }
        let store = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        try await store.apply(.rose, brightness: 0)
        let image = try await CoveWallpaperFiles.preview(makePNG(width: 6_000, height: 400))
        XCTAssertEqual(try XCTUnwrap(image.cgImage).width, 2_048)
        // Discard the preview without calling Apply, just like leaving the screen.
        XCTAssertEqual(store.selection, .rose)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.photoURL.path))
        let reopened = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        XCTAssertEqual(reopened.selection, .rose)
        XCTAssertFalse(reopened.hasPhoto)
    }

    func testApplyPersistsBoundedPhotoAndBrightnessAcrossStoreReload() async throws {
        let fixture = try storage()
        defer { fixture.clean() }
        let store = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        try await store.apply(.photo, brightness: -0.18, photoData: makePNG(width: 6_000, height: 400))
        let reopened = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        XCTAssertEqual(reopened.selection, .photo)
        XCTAssertEqual(reopened.brightness, -0.18, accuracy: 0.001)
        await reopened.loadPhotoIfNeeded()
        XCTAssertEqual(try XCTUnwrap(reopened.photo?.cgImage).width, 2_048)
        XCTAssertTrue(reopened.hasPhoto)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(reopened.photoURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 2_048)
    }

    func testBrokenAndAbnormallyWideImagesDoNotReplaceSavedPhoto() async throws {
        let fixture = try storage()
        defer { fixture.clean() }
        let store = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        try await store.apply(.photo, brightness: 0.1, photoData: makePNG(width: 300, height: 200))
        let original = try Data(contentsOf: store.photoURL)
        for invalid in [Data("invalid image".utf8), try makePNG(width: 40_000, height: 1)] {
            do {
                try await store.apply(.photo, brightness: -0.3, photoData: invalid)
                XCTFail("Unsupported or pathological input must be rejected before replacing the wallpaper.")
            } catch {
                XCTAssertEqual(try Data(contentsOf: store.photoURL), original)
                XCTAssertEqual(store.selection, .photo)
                XCTAssertEqual(store.brightness, 0.1, accuracy: 0.001)
            }
        }
    }

    func testConfirmedRemovalDeletesLocalPhotoAndRestoresDefault() async throws {
        let fixture = try storage()
        defer { fixture.clean() }
        let store = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        try await store.apply(.photo, brightness: 0, photoData: makePNG(width: 300, height: 200))
        try await store.apply(.blush, brightness: 0, removeSavedPhoto: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.photoURL.path))
        let reopened = CoveWallpaperStore(defaults: fixture.defaults, directory: fixture.directory)
        XCTAssertEqual(reopened.selection, .blush)
        XCTAssertFalse(reopened.hasPhoto)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.65, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func storage() throws -> Storage {
        let suite = "CoveWallpaperTests-" + UUID().uuidString
        return Storage(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), suite: suite,
                       directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true))
    }
    private struct Storage {
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
