import XCTest
@testable import Cove

final class PulseDashboardTests: XCTestCase {
    func testDecodesCompleteDashboardFixture() throws {
        let json = #"""
        {
          "generatedAt":"2026-09-15T08:00:01Z",
          "snapshot":{
            "updatedAt":"2026-09-15T08:00:00Z","summary":"醒着",
            "physical":[],"senses":[],"desires":[],
            "vitals":{"heartRate":72,"temperature":36.4,"breathingRate":14.5,"breathingDepth":"平稳","chord":"Cmaj7","activity":"安静","emotion":"平静","source":"digital_model"},
            "heartbeat":{"lastTickAt":"2026-09-15T08:00:00Z","lastWakeAt":"2026-09-15T07:55:00Z","intervalSeconds":300,"quiet":false,"nextTickAt":"2026-09-15T08:05:00Z"},
            "environment":{"timeOfDay":"下午","weather":null,"temperature":null,"source":"clock","updatedAt":"2026-09-15T08:00:00Z"}
          },
          "history":[{"id":"h1","at":"2026-09-15T08:00:00Z","heartRate":72,"temperature":36.4,"breathingRate":14.5}],
          "events":[{"id":"e1","createdAt":"2026-09-15T07:55:00Z","completedAt":"2026-09-15T07:55:02Z","reason":"heartbeat","status":"complete","thoughtSummary":"想看看有没有新消息","actions":[{"id":"a1","title":"检查队列","status":"complete","detail":null}],"resultSummary":"没有待处理项","conversationID":null,"messageID":null}],
          "murmurs":[{"id":"m1","createdAt":"2026-09-15T07:56:00Z","text":"窗外很安静","source":"pulse"}],
          "warnings":[]
        }
        """#.data(using: .utf8)!
        let value = try CoveJSON.decoder().decode(PulseDashboard.self, from: json)
        XCTAssertEqual(value.snapshot.vitals?.source, "digital_model")
        XCTAssertEqual(value.history.map(\.id), ["h1"])
        XCTAssertEqual(value.events.first?.actions.first?.title, "检查队列")
        XCTAssertEqual(value.snapshot.legacySnapshot.summary, "醒着")
    }

    func testMissingOptionalHistoricalDetailsRemainNil() throws {
        let json = #"""
        {"generatedAt":"2026-09-15T08:00:01Z","snapshot":{"updatedAt":"2026-09-15T08:00:00Z","summary":"old","physical":[],"senses":[],"desires":[],"vitals":null,"heartbeat":null,"environment":null},"history":[],"events":[{"id":"e","createdAt":"2026-09-15T07:55:00Z","completedAt":null,"reason":"timer","status":"complete","thoughtSummary":null,"actions":[],"resultSummary":null,"conversationID":null,"messageID":null}],"murmurs":[],"warnings":["history unavailable"]}
        """#.data(using: .utf8)!
        let value = try CoveJSON.decoder().decode(PulseDashboard.self, from: json)
        XCTAssertNil(value.snapshot.vitals)
        XCTAssertNil(value.events[0].thoughtSummary)
        XCTAssertNil(value.events[0].resultSummary)
        XCTAssertTrue(value.history.isEmpty)
    }
}
