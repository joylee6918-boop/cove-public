import XCTest
@testable import Cove

final class CoveWidgetTests: XCTestCase {
    private func value(_ source: String) throws -> CoveWidgetValue { try JSONDecoder().decode(CoveWidgetValue.self, from: Data(source.utf8)) }
    private func document(root: String, state: String = "{}", extra: String = "") throws -> CoveWidgetDocument {
        try CoveWidgetDocument.parse("{\"version\":1,\"id\":\"demo\",\"state\":\(state),\"root\":\(root)\(extra)}")
    }
    func testNestedFormAndExpressions() throws {
        let doc = try document(root: #"{"type":"Card","props":{"title":"表单"},"children":[{"type":"Input","props":{"label":"名字","bind":"name"}},{"type":"Slider","props":{"label":"数量","bind":"count","min":0,"max":10}},{"type":"Button","props":{"label":"发送","action":{"type":"send","text":{"op":"concat","args":["名字：",{"ref":"name"}]}}}}]}"#, state: #"{"name":"","count":2}"#)
        XCTAssertEqual(doc.root.children.count, 3)
        var state = doc.state
        state["name"] = .string("用户")
        XCTAssertEqual(try CoveWidgetEngine.apply(doc.root.children[2].props["action"]!, state: &state), "名字：用户")
    }
    func testSetUsesSnapshotAndIsAtomic() throws {
        var state: [String: CoveWidgetValue] = ["a": .number(1), "b": .number(2)]
        let swap = try value(#"{"type":"set","values":{"a":{"ref":"b"},"b":{"ref":"a"}}}"#)
        XCTAssertNil(try CoveWidgetEngine.apply(swap, state: &state))
        XCTAssertEqual(state, ["a": .number(2), "b": .number(1)])
        let snapshot = state
        XCTAssertThrowsError(try CoveWidgetEngine.apply(value(#"{"type":"set","values":{"a":9,"b":"bad"}}"#), state: &state))
        XCTAssertEqual(snapshot, state)
    }
    func testUnknownAndUnsafeFieldsFailClosed() throws {
        for root in [#"{"type":"HTML","props":{}}"#, #"{"type":"Text","props":{"text":"hello","html":"x"}}"#, #"{"type":"Text","props":{"text":"hello"},"children":[]}"#, #"{"type":"Text","props":{"text":"hello"},"visible":"true"}"#] {
            XCTAssertThrowsError(try document(root: root))
        }
        XCTAssertThrowsError(try document(root: #"{"type":"Text","props":{"text":"a"}}"#, extra: #", "extra":1"#))
        XCTAssertThrowsError(try CoveWidgetDocument.parse(#"{"version":2,"id":"x","state":{},"root":{"type":"Text","props":{"text":"x"}}}"#))
        XCTAssertThrowsError(try document(root: #"{"type":"Text","props":{"text":"a"}}"#, state: #"{"constructor":1}"#))
    }
    func testExpressionArithmeticAndErrors() throws {
        XCTAssertEqual(try CoveWidgetEngine.evaluate(value(#"{"op":"round","args":[{"op":"div","args":[9,2]}]}"#), state: [:]), .number(5))
        for expression in [#"{"op":"div","args":[1,0]}"#, #"{"op":"add","args":[true,1]}"#, #"{"op":"eval","args":["1+1"]}"#, #"{"ref":"missing"}"#, #"{"op":"mul","args":[1e308,1e308]}"#, #"{"op":"if","args":[true,1,{"ref":"missing"}]}"#, #"{"op":"if","args":[true,1,"two"]}"#] {
            XCTAssertThrowsError(try CoveWidgetEngine.evaluate(value(expression), state: [:]))
        }
    }
    func testSendNeedsExplicitApplyAndPreservesState() throws {
        var state: [String: CoveWidgetValue] = ["answer": .string("yes")]
        let snapshot = state
        XCTAssertEqual(try CoveWidgetEngine.apply(value(#"{"type":"send","text":{"ref":"answer"}}"#), state: &state), "yes")
        XCTAssertEqual(snapshot, state)
        XCTAssertThrowsError(try CoveWidgetEngine.apply(value(#"{"type":"send","text":"   "}"#), state: &state))
        XCTAssertThrowsError(try CoveWidgetEngine.apply(value(#"{"type":"send","text":1}"#), state: &state))
    }
    func testMediaURLPolicy() {
        XCTAssertTrue(CoveWidgetEngine.isAllowedMediaURL("https://example.com/photo.png"))
        for url in ["http://example.com/a", "file:///etc/passwd", "https://127.0.0.1/a", "https://[::1]/a", "https://localhost/a", "https://home.local/a", "https://user:pw@example.com/a", "https://example.com:8443/a", "https://12345678/a"] {
            XCTAssertFalse(CoveWidgetEngine.isAllowedMediaURL(url), url)
        }
    }
    func testDepthSizeAndNodeBounds() throws {
        var root = #"{"type":"Text","props":{"text":"end"}}"#
        for _ in 0..<12 { root = "{\"type\":\"Stack\",\"children\":[\(root)]}" }
        XCTAssertThrowsError(try document(root: root))
        let nodes = Array(repeating: #"{"type":"Text","props":{"text":"x"}}"#, count: 128).joined(separator: ",")
        XCTAssertThrowsError(try document(root: "{\"type\":\"Stack\",\"children\":[\(nodes)]}"))
        XCTAssertThrowsError(try CoveWidgetDocument.parse(String(repeating: " ", count: 65537)))
        var expression: CoveWidgetValue = .bool(true)
        for _ in 0..<18 { expression = .object(["op": .string("not"), "args": .array([expression])]) }
        XCTAssertThrowsError(try CoveWidgetEngine.evaluate(expression, state: [:]))
    }
    func testBindingsOptionsAndUniqueIDs() throws {
        XCTAssertThrowsError(try document(root: #"{"type":"Input","props":{"label":"x","bind":"n"}}"#, state: #"{"n":1}"#))
        XCTAssertThrowsError(try document(root: #"{"type":"Slider","props":{"label":"x","bind":"n","min":4,"max":2}}"#, state: #"{"n":1}"#))
        XCTAssertThrowsError(try document(root: #"{"type":"Choice","props":{"label":"x","bind":"s","options":[{"label":"A","value":"a"},{"label":"B","value":"a"}]}}"#, state: #"{"s":""}"#))
        XCTAssertThrowsError(try document(root: #"{"type":"Stack","children":[{"type":"Text","id":"same","props":{"text":"a"}},{"type":"Text","id":"same","props":{"text":"b"}}]}"#))
    }
    func testDuplicateJSONKeysAreRejectedInEveryScope() throws {
        for source in [
            #"{"version":1,"version":1,"id":"x","state":{},"root":{"type":"Text","props":{"text":"x"}}}"#,
            #"{"version":1,"id":"x","state":{},"root":{"type":"Text","props":{"text":"x","text":"y"}}}"#,
            #"{"version":1,"id":"x","state":{},"root":{"type":"Text","props":{"text":"x","te\u0078t":"y"}}}"#,
            #"{"version":1,"id":"x","state":{"a":1,"\u0061":2},"root":{"type":"Text","props":{"text":"x"}}}"#,
            #"{"version":1,"id":"x","state":{},"root":{"type":"Button","props":{"label":"Send","action":{"type":"send","type":"set","text":"x"}}}}"#
        ] { XCTAssertThrowsError(try CoveWidgetDocument.parse(source)) }
        XCTAssertNoThrow(try document(root: #"{"type":"Stack","children":[{"type":"Text","props":{"text":"one"}},{"type":"Text","props":{"text":"two"}}]}"#))
        XCTAssertNoThrow(try document(root: #"{"type":"Text","props":{"te\u0078t":"quotes: \" and backslash: \\"}}"#))
    }
    func testFullDocumentRevalidatesStateConstraints() throws {
        let doc = try document(root: #"{"type":"Stack","children":[{"type":"Input","props":{"label":"Name","bind":"s","maxLength":3}},{"type":"Slider","props":{"label":"Score","bind":"n","min":0,"max":10}}]}"#, state: #"{"s":"ok","n":5}"#)
        XCTAssertNoThrow(try doc.validate(state: ["s": .string("yes"), "n": .number(9)]))
        XCTAssertThrowsError(try doc.validate(state: ["s": .string("long"), "n": .number(9)]))
        XCTAssertThrowsError(try doc.validate(state: ["s": .string("yes"), "n": .number(11)]))
        XCTAssertThrowsError(try doc.validate(state: ["s": .string("yes"), "n": .number(1), "extra": .bool(true)]))
        let choice = try document(root: #"{"type":"Choice","props":{"label":"Pick","bind":"s","options":[{"label":"A","value":"a"}]}}"#, state: #"{"s":""}"#)
        XCTAssertNoThrow(try choice.validate(state: ["s": .string("a")]))
        XCTAssertThrowsError(try choice.validate(state: ["s": .string("b")]))
    }
    func testSendAllowsBoundedComputedText() throws {
        let fourK = CoveWidgetValue.string(String(repeating: "a", count: 4000))
        let computed = CoveWidgetValue.object(["op": .string("concat"), "args": .array([fourK, fourK])])
        var state: [String: CoveWidgetValue] = [:]
        XCTAssertEqual(try CoveWidgetEngine.apply(.object(["type": .string("send"), "text": computed]), state: &state)?.count, 8000)
        XCTAssertThrowsError(try CoveWidgetEngine.evaluate(.object(["op": .string("concat"), "args": .array([computed, .string("x")])]), state: [:]))
        XCTAssertThrowsError(try CoveWidgetEngine.evaluate(.string(String(repeating: "a", count: 4001)), state: [:]))
    }
    func testAllFourteenComponentsParse() throws {
        let root = #"{"type":"Stack","children":[{"type":"Grid","children":[{"type":"Card","children":[{"type":"Text","props":{"text":"Hello"}}]}]},{"type":"Button","props":{"label":"Next","action":{"type":"set","values":{"step":2}}}},{"type":"Input","props":{"label":"Name","bind":"name"}},{"type":"Slider","props":{"label":"Score","bind":"score","min":0,"max":10}},{"type":"Metric","props":{"label":"Score","value":{"ref":"score"}}},{"type":"Progress","props":{"value":{"ref":"score"}}},{"type":"Transition","props":{"key":{"ref":"step"}},"children":[]},{"type":"Choice","props":{"label":"Choice","bind":"name","options":[{"label":"A","value":"a"}]}},{"type":"Image","props":{"src":"https://example.com/a.png","alt":"A"}},{"type":"Disclosure","props":{"label":"More","bind":"open"},"children":[]},{"type":"Audio","props":{"src":"https://example.com/a.mp3","label":"Listen"}}]}"#
        let doc = try document(root: root, state: #"{"name":"","score":5,"step":1,"open":false}"#)
        XCTAssertEqual(doc.root.children.count, 11)
    }
}
