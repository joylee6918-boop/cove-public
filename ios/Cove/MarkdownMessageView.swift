import SwiftUI
import MarkdownUI
import Highlighter
import ImageIO
import cmark_gfm
import cmark_gfm_extensions

/// GFM stays in MarkdownUI; Cove customizes only presentation and image consent.
struct MarkdownMessageView: View {
    let text: String
    var id: String? = nil
    var searchQuery: String = ""
    var allowsLocationCard = false
    var widgetContext: String? = nil
    var onWidgetSend: ((String, String) throws -> Void)? = nil

    @ViewBuilder var body: some View {
        if !searchQuery.isEmpty {
            // Search mode reveals the literal stored body, including code/markup
            // matches. Clearing the located highlight restores normal GFM layout.
            Text(CoveSearchHighlight.text(text, query: searchQuery))
                .font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } else if allowsLocationCard, let location = SharedLocation.parse(text) {
            SharedLocationCard(location: location)
        } else if MarkdownPlainText.isPlain(text) {
            // Preserve Text's intrinsic height and accessibility for the common
            // history row, without MarkdownUI's block-margin preference layout.
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            richBody
        }
    }

    private var richBody: some View {
        let prepared = CovePreparedMarkdown.cached(text)
        return VStack(alignment: .leading, spacing: 6) {
            Markdown(prepared.content)
                .markdownTheme(Self.theme.codeBlock { configuration in
                    codeBlock(content: configuration.content, language: configuration.language, prepared: prepared)
                        .markdownMargin(top: 4, bottom: 10)
                })
                .markdownBlockStyle(\.paragraph) { configuration in
                    Self.paragraph(configuration)
                        .accessibilityIdentifier(id.map { "chat.message.\($0)" } ?? "markdown.paragraph")
                }
                .markdownSoftBreakMode(.lineBreak)
                .markdownImageProvider(ConsentMarkdownImageProvider())
                .markdownInlineImageProvider(NoNetworkInlineImageProvider())
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard MarkdownImageReferences.permitsLink(url) else { return .discarded }
                    return .systemAction(url)
                })
            // SwiftUI Text cannot host an inline button. Mixed-text images get an
            // explicit control below the body; image-only paragraphs stay in place.
            ForEach(prepared.images) { reference in
                VStack(alignment: .leading, spacing: 6) {
                    if !reference.label.isEmpty {
                        Text(reference.label).font(.caption).foregroundStyle(.secondary)
                    }
                    ConsentMarkdownImage(url: URL(string: reference.source))
                }
            }
        }
        .tint(Self.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id.map { "chat.message.\($0)" } ?? "markdown.message")
    }

    private static let accent = CoveStyle.accentText

    @ViewBuilder private func codeBlock(content: String, language: String?, prepared: CovePreparedMarkdown) -> some View {
        if language == "widget", let widgetContext, let onWidgetSend {
            switch prepared.widgets.entry(for: content) {
            case .widget(let document):
                let key = document.id + ":" + CoveWidgetMarkdownIndex.digest(content)
                CoveWidgetView(document: document, contextKey: widgetContext + ":" + key) { text in
                    try onWidgetSend(text, key)
                }
                .id(widgetContext + ":" + key)
            case .invalid(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Label("卡片无法显示", systemImage: "exclamationmark.triangle").font(.subheadline)
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("查看卡片源码") { MarkdownCodeBlock(content: content, language: "json") }
                }
                .accessibilityIdentifier("widget.invalid")
            case nil:
                MarkdownCodeBlock(content: content, language: language)
            }
        } else {
            MarkdownCodeBlock(content: content, language: language)
        }
    }

    private static let theme = MarkdownUI.Theme.basic
        .text { FontSize(17); ForegroundColor(.primary) }
        .link { ForegroundColor(accent); UnderlineStyle(.single) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color(uiColor: .tertiarySystemFill))
        }
        .heading1 { heading($0, size: 1.2) }
        .heading2 { heading($0, size: 1.12) }
        .heading3 { heading($0, size: 1.06) }
        .heading4 { heading($0, size: 1.05) }
        .heading5 { heading($0, size: 1) }
        .heading6 { heading($0, size: 1) }
        .paragraph { paragraph($0) }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.65)).frame(width: 3)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
        .listItem { $0.label.markdownMargin(top: 3, bottom: 3) }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .foregroundStyle(accent)
                .relativeFrame(minWidth: .em(1.4), alignment: .trailing)
                .accessibilityLabel(configuration.isCompleted ? "已完成" : "未完成")
        }
        .codeBlock { configuration in
            MarkdownCodeBlock(content: configuration.content, language: configuration.language)
                .markdownMargin(top: 4, bottom: 10)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(color: Color(uiColor: .separator), width: 0.5))
                    .markdownTableBackgroundStyle(.alternatingRows(.clear, Color(uiColor: .tertiarySystemFill)))
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .markdownMargin(top: 4, bottom: 10)
            .accessibilityIdentifier("markdown.table")
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                    FontSize(.em(0.9))
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .thematicBreak { Divider().markdownMargin(top: 10, bottom: 10) }

    private static func heading(_ configuration: BlockConfiguration, size: CGFloat) -> some View {
        configuration.label
            .markdownTextStyle { FontWeight(.semibold); FontSize(.em(size)) }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 6, bottom: 4)
    }

    private static func paragraph(_ configuration: BlockConfiguration) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.04))
            .markdownMargin(top: 0, bottom: 5)
    }
}

/// Immutable parse artifacts, keyed by the exact source (not message identity).
/// Unlike State(initialValue: MarkdownContent(...)), cache hits do not reparse
/// when unrelated store/keyboard updates reinitialize a message view.
final class CovePreparedMarkdown {
    let content: MarkdownContent
    let images: [MarkdownImageReference]
    let widgets: CoveWidgetMarkdownIndex
    private static let cache: NSCache<NSString, CovePreparedMarkdown> = {
        let cache = NSCache<NSString, CovePreparedMarkdown>()
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private init(_ source: String) {
        content = MarkdownContent(source)
        widgets = CoveWidgetMarkdownIndex(source)
        images = source.contains("!") ? MarkdownImageReferences.inline(in: source) : []
    }

    static func cached(_ source: String) -> CovePreparedMarkdown {
        let key = source as NSString
        if let value = cache.object(forKey: key) { return value }
        let value = CovePreparedMarkdown(source)
        cache.setObject(value, forKey: key, cost: source.utf8.count)
        return value
    }
}

/// A deliberately conservative fast path. Any possible Markdown marker,
/// indentation or autolink delegates to the full GFM engine.
enum MarkdownPlainText {
    static func isPlain(_ source: String) -> Bool {
        guard !source.isEmpty,
              source.rangeOfCharacter(from: CharacterSet(charactersIn: "\\`*_{}[]<>()&#+.!|~-=@")) == nil,
              !source.contains("://"), !source.contains("\n\n"),
              !source.hasPrefix("    "), !source.hasPrefix("\t"),
              !source.contains("\n    "), !source.contains("\n\t"),
              !source.contains("  \n") else { return false }
        return true
    }
}

private struct MarkdownCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: String
    let language: String?
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @State private var copiedContent: String?
    @State private var highlightedContent = ""
    @State private var highlightedText: AttributedString?
    private var request: MarkdownHighlightRequest {
        .init(content: content, language: language, dark: colorScheme == .dark)
    }
    private var displayedCode: AttributedString {
        guard let highlightedText else { return AttributedString(content) }
        if content == highlightedContent { return highlightedText }
        if content.hasPrefix(highlightedContent) {
            var result = highlightedText
            result.append(AttributedString(String(content.dropFirst(highlightedContent.count))))
            return result
        }
        return AttributedString(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "代码")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = content
                    copiedContent = content
                } label: {
                    Label(copiedContent == content ? "已复制" : "复制", systemImage: copiedContent == content ? "checkmark" : "doc.on.doc")
                        .font(.caption).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("markdown.code.copy")
            }.padding(.horizontal, 12)
            Divider()
            ScrollView(.horizontal) {
                Text(displayedCode)
                    .font(.system(size: fontSize, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
            }.accessibilityIdentifier("markdown.code.scroll")
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: request) {
            // Coalesce stream fragments without removing the already visible code.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            let current = request
            let result = MarkdownSyntaxHighlighting.highlighted(current.content, language: current.language, dark: current.dark)
            guard !Task.isCancelled else { return }
            highlightedText = result.map(MarkdownSyntaxHighlighting.swiftUIText)
            highlightedContent = current.content
        }
    }
}

private struct MarkdownHighlightRequest: Hashable {
    let content: String
    let language: String?
    let dark: Bool
}

/// The only evaluated script is Highlighter's fixed bundled highlight.js.
/// User code is passed as a JSValue argument, never evaluated as JavaScript/HTML.
@MainActor
enum MarkdownSyntaxHighlighting {
    private static let light = makeHighlighter(theme: "a11y-light")
    private static let dark = makeHighlighter(theme: "a11y-dark")
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 16
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func highlighted(_ source: String, language: String?, dark isDark: Bool) -> NSAttributedString? {
        // ponytail: bound tokenization work for large streaming blocks; all source
        // remains visible and copyable even when syntax coloring is skipped.
        guard source.utf8.count <= 200_000,
              let name = language?.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              let engine = isDark ? dark : light else { return nil }
        let aliases = ["js": "javascript", "ts": "typescript", "py": "python", "sh": "bash", "shell": "bash", "html": "xml", "zsh": "bash", "yml": "yaml", "c++": "cpp", "c#": "csharp"]
        let canonical = aliases[name] ?? name
        guard engine.supportedLanguages().contains(canonical) else { return nil }
        let key = "\(isDark)-\(canonical)\u{0}\(source)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let value = engine.highlight(source, as: canonical, doFastRender: true), value.string == source else { return nil }
        cache.setObject(value, forKey: key, cost: source.utf8.count)
        return value
    }

    private static func makeHighlighter(theme: String) -> Highlighter? {
        guard let engine = Highlighter(), engine.setTheme(theme) else { return nil }
        engine.ignoreIllegals = true
        return engine
    }

    static func swiftUIText(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        source.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            var run = AttributedString((source.string as NSString).substring(with: range))
            if let color = value as? UIColor { run.foregroundColor = Color(uiColor: color) }
            result.append(run)
        }
        return result
    }
}

private struct ConsentMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { ConsentMarkdownImage(url: url) }
}

/// This provider intentionally contains no network operation, including before
/// a mixed-text image's separate consent control has been tapped.
struct NoNetworkInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}

private struct ConsentMarkdownImage: View {
    let url: URL?
    @State private var requestedURL: String?
    @State private var loadAttempt: UUID?
    @State private var loadedURL: String?
    @State private var failedURL: String?
    @State private var image: UIImage?
    @State private var loading = false
    private var source: String { url?.absoluteString ?? "" }

    var body: some View {
        Group {
            if loadedURL == source, let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("已加载的正文图片")
            } else {
                Button {
                    guard let url, MarkdownImageReferences.permitsImage(url) else { return }
                    requestedURL = source
                    failedURL = nil
                    loadAttempt = UUID()
                } label: {
                    VStack(spacing: 8) {
                        if loading && requestedURL == source { ProgressView() }
                        else { Image(systemName: "photo").font(.title2) }
                        Text(failedURL == source ? "图片未能加载" : "点击加载正文图片").font(.subheadline)
                        Text(url?.host ?? "图片地址不可用").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("加载时会连接图片所在网站").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(loading || url.map { !MarkdownImageReferences.permitsImage($0) } ?? true)
                .accessibilityIdentifier("markdown.image.load")
            }
        }
        .frame(maxWidth: .infinity).frame(height: 180)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: loadAttempt) {
            guard let url, requestedURL == source, loadedURL != source, failedURL != source,
                  MarkdownImageReferences.permitsImage(url) else { return }
            let expectedSource = source
            loading = true
            defer { loading = false }
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 30
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (bytes, response) = try await session.bytes(from: url)
                let limit = 8 * 1024 * 1024
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode), response.expectedContentLength <= limit,
                      response.mimeType?.lowercased().hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                try Task.checkCancellation()
                guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue * height.doubleValue <= 20_000_000,
                      let loaded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                image = loaded
                loadedURL = expectedSource
            } catch is CancellationError {
                return
            } catch {
                failedURL = expectedSource
            }
        }
    }
}

struct MarkdownImageReference: Identifiable, Equatable {
    let source: String
    let label: String
    var id: String { source }
}

/// Reads GFM image nodes, never image-looking strings inside fenced code or HTML.
enum MarkdownImageReferences {
    static func permitsImage(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    static func permitsLink(_ url: URL) -> Bool {
        ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "")
    }

    static func inline(in source: String) -> [MarkdownImageReference] {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(document) }
        var result: [MarkdownImageReference] = []
        var seen: Set<String> = []
        var nodes: [UnsafeMutablePointer<cmark_node>] = [document]
        while let node = nodes.popLast() {
            var children: [UnsafeMutablePointer<cmark_node>] = []
            var child = cmark_node_first_child(node)
            while let current = child { children.append(current); child = cmark_node_next(current) }
            nodes.append(contentsOf: children.reversed())
            guard nodeType(node) == "image", let raw = cmark_node_get_url(node) else { continue }
            let destination = String(cString: raw)
            guard let url = URL(string: destination), permitsImage(url), !isBlockImage(node), seen.insert(destination).inserted else { continue }
            result.append(.init(source: destination, label: plainLabel(node)))
        }
        return result
    }

    private static func nodeType(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
    }

    private static func isBlockImage(_ image: UnsafeMutablePointer<cmark_node>) -> Bool {
        var parent = cmark_node_parent(image)
        while let node = parent {
            let type = nodeType(node)
            if type == "paragraph" || type == "table_cell" { return imageOnlyChildren(node) }
            if type == "heading" { return false }
            parent = cmark_node_parent(node)
        }
        return false
    }

    private static func imageOnlyChildren(_ node: UnsafeMutablePointer<cmark_node>) -> Bool {
        var child = cmark_node_first_child(node)
        while let current = child {
            switch nodeType(current) {
            case "image", "softbreak", "linebreak": break
            case "text":
                if cmark_node_get_literal(current).map({ !String(cString: $0).isEmpty }) == true { return false }
            case "link":
                guard let onlyChild = cmark_node_first_child(current), nodeType(onlyChild) == "image", cmark_node_next(onlyChild) == nil else { return false }
            default: return false
            }
            child = cmark_node_next(current)
        }
        return true
    }

    private static func plainLabel(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        var label = ""
        var nodes = [node]
        while let current = nodes.popLast() {
            if let literal = cmark_node_get_literal(current) { label += String(cString: literal) }
            var children: [UnsafeMutablePointer<cmark_node>] = []
            var child = cmark_node_first_child(current)
            while let next = child { children.append(next); child = cmark_node_next(next) }
            nodes.append(contentsOf: children.reversed())
        }
        return label
    }
}
