import SwiftUI

@MainActor
final class CoveFitnessModel: ObservableObject {
    static let live = CoveFitnessModel(repository: .live)
    static var defaultModel: CoveFitnessModel {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ? preview() : live
    }
    let repository: CoveFitnessRepository
    let isPreview: Bool
    @Published private(set) var sessions: [CoveFitnessSession] = []
    @Published private(set) var draft: CoveFitnessDraft?
    @Published private(set) var isLoaded = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var error: String?

    init(repository: CoveFitnessRepository, isPreview: Bool = false) {
        // A preview cannot accidentally read or persist an injected live repository.
        self.repository = isPreview ? CoveFitnessRepository(directoryURL: nil) : repository
        self.isPreview = isPreview
        reload()
    }
    static func preview() -> CoveFitnessModel {
        CoveFitnessModel(repository: CoveFitnessRepository(directoryURL: nil), isPreview: true)
    }
    func reload(discardUnsavedChanges: Bool = false) {
        guard !hasUnsavedChanges || discardUnsavedChanges else { return }
        do {
            let archive = try repository.snapshot()
            sessions = CoveFitnessSummaries.ordered(archive.sessions); draft = archive.draft
            isLoaded = true; hasUnsavedChanges = false; error = nil
        } catch { self.error = "本机记录未能读取：\(error.localizedDescription)"; isLoaded = false }
    }
    @discardableResult
    func start(_ value: CoveFitnessDraft) -> Bool {
        guard isLoaded, draft == nil else { return false }
        do {
            draft = try repository.saveDraft(value)
            error = nil; hasUnsavedChanges = false
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func update(_ change: (inout CoveFitnessDraft) -> Void) {
        guard var value = draft else { return }
        change(&value)
        draft = value; hasUnsavedChanges = true
        savePending()
    }
    @discardableResult
    func savePending() -> Bool {
        guard let draft else { return true }
        do {
            self.draft = try repository.saveDraft(draft)
            hasUnsavedChanges = false; error = nil
            return true
        } catch { self.error = "草稿尚未保存：\(error.localizedDescription)"; return false }
    }
    func retry() { if hasUnsavedChanges { savePending() } else { reload() } }
    @discardableResult
    func finish(at end: Date = Date()) -> Bool {
        guard savePending(), let draft else { return false }
        do {
            let record = try repository.complete(draft, endedAt: end)
            sessions = CoveFitnessSummaries.ordered(sessions + [record])
            self.draft = nil; hasUnsavedChanges = false; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult
    func discard() -> Bool {
        guard let draft else { return true }
        do {
            // Use the persisted revision; failed local edits need not be saved to discard.
            let archive = try repository.snapshot()
            guard let persisted = archive.draft, persisted.id == draft.id, persisted.revision == draft.revision else {
                throw CoveFitnessError.conflict
            }
            try repository.discard(persisted)
            self.draft = nil; hasUnsavedChanges = false; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

/// Embed in an existing NavigationStack. No tab or app-wide navigation changes.
struct CoveFitnessPage: View {
    @StateObject private var model: CoveFitnessModel
    @State private var showingStart = false
    @State private var showingActive = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    init(model: CoveFitnessModel? = nil) { _model = StateObject(wrappedValue: model ?? .defaultModel) }
    init(repository: CoveFitnessRepository) { _model = StateObject(wrappedValue: CoveFitnessModel(repository: repository)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.isPreview { FitnessPreviewLabel() }
                FitnessErrorNotice(model: model)
                if model.isLoaded {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        hero(at: context.date)
                    }
                    todayCard
                    recent
                }
                Text("仅保存在本机，不会上传或写入 Apple 健康。")
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
            .padding(20).frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(CoveStyle.pearlCanvas).foregroundStyle(CoveStyle.pearlInk)
        .tint(CoveStyle.accent)
        .navigationTitle("健身").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("记录") { FitnessHistoryView(model: model) }
            }
        }
        .sheet(isPresented: $showingStart, onDismiss: {
            if model.draft != nil { showingActive = true }
        }) {
            NavigationStack { FitnessStartView(model: model) { showingStart = false } }
        }
        .sheet(isPresented: $showingActive) {
            NavigationStack { FitnessActiveView(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !model.hasUnsavedChanges { model.reload() }
        }
        .onAppear { if !model.hasUnsavedChanges { model.reload() } }
    }

    private func hero(at date: Date) -> some View {
        let calendar = Calendar.current
        let summary = CoveFitnessSummaries.summary(model.sessions, containing: date, calendar: calendar)
        return VStack(alignment: .leading, spacing: 18) {
            Label("本周节奏", systemImage: "figure.strengthtraining.traditional")
                .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
            Text(summary?.conclusion ?? "按自己的节奏来")
                .font(.system(.largeTitle, design: .serif)).fixedSize(horizontal: false, vertical: true)
            if let summary, summary.sessionCount > 0 {
                Text("\(summary.activeDays) 天有记录 · \(FitnessText.duration(summary.durationSeconds))")
                    .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
            }
            Text("不用追赶，按今天的状态来。")
                .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicType.isAccessibilitySize ? 2 : 7), spacing: 12) {
                ForEach(CoveFitnessSummaries.weekRhythm(model.sessions, containing: date, calendar: calendar)) { day in
                    VStack(spacing: 8) {
                        Image(systemName: day.count > 0 ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(CoveStyle.pearlInk)
                            .padding(6).background(CoveStyle.pearlIce.opacity(day.count > 0 ? 0.75 : 0.20), in: Circle())
                        Text(day.date, format: .dateTime.weekday(.narrow)).font(.caption)
                        Text(day.count > 0 ? "\(day.count)" : "—").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted))，\(day.count) 次记录")
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).covePearlCard(emphasized: true)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今天练什么").font(.title3.weight(.semibold))
            if let draft = model.draft {
                Text(draft.name).font(.headline)
                Text("\(draft.kind.title) · \(model.hasUnsavedChanges ? "尚有未保存内容" : "草稿已保留")")
                    .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
                Button { showingActive = true } label: {
                    Label("继续记录", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent)
            } else {
                Text("力量训练，或散步、跑步、瑜伽。每一种活动都可以记下来。")
                    .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
                Button { showingStart = true } label: {
                    Label("开始 / 补记活动", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).covePearlCard()
    }
    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近训练").font(.title3.weight(.semibold))
            if model.sessions.isEmpty {
                Text("还没有完成的训练。开始后，草稿会自动保留。")
                    .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
            } else {
                ForEach(Array(model.sessions.prefix(3))) { session in
                    NavigationLink { FitnessDetailView(session: session) } label: { FitnessSessionRow(session: session) }
                        .buttonStyle(.plain)
                    if session.id != model.sessions.prefix(3).last?.id { Divider() }
                }
            }
        }.padding(20).covePearlCard()
    }
}

/// Compact standalone entry; shares the same default model as the full page.
/// For app-level sample mode explicitly inject CoveFitnessModel.preview().
struct CoveFitnessHomeCard: View {
    @StateObject private var model: CoveFitnessModel
    @State private var showingPage = false
    init(model: CoveFitnessModel? = nil) { _model = StateObject(wrappedValue: model ?? .defaultModel) }
    init(repository: CoveFitnessRepository) { _model = StateObject(wrappedValue: CoveFitnessModel(repository: repository)) }
    var body: some View {
        Button { showingPage = true } label: {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    Label("健身", systemImage: "dumbbell").font(.headline).foregroundStyle(CoveStyle.dataBlue)
                    if model.isPreview { FitnessPreviewLabel() }
                    if !model.isLoaded || model.error != nil {
                        Text("本机记录待检查").font(.subheadline)
                    } else {
                        Text(CoveFitnessSummaries.summary(model.sessions, containing: context.date)?.conclusion ?? "健身记录")
                            .font(.subheadline)
                        Text(model.draft.map { "继续 · \($0.name)" } ?? "力量 / 一般活动")
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .padding(18).covePearlCard()
            }
        }
        .buttonStyle(.plain).foregroundStyle(CoveStyle.pearlInk)
        .accessibilityIdentifier("home.fitness")
        .accessibilityHint("打开健身记录")
        .sheet(isPresented: $showingPage) {
            NavigationStack {
                CoveFitnessPage(model: model)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { showingPage = false } } }
            }
        }
        .onAppear { if !model.hasUnsavedChanges { model.reload() } }
    }
}

private struct FitnessStartView: View {
    @ObservedObject var model: CoveFitnessModel
    let started: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CoveFitnessKind = .strength
    @State private var name = ""
    @State private var activity = "快走"
    @State private var start = Date()
    @State private var localError: String?
    private let activities = ["快走", "跑步", "骑行", "游泳", "瑜伽", "普拉提", "徒步", "其他"]
    var body: some View {
        Form {
            if model.isPreview { FitnessPreviewLabel() }
            Section("记录类型") {
                Picker("类型", selection: $kind) {
                    ForEach(CoveFitnessKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if kind == .activity {
                    Picker("活动", selection: $activity) { ForEach(activities, id: \.self) { Text($0) } }
                }
                TextField(kind == .strength ? "训练名称，如：下肢力量" : "记录名称，如：傍晚快走", text: $name)
                DatePicker("开始时间", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            }
            Section {
                Text("从现在开始计时，或选择过去的开始时间来补记。一般活动可填写实际时长、距离与热量；没有记录的数值不估算。")
                    .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
            }
            if let error = localError ?? model.error { Text(error).foregroundStyle(CoveStyle.error) }
            Button("建立草稿") {
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = CoveFitnessDraft(name: title, kind: kind, startedAt: start,
                                             activity: kind == .activity ? .init(kind: activity == "其他" ? title : activity) : nil)
                do {
                    try CoveFitnessValidation.draft(value, now: Date())
                    if model.start(value) { started() }
                } catch { localError = error.localizedDescription }
            }.foregroundStyle(CoveStyle.accentText)
        }
        .navigationTitle("开始记录").navigationBarTitleDisplayMode(.inline)
        .tint(CoveStyle.accent)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

private struct FitnessActiveView: View {
    @ObservedObject var model: CoveFitnessModel
    @Environment(\.dismiss) private var dismiss
    @State private var newExercise = ""
    @State private var addingExercise = false
    @State private var editingActivity = false
    @State private var editingSet: FitnessSetEdit?
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    @State private var inputError: String?

    var body: some View {
        Form {
            if model.isPreview { FitnessPreviewLabel() }
            FitnessErrorNotice(model: model)
            if let draft = model.draft {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent("已进行", value: FitnessText.duration(max(0, context.date.timeIntervalSince(draft.startedAt))))
                            .monospacedDigit()
                    }
                    DatePicker("开始时间", selection: Binding(get: { draft.startedAt }, set: { date in
                        model.update { $0.startedAt = date }
                    }), in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    Label(model.hasUnsavedChanges ? "尚未保存，请重试" : "草稿已保存在本机", systemImage: model.hasUnsavedChanges ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
                if draft.kind == .strength {
                    ForEach(draft.exercises) { exercise in exerciseSection(exercise, draft: draft) }
                    Section {
                        Button { addingExercise = true } label: { Label("添加动作", systemImage: "plus") }
                    }
                } else if let activity = draft.activity {
                    Section("一般活动") {
                        LabeledContent("类型", value: activity.kind)
                        LabeledContent("活动时长", value: activity.durationSeconds.map(FitnessText.duration) ?? "使用开始至结束的时间")
                        LabeledContent("距离", value: activity.distanceKM.map { "\(FitnessText.number($0)) km" } ?? "未记录")
                        LabeledContent("热量", value: activity.energyKCAL.map { "\(FitnessText.number($0)) kcal" } ?? "未记录")
                        Button("填写活动数据") { editingActivity = true }
                    }
                }
                Section("感受与备注") {
                    Picker("感受", selection: Binding<CoveFitnessEffort?>(get: { draft.effort }, set: { effort in
                        model.update { $0.effort = effort }
                    })) {
                        Text("未记录").tag(nil as CoveFitnessEffort?)
                        ForEach(CoveFitnessEffort.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    TextField("备注（可选，最多 4000 字）", text: Binding(get: { draft.note }, set: { note in
                        model.update { $0.note = note }
                    }), axis: .vertical).lineLimit(3...8)
                }
                Section {
                    Button("完成并保存") { confirmFinish = true }.font(.headline)
                    Button("放弃这次记录", role: .destructive) { confirmDiscard = true }
                } footer: {
                    Text("只统计标记完成的组；未完成组保留为计划，不计入成绩。保存后记录不可修改。")
                }
            }
        }
        .foregroundStyle(CoveStyle.pearlInk).tint(CoveStyle.accent)
        .navigationTitle(model.draft?.name ?? "训练").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() }.disabled(model.hasUnsavedChanges) } }
        .interactiveDismissDisabled(model.hasUnsavedChanges)
        .alert("添加动作", isPresented: $addingExercise) {
            TextField("动作名称", text: $newExercise)
            Button("添加") {
                do {
                    try CoveFitnessValidation.name(newExercise)
                    let name = newExercise.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.update { $0.exercises.append(.init(name: name)) }
                    newExercise = ""
                } catch { inputError = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("输入名称后，再添加实际训练的组。") }
        .alert("请检查", isPresented: Binding(get: { inputError != nil }, set: { if !$0 { inputError = nil } })) {
            Button("好", role: .cancel) { inputError = nil }
        } message: { Text(inputError ?? "") }
        .sheet(isPresented: $editingActivity) {
            if let draft = model.draft, let activity = draft.activity {
                NavigationStack { FitnessActivityEditor(model: model, activity: activity, startedAt: draft.startedAt) }
            }
        }
        .sheet(item: $editingSet) { edit in
            NavigationStack { FitnessSetEditor(model: model, edit: edit) }
        }
        .confirmationDialog("完成这次记录？", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("保存为完成记录") { if model.finish() { dismiss() } }
            Button("继续记录", role: .cancel) {}
        } message: { Text("结束时间记为现在。保存后不可修改；未完成组不会计入成绩。") }
        .confirmationDialog("放弃这次记录？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃并删除草稿", role: .destructive) { if model.discard() { dismiss() } }
            Button("继续记录", role: .cancel) {}
        } message: { Text("仅删除这次草稿，不影响已完成记录。") }
    }

    private func exerciseSection(_ exercise: CoveFitnessExercise, draft: CoveFitnessDraft) -> some View {
        Section {
            if let previous = CoveFitnessSummaries.previousPerformance(named: exercise.name, before: draft.startedAt, sessions: model.sessions) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上次 · \(previous.date.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    Text(previous.sets.map { "\(FitnessText.number($0.weightKG)) kg × \($0.reps)" }.joined(separator: " · "))
                        .font(.subheadline)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(CoveStyle.pearlIce.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("还没有这个动作的完成记录").font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("第 \(index + 1) 组完成", isOn: setBinding(exercise.id, set.id, \.completed, fallback: set.completed))
                    Stepper(value: setBinding(exercise.id, set.id, \.weightKG, fallback: set.weightKG), in: 0...2_000, step: 0.5) {
                        Text("重量 \(FitnessText.number(set.weightKG)) kg")
                    }.accessibilityLabel("\(exercise.name)，第 \(index + 1) 组重量，千克")
                    Stepper(value: setBinding(exercise.id, set.id, \.reps, fallback: set.reps), in: 1...1_000) {
                        Text("次数 \(set.reps)")
                    }.accessibilityLabel("\(exercise.name)，第 \(index + 1) 组次数")
                    Button("直接输入重量与次数") { editingSet = FitnessSetEdit(exerciseID: exercise.id, set: set) }
                        .font(.subheadline).frame(minHeight: 44)
                    Button("移除第 \(index + 1) 组", role: .destructive) {
                        model.update { value in
                            guard let i = value.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                            value.exercises[i].sets.removeAll { $0.id == set.id }
                        }
                    }.font(.caption).frame(minHeight: 44)
                }.padding(.vertical, 6)
            }
            Button("添加一组") {
                model.update { value in
                    guard let i = value.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                    let last = value.exercises[i].sets.last
                    value.exercises[i].sets.append(.init(weightKG: last?.weightKG ?? 0, reps: last?.reps ?? 8))
                }
            }.disabled(exercise.sets.count >= 100)
            Button("移除动作", role: .destructive) { model.update { $0.exercises.removeAll { $0.id == exercise.id } } }
        } header: { Text(exercise.name) }
    }
    private func setBinding<T>(_ exerciseID: UUID, _ setID: UUID, _ key: WritableKeyPath<CoveFitnessSet, T>, fallback: T) -> Binding<T> {
        Binding(get: {
            model.draft?.exercises.first(where: { $0.id == exerciseID })?.sets.first(where: { $0.id == setID })?[keyPath: key] ?? fallback
        }, set: { newValue in
            model.update { draft in
                guard let i = draft.exercises.firstIndex(where: { $0.id == exerciseID }),
                      let j = draft.exercises[i].sets.firstIndex(where: { $0.id == setID }) else { return }
                draft.exercises[i].sets[j][keyPath: key] = newValue
            }
        })
    }
}

private struct FitnessSetEdit: Identifiable {
    let exerciseID: UUID
    let set: CoveFitnessSet
    var id: UUID { self.set.id }
}

private struct FitnessSetEditor: View {
    @ObservedObject var model: CoveFitnessModel
    let edit: FitnessSetEdit
    @Environment(\.dismiss) private var dismiss
    @State private var weight = ""
    @State private var reps = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section("两项均需填写；自重填 0 kg") {
                TextField("重量 kg", text: $weight).keyboardType(.decimalPad)
                TextField("次数", text: $reps).keyboardType(.numberPad)
            }
            if let error { Text(error).foregroundStyle(CoveStyle.error) }
            FitnessErrorNotice(model: model)
        }
        .navigationTitle("组数据").navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        guard let weightValue = try FitnessText.parseNumber(weight),
                              let repsValue = Int(reps.trimmingCharacters(in: .whitespacesAndNewlines)),
                              (1...1_000).contains(repsValue) else {
                            throw CoveFitnessError.invalid("请完整填写重量与 1–1000 次的整数次数。")
                        }
                        try CoveFitnessValidation.number(weightValue, maximum: 2_000, label: "重量")
                        model.update { draft in
                            guard let i = draft.exercises.firstIndex(where: { $0.id == edit.exerciseID }),
                                  let j = draft.exercises[i].sets.firstIndex(where: { $0.id == edit.id }) else { return }
                            draft.exercises[i].sets[j].weightKG = weightValue
                            draft.exercises[i].sets[j].reps = repsValue
                        }
                        if !model.hasUnsavedChanges { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear { weight = FitnessText.editNumber(edit.set.weightKG); reps = String(edit.set.reps) }
    }
}

private struct FitnessActivityEditor: View {
    @ObservedObject var model: CoveFitnessModel
    let activity: CoveFitnessActivity
    let startedAt: Date
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = ""
    @State private var distance = ""
    @State private var energy = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("活动分钟（留空使用计时）", text: $minutes).keyboardType(.decimalPad)
                TextField("距离 km（可选）", text: $distance).keyboardType(.decimalPad)
                TextField("热量 kcal（可选）", text: $energy).keyboardType(.decimalPad)
            } header: { Text("填写实际数据") } footer: {
                Text("只填实际记录的数值。补记时请先将开始时间设为实际时间；活动时长不能超过开始至结束的时间。")
            }
            if let error { Text(error).foregroundStyle(CoveStyle.error) }
            FitnessErrorNotice(model: model)
        }
        .navigationTitle("活动数据").navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        var updated = activity
                        updated.durationSeconds = try FitnessText.parseNumber(minutes).map { $0 * 60 }
                        updated.distanceKM = try FitnessText.parseNumber(distance)
                        updated.energyKCAL = try FitnessText.parseNumber(energy)
                        let candidate = CoveFitnessDraft(name: "活动", kind: .activity, startedAt: startedAt, activity: updated)
                        try CoveFitnessValidation.draft(candidate, now: Date())
                        if let duration = updated.durationSeconds, duration > Date().timeIntervalSince(startedAt) {
                            throw CoveFitnessError.invalid("活动时长超过已进行时间，请先调整开始时间。")
                        }
                        model.update { $0.activity = updated }
                        if !model.hasUnsavedChanges { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear {
            minutes = activity.durationSeconds.map { FitnessText.editNumber($0 / 60) } ?? ""
            distance = activity.distanceKM.map(FitnessText.editNumber) ?? ""
            energy = activity.energyKCAL.map(FitnessText.editNumber) ?? ""
        }
    }
}

private struct FitnessHistoryView: View {
    @ObservedObject var model: CoveFitnessModel
    var body: some View {
        List {
            if model.isPreview { FitnessPreviewLabel() }
            FitnessErrorNotice(model: model)
            if model.isLoaded && model.sessions.isEmpty {
                ContentUnavailableView("还没有训练记录", systemImage: "dumbbell", description: Text("完成的训练会按月份保存在这里。"))
            }
            ForEach(CoveFitnessSummaries.months(model.sessions)) { month in
                Section {
                    if let total = CoveFitnessSummaries.summary(month.sessions, containing: month.date, component: .month) {
                        Text("\(total.sessionCount) 次 · \(total.activeDays) 天 · \(FitnessText.duration(total.durationSeconds))")
                            .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                    ForEach(month.sessions) { session in
                        NavigationLink { FitnessDetailView(session: session) } label: { FitnessSessionRow(session: session) }
                    }
                } header: { Text(month.date, format: .dateTime.year().month(.wide)) }
            }
        }.navigationTitle("训练记录").tint(CoveStyle.accent)
    }
}

private struct FitnessDetailView: View {
    let session: CoveFitnessSession
    var body: some View {
        List {
            Section("完成记录") {
                LabeledContent("类型", value: session.workout.kind.title)
                LabeledContent("开始", value: session.workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("结束", value: session.endedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("时长", value: FitnessText.duration(session.durationSeconds))
                LabeledContent("感受", value: session.workout.effort?.title ?? "未记录")
            }
            if let activity = session.workout.activity {
                Section("活动数据") {
                    LabeledContent("活动", value: activity.kind)
                    LabeledContent("距离", value: activity.distanceKM.map { "\(FitnessText.number($0)) km" } ?? "未记录")
                    LabeledContent("热量", value: activity.energyKCAL.map { "\(FitnessText.number($0)) kcal" } ?? "未记录")
                }
            }
            ForEach(session.workout.exercises) { exercise in
                Section(exercise.name) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        Label("第 \(index + 1) 组 · \(FitnessText.number(set.weightKG)) kg × \(set.reps) · \(set.completed ? "已完成" : "未完成")",
                              systemImage: set.completed ? "checkmark.circle.fill" : "circle")
                    }
                    if exercise.sets.isEmpty { Text("没有添加组").foregroundStyle(CoveStyle.pearlSecondary) }
                }
            }
            if !session.workout.note.isEmpty { Section("备注") { Text(session.workout.note) } }
            Section { Text("本机手动记录 · 保存后不可修改\n未完成组不计入成绩；跨日训练按开始日归属。")
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary) }
        }.navigationTitle(session.workout.name).navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(CoveStyle.pearlInk)
    }
}

private struct FitnessSessionRow: View {
    let session: CoveFitnessSession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.workout.name).font(.headline)
            Text(session.workout.startedAt, format: .dateTime.month().day().weekday().hour().minute())
                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            Text("\(FitnessText.duration(session.durationSeconds)) · \(session.workout.effort?.title ?? "感受未记录")")
                .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

private struct FitnessErrorNotice: View {
    @ObservedObject var model: CoveFitnessModel
    @State private var confirmReload = false
    var body: some View {
        if let error = model.error {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(CoveStyle.error)
                Button(model.hasUnsavedChanges ? "重试保存草稿" : "重新载入") { model.retry() }
                if model.hasUnsavedChanges {
                    Button("放弃未保存修改并重新载入", role: .destructive) { confirmReload = true }
                }
            }.font(.subheadline).accessibilityElement(children: .contain)
                .confirmationDialog("放弃未保存的修改？", isPresented: $confirmReload, titleVisibility: .visible) {
                    Button("放弃修改并载入本机记录", role: .destructive) { model.reload(discardUnsavedChanges: true) }
                    Button("取消", role: .cancel) {}
                } message: { Text("只放弃尚未写入的修改，不删除已保存的草稿或历史。读取失败时仍保留当前修改。") }
        }
    }
}
private struct FitnessPreviewLabel: View {
    var body: some View { Text("预览 · 示例空间，不写入本机记录").font(.caption).foregroundStyle(CoveStyle.pearlSecondary) }
}
private enum FitnessText {
    static func parseNumber(_ text: String) throws -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let canonical = text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let number = Double(canonical), number.isFinite, number >= 0 else {
            throw CoveFitnessError.invalid("请输入有效的非负数；不填写请留空。")
        }
        return number
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "时长无效" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "不足 1 分钟" }
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
    static func editNumber(_ value: Double) -> String { value.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
}

#Preview("健身 · 示例空间") {
    NavigationStack { CoveFitnessPage(model: .preview()) }
}
