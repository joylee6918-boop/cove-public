import Foundation

struct CoveWalletSnapshot: Decodable {
    struct Activity: Decodable, Identifiable {
        let id: String
        let amountFen: Int
        let category: String
        let reason: String
        let day: String
        let createdAt: String
        let purchaseID: String?
    }
    struct Earning: Decodable, Identifiable {
        let category: String
        let amountFen: Int
        var id: String { category }
    }
    struct Purchase: Decodable, Identifiable {
        let id: String
        let amountFen: Int
        let reason: String
        let status: String
        let createdAt: String
        let updatedAt: String
        var statusTitle: String {
            ["requested": "待审核 · 已预留", "approved": "已扣款 · 待兑现", "fulfilled": "已兑现",
             "denied": "已拒绝", "cancelled": "已取消"][status] ?? "未知状态"
        }
    }
    let wallet: String
    let currency: String
    let virtual: Bool
    let day: String
    let updatedAt: String
    let balanceFen: Int
    let availableFen: Int
    let reservedFen: Int
    let todayIncomeFen: Int
    let todaySpendingFen: Int
    let dailyAllowanceFen: Int
    let allowancePending: Bool
    let activity: [Activity]
    let earnings: [Earning]
    let purchases: [Purchase]

    var pendingApprovalCount: Int { purchases.filter { $0.status == "requested" }.count }
    var pendingApprovalTitle: String { "\(pendingApprovalCount)项待审批" }

    func validated() throws -> Self {
        guard wallet == "assistant", currency == "CNY", virtual, dailyAllowanceFen == 500,
              balanceFen >= 0, (0...balanceFen).contains(reservedFen),
              availableFen == balanceFen - reservedFen, todayIncomeFen >= 0, todaySpendingFen >= 0,
              activity.count <= 100, purchases.count <= 200,
              Set(activity.map(\.id)).count == activity.count,
              Set(purchases.map(\.id)).count == purchases.count,
              purchases.allSatisfy({ (1...100_000_000).contains($0.amountFen) &&
                  ["requested", "approved", "fulfilled", "denied", "cancelled"].contains($0.status) }),
              purchases.filter({ $0.status == "requested" }).reduce(0, { $0 + $1.amountFen }) == reservedFen else {
            throw CoveWalletError.invalidResponse
        }
        return self
    }
}

enum CoveWalletError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "钱包响应无效；不会用零余额替代。" }
}

enum CoveWalletMoney {
    static func parse(_ value: String, signed: Bool = false) -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 12,
              text.range(of: signed ? #"^-?[0-9]+(\.[0-9]{1,2})?$"# : #"^[0-9]+(\.[0-9]{1,2})?$"#,
                         options: .regularExpression) != nil else { return nil }
        let negative = text.hasPrefix("-")
        let parts = text.replacingOccurrences(of: "-", with: "").split(separator: ".")
        guard let yuan = Int(parts[0]), yuan <= 1_000_000 else { return nil }
        let decimals = parts.count == 2 ? String(parts[1]) : ""
        let fen = yuan * 100 + (Int(decimals.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
        guard (1...100_000_000).contains(fen) else { return nil }
        return negative ? -fen : fen
    }

    static func display(_ fen: Int) -> String {
        let magnitude = fen.magnitude
        return "\(fen < 0 ? "−" : "")¥\(magnitude / 100).\(String(format: "%02d", Int(magnitude % 100)))"
    }
}

struct CoveWalletCommand: Codable, Identifiable {
    let id: String
    let operation: String
    var amountFen: Int?
    var category: String?
    var reason: String?
    var purchaseID: String?
    var decision: String?
    // Confirmation copy is local-only, never sent as an API authority or mutable price.
    var displaySummary: String?

    var body: [String: Any] {
        var result: [String: Any] = ["id": id]
        if let amountFen { result["amountFen"] = amountFen }
        if let category { result["category"] = category }
        if let reason { result["reason"] = reason }
        if let purchaseID { result["purchaseID"] = purchaseID }
        if let decision { result["decision"] = decision }
        return result
    }
}

struct CoveWalletReceipt: Decodable {
    let id: String
    let operation: String
}

enum CoveWalletCategory {
    static let owner = ["coding", "bugfix", "research", "penwash", "journal", "writing", "bonus", "gift", "adjustment", "refund"]
    static func title(_ value: String) -> String {
        ["daily": "每日零用钱", "coding": "代码", "bugfix": "修复问题", "research": "维护／研究",
         "penwash": "钢笔淡彩", "journal": "手帐", "writing": "收藏写作", "bonus": "自定奖励",
         "gift": "赠与", "adjustment": "账目更正", "refund": "退款", "purchase": "购买扣款"][value] ?? value
    }
}
