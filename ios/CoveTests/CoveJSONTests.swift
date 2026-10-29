import XCTest
@testable import Cove

final class CoveJSONTests: XCTestCase {
    func testFractionalWholeSecondsAndOffsetsRemainCompatible() throws {
        let samples = ["2026-09-23T09:30:00Z", "2026-09-23T09:30:00.123Z",
                       "2026-09-23T17:30:00+08:00", "2026-09-23T17:30:00.123456+08:00"]
        for raw in samples {
            let decoded = try CoveJSON.decoder().decode(Date.self, from: JSONEncoder().encode(raw))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = raw.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            let expected = try XCTUnwrap(formatter.date(from: raw))
            XCTAssertEqual(decoded.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testInvalidDatesStillFailInsteadOfInventingCurrentTime() throws {
        for raw in ["", "invalid", "2026-09-23", "2026-13-23T09:30:00Z"] {
            XCTAssertThrowsError(try CoveJSON.decoder().decode(Date.self, from: JSONEncoder().encode(raw)))
        }
    }

    func testLargeSyntheticHistoryRoundTrip() throws {
        let dates = (0..<20_000).map { Date(timeIntervalSince1970: 1_790_000_000 + Double($0)) }
        let data = try CoveJSON.encoder().encode(dates)
        XCTAssertEqual(try CoveJSON.decoder().decode([Date].self, from: data), dates)
    }
}
