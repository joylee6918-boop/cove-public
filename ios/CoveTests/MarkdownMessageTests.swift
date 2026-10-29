import XCTest
import MarkdownUI
@testable import Cove

final class MarkdownMessageTests: XCTestCase {
    func testPreparedMarkdownReusesBothParsesAndInvalidatesOnSourceChange() {
        let source = "**hello** inline ![image](https://example.com/test.png)"
        let first = CovePreparedMarkdown.cached(source)
        XCTAssertTrue(first === CovePreparedMarkdown.cached(source))
        XCTAssertEqual(first.content, MarkdownContent(source))
        XCTAssertEqual(first.images, MarkdownImageReferences.inline(in: source))
        let changed = CovePreparedMarkdown.cached(source + " new")
        XCTAssertFalse(first === changed)
        XCTAssertEqual(changed.content, MarkdownContent(source + " new"))
        XCTAssertTrue(CovePreparedMarkdown.cached("**no images**").images.isEmpty)
    }

    func testPlainHistoryFastPathDoesNotBypassMarkdownSyntax() {
        XCTAssertTrue(MarkdownPlainText.isPlain("历史示例 600\n这是用于验证长对话滚动的示例消息。"))
        for source in ["# 标题", "**粗体**", "1. 列表", "1) 列表", "a &amp; b", "- 项目", "文本\n---", "文本\n===", "前 ![图](https://example.com/a.png)", "https://example.com", "<b>HTML</b>", "    code", "段落\n\n段落", "换行  \n文本", "hello@example.com", "表 | 格"] {
            XCTAssertFalse(MarkdownPlainText.isPlain(source), source)
        }
    }

    func testGFMEngineRetainsRequestedBlockAndInlineSyntax() {
        let source = """
        # 标题

        一段 **粗体**、*斜体*、~~删除线~~、`代码` 与 [链接](https://example.com)。

        > 引用

        - 外层
          - 内层
        - [x] 已完成
        - [ ] 未完成

        1. 顺序
        2. 列表

        ---

        | 项目 | 数值 |
        | --- | --- |
        | 睡眠 | 7.4 |

        ```swift
        print("Cove")
        ```
        """
        let html = MarkdownContent(source).renderHTML()
        for token in ["<h1>", "<strong>", "<em>", "<del>", "<code>", "<a href=", "<blockquote>", "<ul>", "<ol>", "<hr", "<table>", "type=\"checkbox\"", "language-swift"] {
            XCTAssertTrue(html.contains(token), "Missing GFM output: \(token)")
        }
        XCTAssertTrue(MarkdownContent("```swift\nlet unfinished = 1").renderHTML().contains("language-swift"), "An unfinished streaming fence must remain a code block.")
    }

    func testMixedAndNestedReferenceImagesHaveConsentControls() {
        let source = """
        开始 ![海湾](https://example.com/bay.png) 结束。
        **嵌套 ![晚灯][lamp]**

        [lamp]: https://example.com/lamp.png
        """
        XCTAssertEqual(MarkdownImageReferences.inline(in: source), [
            .init(source: "https://example.com/bay.png", label: "海湾"),
            .init(source: "https://example.com/lamp.png", label: "晚灯")
        ])
    }

    func testFencedCodeAndRawHTMLNeverBecomeImageRequests() {
        let source = """
        ```markdown
        ![secret](https://example.com/code.png)
        ```

        <img src="https://example.com/html.png" onerror="alert(1)">

        `![inline code](https://example.com/inline.png)`
        """
        XCTAssertTrue(MarkdownImageReferences.inline(in: source).isEmpty)
        XCTAssertTrue(MarkdownImageReferences.inline(in: "```markdown\n![unclosed](https://example.com/unclosed.png)").isEmpty)
    }

    func testStandaloneImagesStayInPlaceAndMixedTableImagesGetControls() {
        let source = """
        ![独立图片](https://example.com/block.png)

        > ![引用图片](https://example.com/quote.png)

        | 单独图片 | 混合图片 |
        | --- | --- |
        | ![a](https://example.com/cell.png) | 前 ![b](https://example.com/mixed.png) 后 |
        """
        XCTAssertEqual(MarkdownImageReferences.inline(in: source), [
            .init(source: "https://example.com/mixed.png", label: "b")
        ])
    }

    func testConsentReferencesAreDeduplicatedAndUnsafeDestinationsRejected() {
        let source = "前 ![a](https://example.com/a.png) 后 ![a](https://example.com/a.png) ![b](file:///private/image.png)"
        XCTAssertEqual(MarkdownImageReferences.inline(in: source).count, 1)
        for value in ["file:///tmp/a", "data:image/png;base64,a", "javascript:alert(1)", "https://user:password@example.com/a"] {
            XCTAssertFalse(MarkdownImageReferences.permitsImage(URL(string: value)!))
        }
        XCTAssertTrue(MarkdownImageReferences.permitsImage(URL(string: "https://example.com/a.png")!))
        XCTAssertFalse(MarkdownImageReferences.permitsLink(URL(string: "javascript:alert(1)")!))
    }
}
