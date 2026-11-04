import AppIntents

extension ActivityApp: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "App" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.wechat: "微信", .douyin: "抖音", .taobao: "淘宝", .chatGPT: "ChatGPT",
         .cove: "Cove", .ccc: "CCC", .safari: "Safari", .rednote: "小红书"]
    }
}
extension ActivityAction: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "活动" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.open: "已打开", .close: "已离开"]
    }
}
struct RecordAppActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "记录 App 活动"
    static var description = IntentDescription("先保存一次打开或离开记录到手机，再分别向已配置的 Cove 和 CCC 补传。需要明确选择 App；不会自动读取前台应用。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "App") var app: ActivityApp
    @Parameter(title: "活动") var action: ActivityAction
    static var parameterSummary: some ParameterSummary {
        Summary("记录 \(\.$app) \(\.$action)")
    }
    @MainActor func perform() async throws -> some IntentResult {
        try await CoveActivityRecorder.shared.record(app: app, action: action)
        // A quiet result means only that the local action finished; it never claims delivery.
        return .result()
    }
}
