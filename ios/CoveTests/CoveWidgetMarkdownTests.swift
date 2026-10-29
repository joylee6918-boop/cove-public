import XCTest
@testable import Cove

final class CoveWidgetMarkdownTests: XCTestCase {
    private let source = #"{"version":1,"id":"example","state":{},"root":{"type":"Text","props":{"text":"Hello"}}}"#

    func testClosedFenceBetweenProseIndexesWithoutRewritingMarkdown() {
        let index = CoveWidgetMarkdownIndex("Before **bold**\n\n```widget\n\(source)\n```\n\nAfter")
        guard case .widget(let doc) = index.entry(for: source + "\n") else { return XCTFail("Missing widget") }
        XCTAssertEqual(doc.id, "example")
    }
    func testUnclosedWidgetFailsEvenWhenJSONIsComplete() {
        guard case .invalid = CoveWidgetMarkdownIndex("```widget\n\(source)").entry(for: source) else { return XCTFail("Unclosed fence rendered") }
    }
    func testUnknownLanguageAndNestedCodeRemainCode() {
        for markdown in ["```json\n\(source)\n```", "```Widget\n\(source)\n```", "> ```widget\n> \(source)\n> ```", "````markdown\n```widget\n\(source)\n```\n````"] {
            XCTAssertNil(CoveWidgetMarkdownIndex(markdown).entry(for: source))
        }
    }
    func testTildeLongFenceAndCRLF() {
        for markdown in ["~~~~widget\n\(source)\n~~~~~", "```widget\r\n\(source)\r\n```\r\n"] {
            guard case .widget = CoveWidgetMarkdownIndex(markdown).entry(for: source) else { return XCTFail("Valid fence not found") }
        }
    }
    func testDuplicateIDsAndDuplicateNestedContentFailClosed() {
        for tail in ["```widget\n\(source)\n```", "> ```widget\n> \(source)\n> ```", "```widget\n\(source.replacingOccurrences(of: "Hello", with: "World"))\n```"] {
            guard case .invalid = CoveWidgetMarkdownIndex("```widget\n\(source)\n```\n\n" + tail).entry(for: source) else { return XCTFail("Duplicate accepted") }
        }
    }
    func testInvalidVersionAndBlockLimit() {
        let bad = source.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        guard case .invalid = CoveWidgetMarkdownIndex("```widget\n\(bad)\n```").entry(for: bad) else { return XCTFail("Unknown version accepted") }
        let many = (0..<9).map { "```widget\n\(source.replacingOccurrences(of: "example", with: "id\($0)"))\n```" }.joined(separator: "\n\n")
        guard case .invalid = CoveWidgetMarkdownIndex(many).entry(for: source.replacingOccurrences(of: "example", with: "id0")) else { return XCTFail("Limit missing") }
    }
}
