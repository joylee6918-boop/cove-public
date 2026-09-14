import XCTest
import UIKit
@testable import Cove

@MainActor
final class MarkdownHighlightTests: XCTestCase {
    func testCommonLanguagesHaveColoredTokensAndPreserveOriginalSource() throws {
        let examples = [
            ("swift", "let greeting = \"用户\"\nprint(greeting) // Cove"),
            ("python", "def greet(name):\n    return \"hello \" + name # Cove"),
            ("js", "const greeting = \"hello\"; // Cove\nconsole.log(greeting);"),
            ("html", "<article class=\"cove\"><h1>用户</h1></article>"),
            ("json", "{\"name\": \"Cove\", \"enabled\": true, \"count\": 7}"),
            ("bash", "#!/bin/bash\necho \"hello $USER\" # Cove")
        ]
        for dark in [false, true] {
            for (language, source) in examples {
                let result = try XCTUnwrap(MarkdownSyntaxHighlighting.highlighted(source, language: language, dark: dark), "Missing \(language) highlighting")
                XCTAssertEqual(result.string, source, "Highlighting must preserve exactly the copyable source.")
                var colors: Set<UIColor> = []
                result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, _, _ in
                    if let color = value as? UIColor { colors.insert(color) }
                }
                XCTAssertGreaterThan(colors.count, 1, "\(language) must include actual syntax coloring.")
                XCTAssertEqual(String(MarkdownSyntaxHighlighting.swiftUIText(result).characters), source)
            }
        }
    }

    func testUnknownLanguagesAndHugeBlocksUsePlainSourceFallback() {
        let source = "this is ordinary source <script>alert(1)</script>"
        XCTAssertNil(MarkdownSyntaxHighlighting.highlighted(source, language: "cove-unknown-language", dark: false))
        XCTAssertNil(MarkdownSyntaxHighlighting.highlighted(source, language: nil, dark: false))
        XCTAssertNil(MarkdownSyntaxHighlighting.highlighted(String(repeating: "a", count: 200_001), language: "swift", dark: false))
    }

    func testUnfinishedStreamingCodeAndHTMLAreDataNotExecutableMarkup() throws {
        let unfinished = "let name = \"用户"
        let result = try XCTUnwrap(MarkdownSyntaxHighlighting.highlighted(unfinished, language: "swift", dark: true))
        XCTAssertEqual(result.string, unfinished)
        let html = "<script>globalThis.coveExecuted = true</script><img src=\"https://example.com/a.png\" onerror=\"alert(1)\">"
        XCTAssertEqual(try XCTUnwrap(MarkdownSyntaxHighlighting.highlighted(html, language: "html", dark: false)).string, html)
    }
}
