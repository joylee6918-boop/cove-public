import XCTest
import ImageIO
import UIKit
@testable import Cove

final class AttachmentImageTests: XCTestCase {
    func testThumbnailAndPreviewUseSeparatePixelLimitsAndPreserveOriginal() async throws {
        let url = try makeImage(width: 6_000, height: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        XCTAssertLessThan(original.count, CoveAttachmentFiles.maximumBytes)

        let thumbnail = try await CoveAttachmentImages.downsample(url, maximumPixelSize: CoveAttachmentImages.thumbnailPixelLimit)
        let preview = try await CoveAttachmentImages.downsample(url, maximumPixelSize: CoveAttachmentImages.previewPixelLimit)
        let small = try XCTUnwrap(thumbnail.cgImage)
        let large = try XCTUnwrap(preview.cgImage)
        XCTAssertEqual(max(small.width, small.height), 768)
        XCTAssertEqual(max(large.width, large.height), 4_096)
        XCTAssertGreaterThan(large.width, small.width, "The image sheet must decode its own larger preview rather than enlarge the chat thumbnail.")
        XCTAssertEqual(try Data(contentsOf: url), original, "Saving or sharing must retain the original encoded file.")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 6_000)
    }

    func testImageOrientationIsAppliedWithoutUpscaling() async throws {
        let url = try makeImage(width: 600, height: 200, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try await CoveAttachmentImages.downsample(url, maximumPixelSize: 768)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 200)
        XCTAssertEqual(pixels.height, 600)
        XCTAssertEqual(image.imageOrientation, .up)
    }

    func testAbnormalSourceDimensionsAreRejectedEvenWhenFileIsSmall() async throws {
        let url = try makeImage(width: 40_000, height: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        XCTAssertLessThan(original.count, CoveAttachmentFiles.maximumBytes)
        do {
            _ = try await CoveAttachmentImages.downsample(url, maximumPixelSize: 768)
            XCTFail("Encoded file size must not bypass the source dimension limit.")
        } catch CoveAttachmentImageError.abnormalDimensions {
            XCTAssertEqual(try Data(contentsOf: url), original, "A rejected preview must still leave its original file available for saving.")
        }
    }

    func testUndecodableImageFailsWithoutAlteringOriginal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let original = Data("not an image".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await CoveAttachmentImages.downsample(url, maximumPixelSize: 4_096)
            XCTFail("Invalid images must use the save-original fallback.")
        } catch CoveAttachmentImageError.unreadable {
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    private func makeImage(width: Int, height: Int, orientation: Int? = nil) throws -> URL {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.12, green: 0.43, blue: 0.48, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(bitmap.makeImage())
        let isJPEG = orientation != nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (isJPEG ? ".jpg" : ".png"))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, (isJPEG ? "public.jpeg" : "public.png") as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "AttachmentImageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode test image"])
        }
        return url
    }
}
