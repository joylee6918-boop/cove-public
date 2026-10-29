import SwiftUI
import AVFoundation
import ImageIO
import Darwin

/// Volatile drafts only: scoped by conversation/message/block/source, never uploaded on edit.
@MainActor
final class CoveWidgetSession: ObservableObject {
    @Published var state: [String: CoveWidgetValue]
    @Published var submitted = false
    @Published var error: String?
    init(state: [String: CoveWidgetValue]) { self.state = state }
    private static var cache: [String: CoveWidgetSession] = [:]
    private static var order: [String] = []
    static func session(key: String, initial: [String: CoveWidgetValue]) -> CoveWidgetSession {
        if let existing = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            return existing
        }
        let value = CoveWidgetSession(state: initial)
        cache[key] = value; order.append(key)
        while order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        return value
    }
}

struct CoveWidgetView: View {
    let document: CoveWidgetDocument
    let onSend: (String) throws -> Void
    @StateObject private var session: CoveWidgetSession
    @State private var preview: WidgetSendPreview?

    init(document: CoveWidgetDocument, contextKey: String, onSend: @escaping (String) throws -> Void) {
        self.document = document
        self.onSend = onSend
        _session = StateObject(wrappedValue: CoveWidgetSession.session(key: contextKey, initial: document.state))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI 互动卡片", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold)).foregroundStyle(CoveStyle.secondaryText)
                .accessibilityElement(children: .ignore).accessibilityLabel("AI 互动卡片")
            CoveWidgetNodeView(node: document.root, session: session, validate: { try document.validate(state: $0) }, send: { preview = WidgetSendPreview(text: $0) })
            Text(session.submitted ? "已加入发送队列；实际发送状态请看对话。" : "填写和选择仅保留在此卡片，点击发送并确认后才会发到对话。")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                .accessibilityIdentifier(session.submitted ? "widget.submitted" : "widget.local.note")
            if let error = session.error { Text(error).font(.caption).foregroundStyle(CoveStyle.error) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CoveStyle.border, lineWidth: 1))
        .tint(CoveStyle.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("widget.card")
        .sheet(item: $preview) { snapshot in
            NavigationStack {
                ScrollView { Text(snapshot.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("widget.send.preview") }
                    .navigationTitle("确认发送内容")
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 12) {
                            Text("以下内容将作为你的消息发送到当前对话。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("发送到对话") {
                                guard !session.submitted else { return }
                                do {
                                    try onSend(snapshot.text)
                                    session.submitted = true
                                    session.error = nil
                                } catch { session.error = "未能加入发送队列：\(error.localizedDescription)" }
                                preview = nil
                            }.buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(session.submitted).accessibilityIdentifier("widget.send.confirm")
                        }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { preview = nil }.accessibilityIdentifier("widget.send.cancel") } }
            }
        }
    }
}

private struct WidgetSendPreview: Identifiable { let id = UUID(); let text: String }

private struct CoveWidgetNodeView: View {
    let node: CoveWidgetNode
    @ObservedObject var session: CoveWidgetSession
    let validate: ([String: CoveWidgetValue]) throws -> Void
    let send: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var submittedExpanded: Bool?

    private func value(_ key: String) -> CoveWidgetValue? {
        guard let expression = node.props[key] else { return nil }
        return try? CoveWidgetEngine.evaluate(expression, state: session.state)
    }
    private func text(_ key: String, fallback: String = "") -> String {
        guard let value = value(key) else { return fallback }
        if let string = value.stringValue { return string }
        if let number = value.numberValue { return number.formatted(.number.precision(.fractionLength(0...4))) }
        if let bool = value.boolValue { return bool ? "是" : "否" }
        return fallback
    }
    private func number(_ key: String, fallback: Double) -> Double { value(key)?.numberValue ?? fallback }
    private func update(_ newState: [String: CoveWidgetValue]) {
        guard !session.submitted else { return }
        do { try validate(newState); session.state = newState; session.error = nil }
        catch { session.error = "此修改会使卡片计算无效，已保留上一个值：\(error.localizedDescription)" }
    }
    private func update(_ key: String, _ value: CoveWidgetValue) {
        var next = session.state; next[key] = value; update(next)
    }
    private var bindingKey: String { node.props["bind"]?.stringValue ?? "" }
    private var stringBinding: Binding<String> {
        Binding(get: { session.state[bindingKey]?.stringValue ?? "" }, set: { newValue in
            let maxLength = max(1, Int(number("maxLength", fallback: 1000)))
            update(bindingKey, .string(String(newValue.prefix(maxLength))))
        })
    }
    private var numericBinding: Binding<Double> {
        Binding(get: { session.state[bindingKey]?.numberValue ?? number("min", fallback: 0) },
                set: { update(bindingKey, .number($0)) })
    }
    private var disclosureBinding: Binding<Bool> {
        guard !bindingKey.isEmpty else { return $expanded }
        return Binding(get: { session.submitted ? (submittedExpanded ?? session.state[bindingKey]?.boolValue ?? false) : (session.state[bindingKey]?.boolValue ?? false) }, set: {
            if session.submitted { submittedExpanded = $0 } else { update(bindingKey, .bool($0)) }
        })
    }
    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            CoveWidgetNodeView(node: child, session: session, validate: validate, send: send)
        }
    }
    private var spacing: CGFloat { CGFloat(number("spacing", fallback: 12)) }

    var body: some View {
        Group {
            if node.visible == nil || (try? CoveWidgetEngine.evaluate(node.visible!, state: session.state).boolValue) == true {
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch node.type {
        case "Text":
            Text(text("text")).font(text("style") == "title" ? .headline : text("style") == "caption" ? .caption : .body)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        case "Stack":
            if text("axis") == "horizontal" && !dynamicType.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: spacing) { children }
                    VStack(alignment: .leading, spacing: spacing) { children }
                }
            } else { VStack(alignment: .leading, spacing: spacing) { children } }
        case "Grid":
            let count = dynamicType.isAccessibilitySize ? 1 : max(1, min(3, Int(number("columns", fallback: 2))))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .topLeading), count: count), alignment: .leading, spacing: spacing) { children }
        case "Card":
            VStack(alignment: .leading, spacing: 10) {
                if !text("title").isEmpty { Text(text("title")).font(.headline) }
                children
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(CoveStyle.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        case "Button":
            let isSend = node.props["action"]?.objectValue?["type"]?.stringValue == "send"
            Button {
                guard let action = node.props["action"] else { return }
                do {
                    var state = session.state
                    let outgoing = try CoveWidgetEngine.apply(action, state: &state)
                    if let outgoing { try validate(session.state); send(outgoing); session.error = nil } else { update(state) }
                } catch { session.error = "卡片操作失败：\(error.localizedDescription)" }
            } label: {
                VStack(spacing: 3) {
                    Text(isSend ? "发送到对话" : text("label", fallback: "继续"))
                    if isSend && !text("label").isEmpty && text("label") != "发送到对话" { Text(text("label")).font(.caption) }
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered)
                .disabled(value("disabled")?.boolValue == true || session.submitted)
                .accessibilityIdentifier("widget.button.\(node.id ?? text("label"))")
        case "Input":
            VStack(alignment: .leading, spacing: 6) {
                Text(text("label")).font(.subheadline)
                TextField(text("placeholder"), text: stringBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...6).frame(minHeight: 44)
                    .accessibilityLabel(text("label")).disabled(session.submitted)
                    .accessibilityIdentifier("widget.input.\(bindingKey)")
            }
        case "Slider":
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(text("label")); Spacer(); Text(numericBinding.wrappedValue.formatted(.number.precision(.fractionLength(0...3)))).monospacedDigit() }
                Slider(value: numericBinding, in: number("min", fallback: 0)...number("max", fallback: 100), step: number("step", fallback: 1))
                    .frame(minHeight: 44).accessibilityLabel(text("label")).disabled(session.submitted)
                    .accessibilityIdentifier("widget.slider.\(bindingKey)")
            }
        case "Metric":
            VStack(alignment: .leading, spacing: 4) {
                Text(text("label")).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                Text(text("value") + (text("unit").isEmpty ? "" : " " + text("unit"))).font(.title2.weight(.semibold)).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading)
        case "Progress":
            ProgressView(value: max(0, min(number("value", fallback: 0), number("total", fallback: 100))), total: number("total", fallback: 100)) { Text(text("label")) }
        case "Transition":
            VStack(alignment: .leading, spacing: 10) { children }
                .id(text("key"))
                .transition(reduceMotion ? .identity : text("style") == "slide" ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.state)
        case "Choice":
            VStack(alignment: .leading, spacing: 4) {
                Text(text("label")).font(.subheadline)
                ForEach(Array((node.props["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, option in
                    if let fields = option.objectValue, let label = fields["label"]?.stringValue, let selection = fields["value"]?.stringValue {
                        Button { update(bindingKey, .string(selection)) } label: {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: stringBinding.wrappedValue == selection ? "largecircle.fill.circle" : "circle")
                                    .accessibilityHidden(true)
                                Text(label).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(stringBinding.wrappedValue == selection ? .isSelected : [])
                            .disabled(session.submitted).accessibilityIdentifier("widget.choice.\(selection)")
                    }
                }
            }
        case "Image":
            CoveWidgetRemoteMedia(source: text("src"), label: text("alt", fallback: "卡片图片"), isAudio: false)
        case "Disclosure":
            DisclosureGroup(isExpanded: disclosureBinding) { VStack(alignment: .leading, spacing: 10) { children } } label: {
                Text(text("label")).frame(minHeight: 44)
            }
        case "Audio":
            CoveWidgetRemoteMedia(source: text("src"), label: text("label", fallback: "卡片音频"), isAudio: true)
        default:
            Text("不支持的卡片组件").font(.caption).foregroundStyle(CoveStyle.error)
        }
    }
}

/// No redirects, cookies, persistent cache or automatic loading. Never opens a URL externally.
private final class WidgetMediaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Preflight blocks private/reserved DNS answers as well as literal local hosts.
/// URLSession still owns TLS hostname verification; redirect responses are never followed.
enum WidgetMediaHostPolicy {
    static func permitsURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), host.contains("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), host.contains(where: { $0.isLetter }), host != "localhost" else { return false }
        return true
    }

    static func hasOnlyPublicAddresses(_ host: String) -> Bool {
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let item = cursor {
            defer { cursor = item.pointee.ai_next }
            guard let address = item.pointee.ai_addr else { return false }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return false }
            let numeric = String(cString: buffer).lowercased()
            if item.pointee.ai_family == AF_INET {
                let octets = numeric.split(separator: ".").compactMap { Int($0) }
                guard octets.count == 4 else { return false }
                let a = octets[0], b = octets[1], c = octets[2]
                guard a != 0, a != 10, a != 127, a < 224,
                      !(a == 100 && (64...127).contains(b)), !(a == 169 && b == 254),
                      !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168),
                      !(a == 192 && b == 0), !(a == 192 && b == 88 && c == 99),
                      !(a == 198 && (b == 18 || b == 19)), !(a == 198 && b == 51 && c == 100),
                      !(a == 203 && b == 0 && c == 113) else { return false }
            } else if item.pointee.ai_family == AF_INET6 {
                // Only global-unicast 2000::/3; reject documentation/special transition ranges.
                guard let firstPart = numeric.split(separator: ":").first,
                      let prefix = UInt16(firstPart, radix: 16), (0x2000...0x3fff).contains(prefix),
                      !numeric.hasPrefix("2001:"), !numeric.hasPrefix("2002:") else { return false }
            } else { continue }
            found = true
        }
        return found
    }
}

private struct CoveWidgetRemoteMedia: View {
    let source: String
    let label: String
    let isAudio: Bool
    @State private var image: UIImage?
    @State private var player: AVAudioPlayer?
    @State private var loading = false
    @State private var failure: String?
    @State private var attempt: UUID?
    @State private var playing = false
    private var url: URL? { URL(string: source) }
    private var allowed: Bool { url.map(WidgetMediaHostPolicy.permitsURL) ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).accessibilityLabel(label) }
            else if let player {
                Button {
                    if player.isPlaying { player.pause(); playing = false }
                    else { playing = player.play() }
                } label: { Label(playing ? "暂停：\(label)" : "播放：\(label)", systemImage: playing ? "pause.circle" : "play.circle").frame(minHeight: 44) }
            } else {
                Button { attempt = UUID() } label: {
                    HStack {
                        if loading { ProgressView() }
                        Label("点击加载\(isAudio ? "音频" : "图片")：\(label)", systemImage: isAudio ? "waveform" : "photo")
                    }.frame(minHeight: 44)
                }.disabled(loading || !allowed)
                Text("加载会连接 \(url?.host ?? "无效地址")；不会自动播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(CoveStyle.error) }
        }
        .task(id: attempt) {
            guard attempt != nil, allowed, let url else { return }
            loading = true; failure = nil
            defer { loading = false }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration, delegate: WidgetMediaRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let host = url.host ?? ""
                let publicAddresses = await Task.detached(priority: .utility) { WidgetMediaHostPolicy.hasOnlyPublicAddresses(host) }.value
                try Task.checkCancellation()
                guard publicAddresses else { throw URLError(.unsupportedURL) }
                let (bytes, response) = try await session.bytes(from: url)
                let limit = 8 * 1024 * 1024
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      response.expectedContentLength <= limit,
                      response.mimeType?.lowercased().hasPrefix(isAudio ? "audio/" : "image/") == true else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                try Task.checkCancellation()
                if isAudio {
                    let loaded = try AVAudioPlayer(data: data)
                    guard loaded.duration.isFinite, loaded.duration <= 600 else { throw URLError(.dataLengthExceedsMaximum) }
                    player = loaded // prepare/play only after a separate explicit tap.
                } else {
                    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          width.doubleValue > 0, height.doubleValue > 0,
                          width.doubleValue * height.doubleValue <= 20_000_000,
                          let loaded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                    image = loaded
                }
            } catch is CancellationError { return }
            catch { failure = "加载失败，请检查地址或稍后重试。" }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if playing, player?.isPlaying != true { playing = false }
        }
        .onDisappear { player?.stop(); playing = false }
        .onChange(of: source) { _, _ in player?.stop(); player = nil; image = nil; attempt = nil; playing = false; failure = nil }
    }
}
