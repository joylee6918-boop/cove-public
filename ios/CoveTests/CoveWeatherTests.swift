import XCTest
@testable import Cove

final class CoveWeatherTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    private func fixture() -> CoveWeatherAttribution {
        .init(required: true, serviceName: "Apple Weather",
              markLightURL: "https://weatherkit.apple.com/assets/branding/light.png",
              markDarkURL: "https://weatherkit.apple.com/assets/branding/dark.png",
              markLightData: png, markDarkData: png,
              legalURLs: ["https://developer.apple.com/weatherkit/data-source-attribution/"],
              sourceValidAt: "2026-10-14T12:34:28Z", fetchedAt: "2026-10-14T12:35:00Z",
              expiresAt: "2026-10-14T12:39:28Z", timezone: "Asia/Shanghai")
    }

    func testOldMessagesRemainDecodableWithoutInventedWeather() throws {
        let bytes = Data(#"{"id":"old","conversationID":"chat","role":"assistant","text":"hello","createdAt":"2026-09-13T00:00:00Z","status":"complete"}"#.utf8)
        XCTAssertNil(try CoveJSON.decoder().decode(ChatMessage.self, from: bytes).weatherAttribution)
    }

    func testAttributionPersistsWithMessageAndHiddenUntilWholeReply() throws {
        var message = ChatMessage(id: "weather", conversationID: "a", role: "assistant", text: "北京天气", createdAt: Date(), status: "streaming", weatherAttribution: fixture())
        XCTAssertNil(message.readyForDisplay.weatherAttribution)
        message.status = "complete"
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.weatherAttribution, fixture())
        XCTAssertEqual(restored.readyForDisplay.weatherAttribution, fixture())
    }

    func testOfficialLegalAndMarkURLsHaveSeparateAllowlists() {
        XCTAssertEqual(fixture().safeLegalURLs.count, 1)
        XCTAssertNil(CoveWeatherAttribution.appleURL("https://developer.apple.com/weatherkit/data-source-attribution/"))
        for url in ["http://weatherkit.apple.com/a", "https://evil.invalid/a", "https://user@weatherkit.apple.com/a", "https://weatherkit.apple.com:444/a", "https://weatherkit.apple.com\\@evil.invalid/a"] {
            XCTAssertNil(CoveWeatherAttribution.appleURL(url))
        }
    }

    func testOfficialPNGBytesAreDecodedLocallyAndBeijingTimeDoesNotUsePhoneZone() {
        XCTAssertEqual(fixture().markData(dark: true), Data(base64Encoded: png))
        XCTAssertEqual(CoveWeatherAttribution.beijingTime(fixture().sourceDate!), "10-14 20:34（北京时间）")
    }

    func testMalformedMarkDoesNotReachImageDecoder() throws {
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as! [String: Any]
        for invalid in ["not base64", Data("not png".utf8).base64EncodedString(), String(repeating: "A", count: 350_001)] {
            body["markLightData"] = invalid
            let value = try JSONDecoder().decode(CoveWeatherAttribution.self, from: JSONSerialization.data(withJSONObject: body))
            XCTAssertNil(value.markData(dark: false))
        }
    }

    func testCompactPreviewUsesMetadataNotWordsAndKeepsFullHistoricalBody() throws {
        var message = ChatMessage(id: "weather", conversationID: "a", role: "assistant", text: "北京气温 23°C", createdAt: Date(), status: "complete", weatherAttribution: fixture())
        XCTAssertEqual(message.previewText(), "北京天气消息，打开查看")
        XCTAssertEqual(message.text, "北京气温 23°C")
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as! [String: Any]
        body["expiresAt"] = "2020-01-01T00:00:00Z"
        message.weatherAttribution = try JSONDecoder().decode(CoveWeatherAttribution.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(message.previewText(), "北京天气消息，打开查看")
        message.role = "user"
        XCTAssertEqual(message.previewText(), message.text)
        message.role = "assistant"; message.weatherAttribution = nil
        message.text = "Apple Weather 北京天气 23°C"
        XCTAssertEqual(message.previewText(), message.text)
    }

    func testInvalidMetadataDoesNotChangeOrdinaryPreviewOrAttachmentFallback() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as! [String: Any]
        for (key, invalid) in [("required", false), ("timezone", "UTC"), ("serviceName", ""),
                               ("legalURLs", ["https://evil.invalid/"]), ("sourceValidAt", "bad"),
                               ("markLightURL", "https://evil.invalid/a.png"), ("markDarkData", "bad")] as [(String, Any)] {
            var broken = body; broken[key] = invalid
            let attribution = try JSONDecoder().decode(CoveWeatherAttribution.self, from: JSONSerialization.data(withJSONObject: broken))
            let message = ChatMessage(id: "m", conversationID: "a", role: "assistant", text: "普通正文", createdAt: Date(), status: "complete", weatherAttribution: attribution)
            XCTAssertEqual(message.previewText(), "普通正文", key)
        }
        var empty = ChatMessage(id: "m", conversationID: "a", role: "assistant", text: "", createdAt: Date(), status: "complete")
        XCTAssertEqual(empty.previewText(), "附件")
        XCTAssertEqual(empty.previewText(emptyFallback: "一个附件"), "一个附件")
        empty.attachments = [.init(id: "file", filename: "report.pdf", mime: "application/pdf", size: 1, url: "/file")]
        XCTAssertEqual(empty.previewText(), "report.pdf")
    }
}
