import Foundation
import CryptoKit
import cmark_gfm

/// Index only real, explicitly closed top-level fences. MarkdownUI still owns
/// all Markdown layout: this is eligibility/identity, not a second renderer.
final class CoveWidgetMarkdownIndex {
    enum Entry {
        case widget(CoveWidgetDocument)
        case invalid(String)
    }
    private(set) var entries: [String: Entry] = [:]

    static func normalized(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(_ source: String) {
        guard source.utf8.count <= 512 * 1024, source.contains("widget") else { return }
        let source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let document = cmark_parse_document(source, source.utf8.count, CMARK_OPT_DEFAULT) else { return }
        defer { cmark_node_free(document) }
        let lines = source.components(separatedBy: .newlines)
        // MarkdownUI's styling callback carries content, not source positions.
        // Never let an identical nested/example block borrow a live block's identity.
        var occurrences: [String: Int] = [:]
        var nodes = [document]
        while let node = nodes.popLast() {
            if cmark_node_get_type_string(node).map({ String(cString: $0) }) == "code_block",
               cmark_node_get_fence_info(node).map({ String(cString: $0).split(whereSeparator: { $0.isWhitespace }).first == "widget" }) == true,
               let literal = cmark_node_get_literal(node) {
                occurrences[Self.normalized(String(cString: literal)), default: 0] += 1
            }
            var child = cmark_node_first_child(node)
            while let next = child { nodes.append(next); child = cmark_node_next(next) }
        }
        var candidate = cmark_node_first_child(document)
        var ids: [String: [String]] = [:]
        var count = 0
        while let node = candidate {
            candidate = cmark_node_next(node)
            guard cmark_node_get_type_string(node).map({ String(cString: $0) }) == "code_block",
                  cmark_node_get_fence_info(node).map({ String(cString: $0) }) == "widget",
                  let literal = cmark_node_get_literal(node) else { continue }
            count += 1
            guard count <= 8 else {
                entries = entries.mapValues { _ in .invalid("同一条消息最多包含 8 张卡片。") }
                return
            }
            let body = String(cString: literal)
            let key = Self.normalized(body)
            var length: Int32 = 0
            var offset: Int32 = 0
            var character: CChar = 0
            let end = Int(cmark_node_get_end_line(node)) - 1
            guard cmark_node_get_fenced(node, &length, &offset, &character) != 0,
                  end >= 0, end < lines.count,
                  cmark_node_get_end_line(node) > cmark_node_get_start_line(node) else {
                entries[key] = .invalid("卡片代码块尚未闭合。")
                continue
            }
            let closing = lines[end].trimmingCharacters(in: .whitespaces)
            let fence = Character(UnicodeScalar(UInt8(bitPattern: character)))
            guard closing.count >= Int(length), closing.allSatisfy({ $0 == fence }) else {
                entries[key] = .invalid("卡片代码块尚未闭合。")
                continue
            }
            do {
                let widget = try CoveWidgetDocument.parse(body)
                ids[widget.id, default: []].append(key)
                entries[key] = .widget(widget)
            } catch {
                entries[key] = .invalid(error.localizedDescription)
            }
        }
        for (_, keys) in ids where keys.count > 1 {
            for key in keys { entries[key] = .invalid("同一条消息中的卡片 id 必须唯一。") }
        }
        for (key, count) in occurrences where count > 1 && entries[key] != nil {
            entries[key] = .invalid("重复的卡片代码块不能共享交互状态。")
        }
    }

    func entry(for content: String) -> Entry? { entries[Self.normalized(content)] }
}
