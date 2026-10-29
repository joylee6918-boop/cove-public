import Foundation

/// Deliberately data-only: no JavaScript, interpolation, file access or automatic sends.
indirect enum CoveWidgetValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([CoveWidgetValue]), object([String: CoveWidgetValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([CoveWidgetValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CoveWidgetValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var objectValue: [String: CoveWidgetValue]? { if case .object(let v) = self { return v }; return nil }
    var arrayValue: [CoveWidgetValue]? { if case .array(let v) = self { return v }; return nil }
    var displayText: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.formatted(.number.grouping(.never).precision(.fractionLength(0...8)))
        case .bool(let v): return v ? "true" : "false"
        default: return ""
        }
    }
    fileprivate var primitive: Bool {
        switch self { case .string(let v): return v.count <= 4000; case .number(let v): return v.isFinite; case .bool: return true; default: return false }
    }
    fileprivate func sameType(as other: Self) -> Bool {
        switch (self, other) { case (.string, .string), (.number, .number), (.bool, .bool): return true; default: return false }
    }
}

struct CoveWidgetError: LocalizedError {
    let message: String
    var errorDescription: String? { "卡片格式无效：\(message)" }
}
private func requireWidget(_ condition: Bool, _ message: String) throws {
    if !condition { throw CoveWidgetError(message: message) }
}
private func widgetKeys(_ object: [String: CoveWidgetValue], _ allowed: Set<String>) throws {
    try requireWidget(Set(object.keys).isSubset(of: allowed), "存在未知字段")
}
private func widgetIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 } && !["__proto__", "prototype", "constructor"].contains(value)
}

/// JSONDecoder accepts repeated object keys. Preflight each independent object scope
/// before decoding, comparing decoded keys so escaped spellings cannot bypass it.
private struct CoveWidgetJSONPreflight {
    let bytes: [UInt8]
    var offset = 0

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        try requireWidget(offset == bytes.count, "JSON 尾部存在额外内容")
    }
    private mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func consume(_ byte: UInt8) throws {
        whitespace()
        try requireWidget(offset < bytes.count && bytes[offset] == byte, "JSON 结构错误")
        offset += 1
    }
    private mutating func string() throws -> String {
        whitespace()
        let start = offset
        try consume(34)
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
        }
        throw CoveWidgetError(message: "JSON 字符串未结束")
    }
    private mutating func value(depth: Int) throws {
        whitespace()
        try requireWidget(depth <= 64 && offset < bytes.count, "JSON 嵌套过深或不完整")
        switch bytes[offset] {
        case 123:
            offset += 1
            whitespace()
            if offset < bytes.count && bytes[offset] == 125 { offset += 1; return }
            var keys = Set<String>()
            while true {
                let key = try string()
                try requireWidget(keys.insert(key).inserted, "JSON 对象包含重复字段")
                try consume(58)
                try value(depth: depth + 1)
                whitespace()
                if offset < bytes.count && bytes[offset] == 125 { offset += 1; return }
                try consume(44)
            }
        case 91:
            offset += 1
            whitespace()
            if offset < bytes.count && bytes[offset] == 93 { offset += 1; return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if offset < bytes.count && bytes[offset] == 93 { offset += 1; return }
                try consume(44)
            }
        case 34: _ = try string()
        default:
            let start = offset
            while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            try requireWidget(offset > start, "JSON 值缺失")
            // Validate primitive token syntax now; full document decoding follows.
            let token = try JSONDecoder().decode(CoveWidgetValue.self, from: Data(bytes[start..<offset]))
            try requireWidget(token.primitive || token == .null, "JSON 值错误")
        }
    }
}

struct CoveWidgetNode: Equatable {
    let type: String
    let id: String?
    let visible: CoveWidgetValue?
    let props: [String: CoveWidgetValue]
    let children: [CoveWidgetNode]
}

struct CoveWidgetDocument: Equatable {
    let version: Int
    let id: String
    let state: [String: CoveWidgetValue]
    let root: CoveWidgetNode

    static func parse(_ source: String) throws -> Self {
        try requireWidget(source.utf8.count <= 65536, "超过 64 KiB")
        var preflight = CoveWidgetJSONPreflight(bytes: Array(source.utf8))
        try preflight.validate()
        let value = try JSONDecoder().decode(CoveWidgetValue.self, from: Data(source.utf8))
        guard let object = value.objectValue, let id = object["id"]?.stringValue,
              let state = object["state"]?.objectValue, let rawRoot = object["root"] else { throw CoveWidgetError(message: "缺少文档字段") }
        try widgetKeys(object, ["version", "id", "state", "root"])
        try requireWidget(object["version"] == .number(1), "不支持的 version")
        try requireWidget(widgetIdentifier(id), "id 不合法")
        try requireWidget(state.count <= 32 && state.allSatisfy { widgetIdentifier($0.key) && $0.value.primitive }, "state 仅允许最多 32 个基本值")
        var count = 0
        var ids = Set<String>()
        let root = try parseNode(rawRoot, state: state, depth: 1, count: &count, ids: &ids)
        return Self(version: 1, id: id, state: state, root: root)
    }

    /// Revalidate a transaction before committing local UI state. No network side effects.
    func validate(state candidate: [String: CoveWidgetValue]) throws {
        try requireWidget(Set(candidate.keys) == Set(state.keys), "不能新增或删除状态")
        for (key, original) in state {
            guard let value = candidate[key] else { throw CoveWidgetError(message: "缺少状态") }
            try requireWidget(value.primitive && value.sameType(as: original), "状态类型或长度错误")
        }
        func encoded(_ node: CoveWidgetNode) -> CoveWidgetValue {
            var o: [String: CoveWidgetValue] = ["type": .string(node.type), "props": .object(node.props)]
            if !node.children.isEmpty { o["children"] = .array(node.children.map(encoded)) }
            if let id = node.id { o["id"] = .string(id) }
            if let visible = node.visible { o["visible"] = visible }
            return .object(o)
        }
        var count = 0
        var ids = Set<String>()
        _ = try Self.parseNode(encoded(root), state: candidate, depth: 1, count: &count, ids: &ids)
    }

    private static func parseNode(_ value: CoveWidgetValue, state: [String: CoveWidgetValue], depth: Int, count: inout Int, ids: inout Set<String>) throws -> CoveWidgetNode {
        count += 1
        try requireWidget(depth <= 12 && count <= 128, "组件数量或嵌套过深")
        guard let o = value.objectValue, let type = o["type"]?.stringValue else { throw CoveWidgetError(message: "组件缺少 type") }
        try widgetKeys(o, ["type", "id", "visible", "props", "children"])
        let id = o["id"]?.stringValue
        if let raw = o["id"] { try requireWidget(raw.stringValue != nil && widgetIdentifier(id ?? "") && ids.insert(id ?? "").inserted, "组件 id 无效或重复") }
        if let visible = o["visible"] { try requireWidget(try CoveWidgetEngine.evaluate(visible, state: state).boolValue != nil, "visible 必须为布尔表达式") }
        try requireWidget(o["props"] == nil || o["props"]?.objectValue != nil, "props 必须是对象")
        try requireWidget(o["children"] == nil || o["children"]?.arrayValue != nil, "children 必须是数组")
        let p = o["props"]?.objectValue ?? [:]
        let containers: Set<String> = ["Stack", "Grid", "Card", "Transition", "Disclosure"]
        try requireWidget(containers.contains(type) || o["children"] == nil, "叶组件不能包含 children")
        func literal(_ key: String, required: Bool = true) throws -> String? {
            if !required && p[key] == nil { return nil }
            guard let s = p[key]?.stringValue, s.count <= 4000 else { throw CoveWidgetError(message: "\(type).\(key) 必须是字符串") }
            return s
        }
        func expression(_ key: String, kind: String = "display", required: Bool = true) throws {
            if !required && p[key] == nil { return }
            guard let e = p[key] else { throw CoveWidgetError(message: "缺少 \(type).\(key)") }
            let v = try CoveWidgetEngine.evaluate(e, state: state)
            try requireWidget(kind == "number" ? v.numberValue != nil : kind == "bool" ? v.boolValue != nil : v.primitive, "\(type).\(key) 类型错误")
        }
        func number(_ key: String, default fallback: Double? = nil) throws -> Double {
            guard let n = p[key]?.numberValue ?? (p[key] == nil ? fallback : nil), n.isFinite else { throw CoveWidgetError(message: "\(type).\(key) 必须是数值") }; return n
        }
        func bind(_ kind: String) throws -> CoveWidgetValue {
            guard let key = try literal("bind"), let value = state[key] else { throw CoveWidgetError(message: "bind 引用了不存在的状态") }
            try requireWidget(kind == "string" ? value.stringValue != nil : kind == "number" ? value.numberValue != nil : value.boolValue != nil, "bind 类型错误")
            return value
        }
        switch type {
        case "Text":
            try widgetKeys(p, ["text", "style"]); try expression("text")
            if let style = try literal("style", required: false) { try requireWidget(["body", "title", "caption"].contains(style), "Text.style 无效") }
        case "Stack", "Grid":
            try widgetKeys(p, type == "Stack" ? ["axis", "spacing"] : ["columns", "spacing"])
            let spacing = try number("spacing", default: 12); try requireWidget((0...32).contains(spacing), "spacing 超出范围")
            if type == "Stack", let axis = try literal("axis", required: false) { try requireWidget(["horizontal", "vertical"].contains(axis), "axis 无效") }
            if type == "Grid" { let n = try number("columns", default: 2); try requireWidget((1...3).contains(n) && n.rounded() == n, "columns 必须为 1–3") }
        case "Card": try widgetKeys(p, ["title"]); try expression("title", required: false)
        case "Button":
            try widgetKeys(p, ["label", "action", "disabled"]); try expression("label"); try expression("disabled", kind: "bool", required: false)
            guard let a = p["action"] else { throw CoveWidgetError(message: "缺少 Button.action") }
            var copy = state; _ = try CoveWidgetEngine.apply(a, state: &copy, validating: true)
        case "Input":
            try widgetKeys(p, ["label", "bind", "placeholder", "maxLength"]); _ = try literal("label"); _ = try literal("placeholder", required: false)
            let v = try bind("string"); let limit = try number("maxLength", default: 1000)
            try requireWidget((1...4000).contains(limit) && limit.rounded() == limit && Double(v.stringValue!.count) <= limit, "Input 长度超出范围")
        case "Slider":
            try widgetKeys(p, ["label", "bind", "min", "max", "step"]); _ = try literal("label"); let v = try bind("number")
            let lo = try number("min"), hi = try number("max"), step = try number("step", default: 1)
            try requireWidget(lo < hi && (hi - lo).isFinite && step > 0 && step <= hi - lo && (lo...hi).contains(v.numberValue!), "Slider 范围错误")
        case "Metric": try widgetKeys(p, ["label", "value", "unit"]); _ = try literal("label"); _ = try literal("unit", required: false); try expression("value")
        case "Progress":
            try widgetKeys(p, ["label", "value", "total"]); _ = try literal("label", required: false); try expression("value", kind: "number")
            try requireWidget(try number("total", default: 100) > 0, "Progress.total 必须为正数")
        case "Transition":
            try widgetKeys(p, ["key", "style"]); try expression("key", required: false)
            if let s = try literal("style", required: false) { try requireWidget(["fade", "slide"].contains(s), "Transition.style 无效") }
        case "Choice":
            try widgetKeys(p, ["label", "bind", "options"]); _ = try literal("label"); let selection = try bind("string").stringValue!
            guard let options = p["options"]?.arrayValue else { throw CoveWidgetError(message: "Choice 缺少 options") }
            try requireWidget((1...20).contains(options.count), "Choice 选项数量超出范围")
            var values = Set<String>()
            for option in options {
                guard let o = option.objectValue, let label = o["label"]?.stringValue, let value = o["value"]?.stringValue else { throw CoveWidgetError(message: "Choice 选项格式错误") }
                try widgetKeys(o, ["label", "value"])
                try requireWidget(label.count <= 4000 && value.count <= 4000 && values.insert(value).inserted, "Choice 选项重复或过长")
            }
            try requireWidget(selection.isEmpty || values.contains(selection), "Choice 状态不在选项中")
        case "Image", "Audio":
            try widgetKeys(p, type == "Image" ? ["src", "alt"] : ["src", "label"])
            _ = try literal(type == "Image" ? "alt" : "label")
            try requireWidget(CoveWidgetEngine.isAllowedMediaURL(try literal("src") ?? ""), "媒体只支持公共 HTTPS 地址")
        case "Disclosure":
            try widgetKeys(p, ["label", "bind"]); _ = try literal("label"); if p["bind"] != nil { _ = try bind("bool") }
        default: throw CoveWidgetError(message: "未知组件 \(type)")
        }
        let children = try (o["children"]?.arrayValue ?? []).map { try parseNode($0, state: state, depth: depth + 1, count: &count, ids: &ids) }
        return CoveWidgetNode(type: type, id: id, visible: o["visible"], props: p, children: children)
    }
}

enum CoveWidgetEngine {
    static func evaluate(_ expression: CoveWidgetValue, state: [String: CoveWidgetValue]) throws -> CoveWidgetValue {
        var budget = 256
        return try evaluate(expression, state: state, depth: 0, budget: &budget)
    }
    private static func evaluate(_ e: CoveWidgetValue, state: [String: CoveWidgetValue], depth: Int, budget: inout Int) throws -> CoveWidgetValue {
        budget -= 1; try requireWidget(depth <= 16 && budget >= 0, "表达式过于复杂")
        if e.primitive { return e }
        guard let o = e.objectValue else { throw CoveWidgetError(message: "表达式必须为基本值、ref 或 op") }
        if let ref = o["ref"]?.stringValue {
            try widgetKeys(o, ["ref"])
            guard widgetIdentifier(ref), let value = state[ref], value.primitive else { throw CoveWidgetError(message: "未知状态引用 \(ref)") }; return value
        }
        try widgetKeys(o, ["op", "args"])
        guard let op = o["op"]?.stringValue, let args = o["args"]?.arrayValue, args.count <= 32 else { throw CoveWidgetError(message: "运算格式错误") }
        // Evaluate every branch: hidden content cannot conceal invalid references or operations.
        let v = try args.map { try evaluate($0, state: state, depth: depth + 1, budget: &budget) }
        func arity(_ n: Int) throws { try requireWidget(v.count == n, "\(op) 参数数量错误") }
        func nums() throws -> [Double] { try requireWidget(v.allSatisfy { $0.numberValue != nil }, "\(op) 需要数值"); return v.compactMap(\.numberValue) }
        func bools() throws -> [Bool] { try requireWidget(v.allSatisfy { $0.boolValue != nil }, "\(op) 需要布尔值"); return v.compactMap(\.boolValue) }
        var result: CoveWidgetValue
        switch op {
        case "add", "sub", "mul", "div", "min", "max":
            try arity(2); let n = try nums(); var r: Double
            switch op { case "add": r = n[0] + n[1]; case "sub": r = n[0] - n[1]; case "mul": r = n[0] * n[1]; case "div": try requireWidget(n[1] != 0, "不能除以零"); r = n[0] / n[1]; case "min": r = min(n[0], n[1]); default: r = max(n[0], n[1]) }
            result = .number(r)
        case "round": try arity(1); result = .number(try nums()[0].rounded())
        case "eq", "ne": try arity(2); try requireWidget(v[0].sameType(as: v[1]), "比较值类型必须相同"); result = .bool(op == "eq" ? v[0] == v[1] : v[0] != v[1])
        case "lt", "lte", "gt", "gte":
            try arity(2); let n = try nums(); result = .bool(op == "lt" ? n[0] < n[1] : op == "lte" ? n[0] <= n[1] : op == "gt" ? n[0] > n[1] : n[0] >= n[1])
        case "and", "or": try arity(2); let b = try bools(); result = .bool(op == "and" ? b[0] && b[1] : b[0] || b[1])
        case "not": try arity(1); result = .bool(try !bools()[0])
        case "if": try arity(3); try requireWidget(v[0].boolValue != nil && v[1].sameType(as: v[2]), "if 条件或分支类型错误"); result = v[0].boolValue! ? v[1] : v[2]
        case "concat": try requireWidget(!v.isEmpty, "concat 至少一个参数"); result = .string(v.map(\.displayText).joined())
        default: throw CoveWidgetError(message: "未知运算 \(op)")
        }
        try requireWidget(result.primitive || (result.stringValue.map { $0.count <= 8000 } ?? false), "计算结果过长或非有限数")
        return result
    }

    static func apply(_ action: CoveWidgetValue, state: inout [String: CoveWidgetValue]) throws -> String? {
        try apply(action, state: &state, validating: false)
    }
    fileprivate static func apply(_ action: CoveWidgetValue, state: inout [String: CoveWidgetValue], validating: Bool) throws -> String? {
        guard let o = action.objectValue, let type = o["type"]?.stringValue else { throw CoveWidgetError(message: "action 格式错误") }
        if type == "set" {
            try widgetKeys(o, ["type", "values"])
            guard let updates = o["values"]?.objectValue, !updates.isEmpty, updates.count <= 32 else { throw CoveWidgetError(message: "set.values 格式错误") }
            var next = state
            for (key, expression) in updates {
                guard let old = state[key] else { throw CoveWidgetError(message: "set 引用了不存在的状态") }
                let value = try evaluate(expression, state: state)
                try requireWidget(value.sameType(as: old) && value.primitive, "set 不能改变状态类型")
                next[key] = value
            }
            state = next; return nil
        }
        if type == "send" {
            try widgetKeys(o, ["type", "text"])
            guard let expression = o["text"], let text = try evaluate(expression, state: state).stringValue else { throw CoveWidgetError(message: "send.text 必须为字符串表达式") }
            try requireWidget(text.count <= 8000 && (validating || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), "发送内容为空或过长")
            return text
        }
        throw CoveWidgetError(message: "未知 action")
    }

    static func isAllowedMediaURL(_ source: String) -> Bool {
        guard source.utf8.count <= 4096, let c = URLComponents(string: source), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), !host.isEmpty, c.port == nil || c.port == 443 else { return false }
        // Reject IP literals entirely; public DNS names only. DNS rebinding still needs transport enforcement.
        if host.contains(":") || host.hasPrefix("[") || host.hasSuffix(".") || !host.contains(".") { return false }
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        return !["localhost", "local", "internal", "home", "lan", "test", "invalid"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
