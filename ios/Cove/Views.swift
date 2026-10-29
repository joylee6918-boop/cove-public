import Combine
import AVFoundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Charts


public struct CoveRootView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var keyboardVisible = false
    @State private var wallpaperFrame = CGRect.zero

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if store.previewMode {
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                    Text("示例预览 · 数据不会上传").font(.caption)
                    Spacer()
                    Button("退出") { store.exitPreview() }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
            }
            TabView(selection: $store.selectedTab) {
                NavigationStack { HomeView().navigationBarTitleDisplayMode(.inline).toolbarVisibility(keyboardVisible ? .hidden : .visible, for: .tabBar) }.tabItem { Label("家", systemImage: "house").accessibilityIdentifier("tab.home") }.tag(0)
                NavigationStack { PulseView().navigationBarTitleDisplayMode(.inline).toolbarVisibility(keyboardVisible ? .hidden : .visible, for: .tabBar) }.tabItem { Label("心跳", systemImage: "heart").accessibilityIdentifier("tab.pulse") }.tag(1)
                NavigationStack { ChatView().toolbarVisibility(keyboardVisible ? .hidden : .visible, for: .tabBar) }.tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right").accessibilityIdentifier("tab.chat") }.tag(2)
                NavigationStack { HealthView().navigationBarTitleDisplayMode(.inline).toolbarVisibility(keyboardVisible ? .hidden : .visible, for: .tabBar) }.tabItem { Label("健康", systemImage: "heart.text.square").accessibilityIdentifier("tab.health") }.tag(3)
                NavigationStack { SettingsView().navigationBarTitleDisplayMode(.inline).toolbarVisibility(keyboardVisible ? .hidden : .visible, for: .tabBar) }.tabItem { Label("设置", systemImage: "gearshape").accessibilityIdentifier("tab.settings") }.tag(4)
            }
            // Keep all five destinations discoverable while reading history.
            // Keyboard visibility changes the bar, never the available tabs.
            .tabBarMinimizeBehavior(.never)
        }
        .background {
            if store.selectedTab == 2 {
                CoveChatWallpaperView()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { wallpaperFrame = $0 }
                    .ignoresSafeArea()
            } else if store.selectedTab == 0 || store.selectedTab == 1 {
                CoveLivingWallpaperView(scene: store.selectedTab == 1 ? .pulse : .home).ignoresSafeArea()
            } else {
                CoveStyle.card.ignoresSafeArea()
            }
        }
        .overlay {
            #if DEBUG
            if store.previewMode && ProcessInfo.processInfo.arguments.contains("--composer-control-qa") { CoveComposerControlFixture() }
            if store.previewMode && ProcessInfo.processInfo.arguments.contains("--health-request-qa") { CoveHealthRequestFixture() }
            #endif
        }
        .modifier(CoveTravelLifecycle())
        .environment(\.coveWallpaperFrame, wallpaperFrame)
        .foregroundStyle(CoveStyle.text)
        .tint(CoveStyle.teal)
        .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }
}

private struct Avatar: View {
    let name: String
    var size: CGFloat = 44
    var body: some View {
        Text(name == "Assistant" ? "A" : "U")
            .font(.system(size: size * 0.40, weight: .medium, design: .rounded))
            .foregroundStyle(CoveStyle.teal)
            .frame(width: size, height: size)
            .background(CoveStyle.teal.opacity(0.12), in: Circle())
            .accessibilityLabel(name + "的头像")
    }
}

private struct HomeView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var lifeRefreshID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HomeRelationshipHero(isConnected: store.isConnected)

                // Keep our emotional thread close to the relationship hero.
                pulseStatusRow
                    .padding(.horizontal, 18)
                    .covePearlCard()

                CoveHomeDashboard(refreshID: lifeRefreshID, previewMode: store.previewMode)
                    .id(store.previewMode)

                CoveTravelEntry()
                CoveWalletHomeCard(refreshID: lifeRefreshID)
                CoveMemoryCalendarCard(usesHomeSurface: true)
                CoveToyHomeCard(usesHomeSurface: true)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: 680)
        }
        .foregroundStyle(CoveStyle.pearlInk)
        .frame(maxWidth: .infinity).background(Color.clear)
        .navigationTitle("家").navigationBarTitleDisplayMode(.inline)
        .refreshable { lifeRefreshID = UUID(); await store.refresh() }
    }

    private var pulseStatusRow: some View {
        Button { store.selectedTab = 1 } label: {
            HomeStatusRow(title: "我的近况", symbol: "heart") {
                Text(store.pulse?.summary ?? "还没有读到心跳记录。")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let date = store.pulse?.updatedAt { SnapshotTime(date: date) }
            }
        }
        .buttonStyle(.plain).accessibilityHint("打开心跳页")
    }

}

private struct HomeRelationshipHero: View {
    let isConnected: Bool
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .largeTitle) private var daySize = 52

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(greeting(at: context.date) + "，用户")
                            .font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
                        Text("用户与 Assistant")
                            .font(.system(.title2, design: .serif).weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Label(isConnected ? "Assistant 已连接" : "等待连接", systemImage: isConnected ? "checkmark.circle" : "circle.dotted")
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                    Spacer(minLength: 0)
                    pearlCluster
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("我们在一起")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("第").font(.subheadline)
                        Text(CoveHomeDates.togetherDay(on: context.date), format: .number)
                            .font(.system(size: daySize, weight: .light, design: .serif)).monospacedDigit()
                        Text("天").font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home.togetherDays")
                    Text("2026.08.20 · 表明心意的那一天")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }

                Rectangle().fill(CoveStyle.pearlBorderStrong.opacity(0.4)).frame(height: 0.5)

                Button { store.selectedTab = 2 } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("接着说").font(.caption.weight(.medium))
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.caption)
                        }
                        .foregroundStyle(CoveStyle.accentText)
                        if let last = store.messages.last {
                            Text(last.status == "streaming" ? "正在回复…" : last.previewText(emptyFallback: "一个附件"))
                                .font(.body).lineSpacing(3)
                                .lineLimit(dynamicType.isAccessibilitySize ? 5 : 3)
                                .multilineTextAlignment(.leading)
                            Text("\(last.role == "user" ? "用户" : "Assistant") · \(last.createdAt.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                        } else {
                            Text("想说的话，慢慢说。")
                                .font(.body).multilineTextAlignment(.leading)
                            Text("还没有对话").font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityHint("打开对话页")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .covePearlCard(emphasized: true)
        }
    }

    private var pearlCluster: some View {
        ZStack {
            CovePearlBead(diameter: 26).offset(x: 6, y: -6)
            CovePearlBead(diameter: 17).offset(x: -14, y: 12)
            CovePearlBead(diameter: 10).offset(x: 9, y: 21)
        }.frame(width: 52, height: 56).accessibilityHidden(true)
    }

    private func greeting(at date: Date) -> String {
        switch CoveHomeDates.calendar.component(.hour, from: date) {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }
}

private struct HomeStatusRow<Detail: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.body.weight(.regular))
                .foregroundStyle(CoveStyle.accentText)
                .frame(width: 30, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                detail()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2.weight(.medium))
                .foregroundStyle(CoveStyle.pearlSecondary).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}

private struct PulseView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var section = PulseSection.current

    private enum PulseSection: String, CaseIterable, Identifiable {
        case current = "当前"
        case wakes = "醒来记录"
        case feelings = "感受"
        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pulseHeader
                Picker("心跳内容", selection: $section) {
                    ForEach(PulseSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("心跳内容")

                if let pulse = store.pulse {
                    Group {
                        switch section {
                        case .current: PulseCurrentPanel(pulse: pulse, dashboard: store.pulseDashboard)
                        case .wakes:
                            PulseWakePanel(events: store.pulseDashboard?.events ?? [], onOpenConversation: openConversation)
                        case .feelings: PulseFeelingsPanel(pulse: pulse, dashboard: store.pulseDashboard)
                        }
                    }
                } else {
                    EmptyCard(symbol: "heart", title: "心跳还没有到这里", detail: "连接私有服务后，就能看到 Assistant 最近写下的状态。")
                    Button("前往连接设置") { store.selectedTab = 4 }.buttonStyle(.bordered).frame(minHeight: 44)
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28).frame(maxWidth: 680)
        }
        .foregroundStyle(CoveStyle.pearlInk)
        .frame(maxWidth: .infinity).background(Color.clear)
        .navigationTitle("心跳").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshPulseDashboard() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.refreshPulseDashboard() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("刷新心跳") } }
        .task(id: "\(store.selectedTab)-\(scenePhase)") {
            guard store.selectedTab == 1, scenePhase == .active else { return }
            await store.refreshPulseDashboard()
            while !Task.isCancelled, store.selectedTab == 1, scenePhase == .active {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await store.refreshPulseDashboard()
            }
        }
    }

    @ViewBuilder private var pulseHeader: some View {
        VStack(spacing: 12) {
            PulseLivingOrb(
                lastTickAt: store.pulseDashboard?.snapshot.heartbeat?.lastTickAt,
                respondsToUpdates: store.selectedTab == 1 && scenePhase == .active
                    && !store.pulseIsStale && !store.previewMode
            )
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    Text("Assistant").font(.system(.title2, design: .serif).weight(.medium))
                    if store.isRefreshingPulse {
                        ProgressView().controlSize(.mini).accessibilityLabel("正在更新心跳")
                    }
                }.frame(maxWidth: .infinity)
                Text(store.pulse?.summary ?? "等待最近一次心跳记录。")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let tick = store.pulseDashboard?.snapshot.heartbeat?.lastTickAt {
                    Text("上次心跳 \(pulseDate(tick))")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                } else {
                    Text("数字身体模型 · 暂无心跳记录")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
            }
            if store.pulseIsStale {
                Label("数据可能已过期，正在保留上次记录", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
            if let error = store.pulseError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(CoveStyle.error)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4).padding(.bottom, 8)
    }

    private func openConversation(_ id: String) {
        Task {
            await store.selectConversation(id)
            store.selectedTab = 2
        }
    }
}

private struct PulseLivingOrb: View {
    let lastTickAt: Date?
    let respondsToUpdates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var receivedTick = 0

    var body: some View {
        let showsGlint = !reduceMotion && respondsToUpdates
        ZStack {
            Circle()
                .stroke(CoveStyle.nacreEdge, lineWidth: 0.5)
                .frame(width: 104, height: 104)
            face
                .frame(width: 90, height: 90)
                .overlay {
                    Text("K")
                        .font(.system(size: 43, weight: .light, design: .serif))
                        .foregroundStyle(CoveStyle.pearlInk)
                        .accessibilityHidden(true)
                }
            ForEach(0..<26, id: \.self) { index in
                let angle = Double(index) / 26 * 2 * Double.pi - .pi / 2
                CovePearlBead(diameter: 11)
                    .offset(x: cos(angle) * 62, y: sin(angle) * 62)
            }
        }
        .frame(width: 146, height: 146)
        .keyframeAnimator(initialValue: 0.0, trigger: receivedTick) { content, progress in
            content.overlay {
                // One short glint on receipt of a new actual tick. The K, pearls,
                // and layout never scale, breathe, rotate or repeat.
                if showsGlint {
                    Circle().trim(from: 0, to: 0.16)
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 124, height: 124)
                        .rotationEffect(.degrees(-90 + progress * 360))
                        .opacity(sin(progress * .pi))
                        .allowsHitTesting(false)
                }
            }
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0.0)
                LinearKeyframe(1.0, duration: 0.26)
            }
        }
        .onChange(of: lastTickAt) { oldTick, newTick in
            // Initial load, stale/cache responses, backwards timestamps, inactive
            // tabs and Reduce Motion must not look like a live heartbeat.
            guard respondsToUpdates, !reduceMotion,
                  let oldTick, let newTick, newTick > oldTick,
                  (-90...5).contains(newTick.timeIntervalSinceNow) else { return }
            receivedTick += 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant 的珍珠徽记")
        .accessibilityValue(lastTickAt.map { "上次心跳记录于 \(pulseDate($0))" } ?? "暂无心跳记录")
    }

    @ViewBuilder private var face: some View {
        if reduceTransparency || contrast == .increased {
            Circle().fill(CoveStyle.pearlCardEmphasized)
                .overlay(Circle().stroke(CoveStyle.pearlBorderStrong, lineWidth: 1))
        } else {
            Circle().fill(CoveStyle.pearlCard.opacity(0.48))
                .overlay(Circle().fill(CoveStyle.nacreGradient).opacity(0.38))
                .glassEffect(.clear, in: Circle())
                .overlay(Circle().strokeBorder(CoveStyle.nacreEdge, lineWidth: 0.8))
        }
    }
}

private struct PulseGroup: View {
    let title: String
    let metrics: [PulseMetric]
    private var strongest: Set<String> {
        Set(metrics.sorted { $0.value > $1.value }.prefix(3).map(\.id))
    }
    var body: some View {
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if !title.isEmpty { Text(title).font(.headline) }
                ForEach(metrics) { metric in
                    let emphasized = strongest.contains(metric.id) && metric.value > 0.05
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().stroke(CoveStyle.border.opacity(0.7), lineWidth: 4)
                            Circle().trim(from: 0, to: min(max(metric.value, 0), 1))
                                .stroke(emphasized ? CoveStyle.accent : CoveStyle.pearlSecondary.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(min(max(metric.value, 0), 1), format: .percent.precision(.fractionLength(0)))
                                .font(.caption2.monospacedDigit())
                        }
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.label).font(.subheadline.weight(emphasized ? .semibold : .medium))
                            // A zeroed drive is retained as an honest quiet state, but an
                            // old descriptive phrase must not look current.
                            if metric.value > 0.05, !metric.detail.isEmpty {
                                Text(metric.detail).font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(min(max(metric.value, 0), 1), format: .percent.precision(.fractionLength(0))))
                }
            }.padding(16).covePearlCard(emphasized: false)
        }
    }
}

private struct PulseCurrentPanel: View {
    let pulse: PulseSnapshot
    let dashboard: PulseDashboard?
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var vitals: PulseVitals? { dashboard?.snapshot.vitals }
    private var heartbeat: PulseHeartbeat? { dashboard?.snapshot.heartbeat }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("数字身体").font(.subheadline.weight(.medium))
                    Text("以下是模型记录，不是人体测量。")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
                if let vitals {
                    if dynamicType.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 18) { vitalValues(vitals) }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) { vitalValues(vitals) }
                            VStack(alignment: .leading, spacing: 18) { vitalValues(vitals) }
                        }
                    }
                    Text("\(vitals.emotion) · \(vitals.activity) · 呼吸\(vitals.breathingDepth) · \(vitals.chord)")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                } else {
                    Text("未记录").font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary)
                }
                SnapshotTime(date: pulse.updatedAt)
                Divider()
                PulseHistoryChart(points: dashboard?.history ?? [], generatedAt: dashboard?.generatedAt ?? pulse.updatedAt)
            }
            .padding(20).covePearlCard()

            VStack(alignment: .leading, spacing: 12) {
                Text("心跳节律").font(.subheadline.weight(.medium))
                if let heartbeat {
                    LabeledContent("上次心跳", value: pulseDate(heartbeat.lastTickAt))
                    Divider()
                    LabeledContent("上次触发", value: pulseDate(heartbeat.lastWakeAt))
                    Divider()
                    LabeledContent("节律", value: heartbeat.quiet ? "安静" : "每 \(heartbeat.intervalSeconds) 秒")
                    Divider()
                    LabeledContent("下次心跳", value: pulseDate(heartbeat.nextTickAt))
                } else { Text("未记录").foregroundStyle(CoveStyle.pearlSecondary) }
                if let generated = dashboard?.generatedAt {
                    Text("面板获取于 \(generated.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
            }
            .font(.subheadline).padding(20).covePearlCard()

            if let warnings = dashboard?.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings, id: \.self) {
                        Label($0, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                }.padding(16).covePearlCard()
            }
        }
    }

    @ViewBuilder private func vitalValues(_ vitals: PulseVitals) -> some View {
        PulseVitalValue(title: "心率", value: vitals.heartRate.formatted(.number.precision(.fractionLength(0))), unit: "bpm", symbol: "heart")
        PulseVitalValue(title: "体温", value: vitals.temperature.formatted(.number.precision(.fractionLength(1))), unit: "°C", symbol: "thermometer.medium")
        PulseVitalValue(title: "呼吸", value: vitals.breathingRate.formatted(.number.precision(.fractionLength(1))), unit: "次/分", symbol: "wind")
    }
}

private struct PulseVitalValue: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.regular)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PulseHistoryChart: View {
    let points: [PulseHistoryPoint]
    let generatedAt: Date
    private var visiblePoints: [PulseHistoryPoint] {
        let start = generatedAt.addingTimeInterval(-24 * 60 * 60)
        return points.filter { $0.at >= start && $0.at <= generatedAt }.sorted { $0.at < $1.at }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("24 小时心率").font(.subheadline.weight(.medium))
                Spacer()
                Text("已记录的采样").font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
            if visiblePoints.isEmpty {
                Text("暂无已记录的模型采样").font(.subheadline).foregroundStyle(CoveStyle.pearlSecondary).frame(height: 100)
            } else {
                Chart(visiblePoints) { point in
                    if visiblePoints.count == 1 {
                        PointMark(x: .value("时间", point.at), y: .value("心率", point.heartRate))
                            .foregroundStyle(CoveStyle.accent).symbolSize(42)
                    } else {
                        AreaMark(x: .value("时间", point.at), y: .value("心率", point.heartRate))
                            .foregroundStyle(LinearGradient(colors: [CoveStyle.accent.opacity(0.12), CoveStyle.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.at), y: .value("心率", point.heartRate))
                            .foregroundStyle(CoveStyle.accentText.opacity(0.82))
                            .lineStyle(.init(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisTick(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])); AxisValueLabel() } }
                .frame(height: 130)
                .accessibilityLabel("24 小时数字身体模型心率图，共 \(visiblePoints.count) 个已记录的模型采样点")
            }
        }
    }
}

private struct PulseWakePanel: View {
    let events: [PulseWakeEvent]
    let onOpenConversation: (String) -> Void
    var body: some View {
        if events.isEmpty {
            EmptyCard(symbol: "moon.zzz", title: "还没有唤醒记录", detail: "只有 VPS 真实记下的醒来与动作会出现在这里。")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 13) {
                        VStack(spacing: 0) {
                            Circle().fill(pulseStatusColor(event.status)).frame(width: 10, height: 10).padding(.top, 7)
                            if index < events.count - 1 {
                                Rectangle().fill(CoveStyle.border.opacity(0.72)).frame(width: 1).frame(minHeight: 178)
                            }
                        }.frame(width: 16)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(pulseReasonText(event.reason)).font(.headline)
                                Spacer(minLength: 8)
                                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                            }
                            PulseRecordedRow(title: "想法摘要", value: event.thoughtSummary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("实际动作").font(.caption.weight(.semibold)).foregroundStyle(CoveStyle.pearlSecondary)
                                if event.actions.isEmpty { Text("未记录").font(.subheadline) }
                                ForEach(event.actions) { action in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: pulseStatusSymbol(action.status)).foregroundStyle(pulseStatusColor(action.status)).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(action.title).font(.subheadline.weight(.medium))
                                            if let detail = action.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(CoveStyle.pearlSecondary) }
                                        }
                                    }
                                }
                            }
                            PulseRecordedRow(title: "结果", value: event.resultSummary)
                            if let completed = event.completedAt {
                                LabeledContent("完成于", value: completed.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                            }
                            HStack {
                                Label(pulseStatusText(event.status), systemImage: pulseStatusSymbol(event.status)).font(.caption).foregroundStyle(pulseStatusColor(event.status))
                                Spacer()
                                if let id = event.conversationID {
                                    Button("打开对话") { onOpenConversation(id) }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .covePearlCard()
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }
}

private struct PulseRecordedRow: View {
    let title: String; let value: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(CoveStyle.pearlSecondary)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "未记录").font(.subheadline).textSelection(.enabled)
        }
    }
}

private struct PulseFeelingsPanel: View {
    let pulse: PulseSnapshot
    let dashboard: PulseDashboard?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PulseGroup(title: "心里的倾向", metrics: pulse.desires)
            PulseGroup(title: "身体与状态", metrics: pulse.physical)
            PulseGroup(title: "感官与细节", metrics: pulse.senses)
            VStack(alignment: .leading, spacing: 8) {
                Text("环境").font(.headline)
                if let environment = dashboard?.snapshot.environment {
                    LabeledContent("时段", value: environment.timeOfDay)
                    LabeledContent("天气", value: environment.weather ?? "未记录")
                    LabeledContent("温度", value: environment.temperature.map { $0.formatted(.number.precision(.fractionLength(1))) + " °C" } ?? "未记录")
                    LabeledContent("来源", value: environment.source)
                    if let at = environment.updatedAt { SnapshotTime(date: at) }
                } else { Text("未记录").foregroundStyle(CoveStyle.pearlSecondary) }
            }.font(.subheadline).padding(16).covePearlCard(emphasized: false)
            VStack(alignment: .leading, spacing: 10) {
                Text("低语").font(.headline)
                if let murmurs = dashboard?.murmurs, !murmurs.isEmpty {
                    ForEach(murmurs) { murmur in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(murmur.text).font(.subheadline).textSelection(.enabled)
                            Text(murmur.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(CoveStyle.pearlSecondary)
                        }
                        if murmur.id != murmurs.last?.id { Divider() }
                    }
                } else { Text("未记录").foregroundStyle(CoveStyle.pearlSecondary) }
            }.padding(16).covePearlCard(emphasized: false)
        }
    }
}

private func pulseDate(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "未记录" }
private func pulseStatusText(_ status: String) -> String {
    switch status { case "complete", "completed", "success": return "已完成"; case "quiet": return "安静完成"; case "failed", "error": return "失败"; case "running": return "进行中"; case "queued": return "等待中"; default: return status.isEmpty ? "未记录" : status }
}
private func pulseStatusSymbol(_ status: String) -> String {
    switch status { case "complete", "completed", "success": return "checkmark.circle"; case "quiet": return "moon.circle"; case "failed", "error": return "xmark.circle"; case "running": return "ellipsis.circle"; default: return "circle" }
}
private func pulseStatusColor(_ status: String) -> Color {
    switch status { case "failed", "error": return CoveStyle.error; case "quiet": return CoveStyle.pearlSecondary; default: return CoveStyle.teal }
}
private func pulseReasonText(_ reason: String) -> String {
    switch reason {
    case "attachment_crossed_threshold": return "想念推动了主动靠近"
    case "libido_crossed_threshold": return "性欲推动了主动靠近"
    case "intimacy_crossed_threshold": return "亲密欲推动了主动靠近"
    case "scheduled_heartbeat": return "定时心跳"
    case "heartbeat": return "心跳唤醒"
    default: return reason.isEmpty ? "未记录原因" : reason
    }
}


private enum CoveAudioComposerMode: String, CaseIterable, Identifiable {
    case note, call
    var id: String { rawValue }
    var title: String { self == .note ? "语音条" : "实时通话" }
    var icon: String { self == .note ? "waveform" : "phone.waveform.fill" }
}

private struct CoveAudioModePicker: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: CoveAudioComposerMode
    let disabled: Bool
    let reduceMotion: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CoveAudioComposerMode.allCases) { mode in
                let selected = selection == mode
                Button {
                    guard !selected else { return }
                    onSelect()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selection = mode }
                } label: {
                    Label(mode.title, systemImage: mode.icon)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(selected ? Color.primary : CoveStyle.secondaryText)
                        .background {
                            Capsule()
                                .fill(selected ? Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.18 : 0.72) : .clear)
                                .shadow(color: .black.opacity(selected ? (colorScheme == .dark ? 0.12 : 0.06) : 0), radius: 5, y: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("chat.audioMode.\(mode.rawValue)")
            }
        }
        .padding(3)
        .background(.ultraThinMaterial.opacity(0.5), in: Capsule())
        .disabled(disabled)
    }
}

/// Owns the only view subscription to live typed text. The app-wide CoveStore
/// deliberately does not publish keystrokes, so history, tabs and panels stay
/// outside the input invalidation domain.
private struct CoveTextComposerControls: View {
    @ObservedObject var draftState: CoveComposerDraftState
    @FocusState.Binding var focused: Bool
    let showingStickers: Bool
    let reduceMotion: Bool
    let voiceSending: Bool
    let hasVoiceDraft: Bool
    let canSend: Bool
    let openStickers: () -> Void
    let toggleVoiceMode: () -> Void
    let send: () -> Void
    let frameChanged: (CGRect) -> Void

    private var hasText: Bool {
        !draftState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                TextField("说给 Assistant 听…", text: $draftState.text, axis: .vertical)
                    .lineLimit(1...6).font(.body).focused($focused)
                    .padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 10)
                    .accessibilityLabel("消息输入").accessibilityIdentifier("chat.input")
                    .disabled(hasVoiceDraft)
                CoveInputModeButton(stickerMode: showingStickers, reduceMotion: reduceMotion, action: openStickers)
                    .frame(width: 44, height: 44).disabled(hasVoiceDraft)
            }
            .modifier(CoveGlassControlSurface(shape: RoundedRectangle(cornerRadius: 22)))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameChanged($0) }

            CoveVoiceModeButton(voiceMode: false, disabled: voiceSending, action: toggleVoiceMode)
                .frame(width: 44, height: 44).contentShape(Rectangle()).disabled(voiceSending)

            if hasText {
                CoveComposerNativeButton(isBusy: false, disabled: !canSend, reduceMotion: reduceMotion, action: send)
                    .frame(width: 44, height: 44).disabled(!canSend)
            }
        }
    }
}

private struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("cove.sendHaptics") private var sendHaptics = true
    @State private var sendFeedback = 0
    @EnvironmentObject private var store: CoveStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var composerFocused: Bool
    @State private var nearBottom = true
    @State private var farFromBottom = false
    @StateObject private var attachmentComposer = CoveAttachmentComposer()
    @State private var showingAttachments = false
    @State private var showingSystemPhotos = false
    @State private var selectedSystemPhotos: [PHPickerResult] = []
    @State private var photoDraftGeneration: UUID?
    @State private var pendingFileImporter = false
    @State private var showingFileImporter = false
    @State private var showingStickers = false
    @State private var uploadCount = 0
    @State private var isUploading = false
    @State private var showingConversations = false
    @State private var showingTerminal = false
    @State private var showingSearch = false
    @State private var showingVoice = false
    @StateObject private var voiceRecorder = CoveVoiceRecorder()
    @State private var voiceSending = false
    @State private var voiceInputMode = false
    @State private var audioComposerMode: CoveAudioComposerMode = .note
    @State private var showingRealtime = false
    @State private var voiceConversationID = ""
    @State private var attachmentError: String?
    @State private var historyInteracting = false
    @State private var tailScrollTask: Task<Void, Never>?
    @State private var renderWindow = CoveChatRenderWindow()
    @State private var historyNavigationInProgress = false
    @State private var composerFrame: CGRect = .zero
    @State private var outgoingArrival: CoveOutgoingArrival?
    @State private var returnToKeyboardAfterStickers = false
    private var changeKey: String {
        guard let last = store.messages.last else { return "empty" }
        return "\(store.messages.count)-\(last.id)-\(last.text.count)-\(last.status)"
    }

    var body: some View {
        chatHistory
        .onDisappear {
            tailScrollTask?.cancel(); voiceRecorder.cancel()
            // CCC only reclaims an expanded history window while off screen.
            renderWindow = CoveChatRenderWindow()
            historyNavigationInProgress = false
        }
        .onChange(of: store.activeConversationID) { _, _ in voiceRecorder.cancel(); showingVoice = false }
        .onChange(of: store.selectedTab) { _, _ in voiceRecorder.cancel(); showingVoice = false }
        .onChange(of: showingVoice) { _, showing in if !showing { voiceRecorder.cancel() } }
        // Synchronous publisher fences invalidate pending permission/bytes even
        // when a replacement endpoint reuses the same conversation identifier.
        .onReceive(store.$serverURL.dropFirst()) { _ in cancelVoiceContext() }
        .onReceive(store.$accessToken.dropFirst()) { _ in cancelVoiceContext() }
        .onReceive(store.$previewMode.dropFirst()) { _ in cancelVoiceContext() }
        .onReceive(store.$connectionStatus.dropFirst()) { status in
            if status == "正在连接…" { cancelVoiceContext() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in voiceRecorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { voiceRecorder.cancel() }
        }
        // Paint behind both native navigation and the composer, using the same
        // wallpaper coordinates as the root behind the native floating tab bar.
        .background { CoveChatWallpaperView().ignoresSafeArea() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Assistant").font(.subheadline.weight(.semibold))
                    Text(store.isBusy ? "正在回复…" : store.connectionStatus)
                        .font(.caption2).foregroundStyle(CoveStyle.secondaryText).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarLeading) { searchButton }
            ToolbarItemGroup(placement: .topBarTrailing) {
                terminalButton
                conversationButton
            }
        }
        .sheet(isPresented: $showingStickers, onDismiss: {
            if returnToKeyboardAfterStickers { composerFocused = true }
            returnToKeyboardAfterStickers = false
        }) {
            CoveStickerPicker(onSend: { nearBottom = true }, onReturnToKeyboard: {
                returnToKeyboardAfterStickers = true
                showingStickers = false
            })
            .accessibilityIdentifier("stickers.sheet")
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingConversations) { ConversationSheet() }
        .sheet(isPresented: $showingTerminal) {
            CoveTerminalModeContainer(shellAPI: store.shellAPI(conversationID: store.activeConversationID)) {
                CoveTerminalView()
            }
                .id("\(store.appActivityScopeID)|\(store.activeConversationID)")
        }
        .sheet(isPresented: $showingSearch) { MessageSearchSheet() }
        .sheet(isPresented: $showingRealtime) { CoveRealtimeView() }
        .sheet(isPresented: $showingVoice) {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("发送你真实的声音，不必先转成文字。录好后可以试听，再决定发送。")
                        .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    CoveVoiceComposer(recorder: voiceRecorder, send: sendVoice)
                    Spacer()
                }.padding()
                    .navigationTitle("语音消息").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showingVoice = false } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭语音")
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSystemPhotos, onDismiss: {
            let results = selectedSystemPhotos
            selectedSystemPhotos = []
            guard photoDraftGeneration == attachmentComposer.generation,
                  attachmentComposer.conversationID == store.activeConversationID else { return }
            photoDraftGeneration = nil
            guard !results.isEmpty else { attachmentComposer.cancel(); return }
            // Present review only after the native browser has gone away.
            attachmentComposer.importPhotos(results.map { result in
                { try await CoveSystemPhotoPicker.loadPhoto(result) }
            })
            showingAttachments = true
        }) {
            CoveSystemPhotoPicker(selectionLimit: 10) { results in
                selectedSystemPhotos = results
                showingSystemPhotos = false
            }
        }
        .sheet(isPresented: $showingAttachments, onDismiss: {
            if pendingFileImporter {
                pendingFileImporter = false
                // Native Files is presented from ChatView, never stacked over
                // a second attachment sheet (important for iCloud navigation).
                Task { @MainActor in
                    await Task.yield()
                    showingFileImporter = true
                }
            } else {
                attachmentComposer.cancel()
            }
        }) {
            CoveAttachmentPicker(model: attachmentComposer, onBrowseFiles: {
                pendingFileImporter = true
            }, onSend: { files, caption, conversationID in
                nearBottom = true
                return await store.sendAttachments(files: files, caption: caption,
                    expectedConversationID: conversationID, waitForDelivery: false)
            })
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let generation = attachmentComposer.generation
            Task { @MainActor in
                isUploading = true
                attachmentComposer.preparing = true
                defer {
                    isUploading = false
                    attachmentComposer.preparing = false
                    if generation == attachmentComposer.generation {
                        // Return to the SAME selection/caption, not another
                        // "choose photos/files" or review screen.
                        showingAttachments = !attachmentComposer.choices.isEmpty || attachmentComposer.failure != nil
                        if !showingAttachments { attachmentComposer.cancel() }
                    }
                }
                do {
                    let urls = try result.get()
                    guard !urls.isEmpty else { return }
                    guard attachmentComposer.choices.count + urls.count <= 10 else { throw CoveAttachmentError.tooMany }
                    uploadCount = urls.count
                    let files = try await CoveAttachmentFiles.readSelected(urls)
                    guard generation == attachmentComposer.generation,
                          attachmentComposer.conversationID == store.activeConversationID else {
                        throw CoveError.message("对话已切换，请在当前对话重新选择附件。")
                    }
                    try attachmentComposer.add(files)
                    attachmentComposer.failure = nil
                } catch {
                    let nsError = error as NSError
                    if nsError.code != NSUserCancelledError { attachmentComposer.failure = error.localizedDescription }
                }
            }
        }
        .alert("附件未发送", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("好") { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
        .task(id: outgoingArrival?.id) {
            guard let id = outgoingArrival?.id else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, outgoingArrival?.id == id else { return }
            outgoingArrival = nil
        }
    }

    private var chatHistory: some View {
        ScrollViewReader { proxy in
          let range = renderWindow.range(in: store.messages, conversationID: store.activeConversationID)
          let includesLatest = range.upperBound == store.messages.count
          VStack(spacing: 0) {
            CoveTravelEntry(compact: true).padding(.horizontal, 16)
            ScrollView {
                ChatHistoryRows(messages: store.messages, visibleRange: range,
                                isConnected: store.isConnected, reactingMessageIDs: store.reactingMessageIDs,
                                healthRequests: store.previewMode || !includesLatest ? [] : store.healthRequests.filter { $0.conversationID == store.activeConversationID },
                                deviceRequests: store.previewMode || !includesLatest ? [] : store.deviceRequests.filter { $0.conversationID == store.activeConversationID },
                                outgoingArrival: outgoingArrival,
                                onEarlier: { expandHistory(proxy, earlier: true) },
                                onLater: { expandHistory(proxy, earlier: false) },
                                onConnect: { store.selectedTab = 4 },
                                onReply: { id in
                                    store.replyToMessageID = id
                                    composerFocused = true
                                },
                                onRetry: { store.retry($0) },
                                onLike: { message, liked in Task { await store.setMessageLiked(message, liked: liked) } })
                    .equatable()
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)

            }
            .contentShape(Rectangle())
            .refreshable { await expandHistoryAndWait(proxy, earlier: true) }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chat.history")
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Telegram updates history insets with the input-panel layout.
            // SwiftUI's size-change anchor performs the corresponding viewport
            // adjustment; an old-history reader keeps their existing offset.
            .defaultScrollAnchor(nearBottom ? .bottom : nil, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                // A native UITextView does not consume SwiftUI's ancestor tap
                // the way TextField does. Only history taps may dismiss input.
                guard composerFrame.minY > 0, value.location.y < composerFrame.minY else { return }
                composerFocused = false
            })
            .onScrollPhaseChange { previous, phase, context in
                // A wallpaper tap can enter tracking without scrolling. Only an
                // actual drag cancels the previously captured bottom alignment.
                historyInteracting = phase == .interacting || phase == .decelerating
                if phase == .interacting {
                    renderWindow.pinForReading(store.messages, conversationID: store.activeConversationID)
                }
                if phase == .idle && (previous == .interacting || previous == .decelerating) {
                    // The final geometry callback may arrive after idle. Capture
                    // the settled position here instead of losing a manual
                    // return to the bottom when the interaction guard closes.
                    if !historyNavigationInProgress {
                        nearBottom = includesLatest && context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 90
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 90
            } action: { _, bottom in
                // Pinning is user intent, not a keyboard-notification race.
                // Resizing the viewport must never turn a bottom reader into
                // an old-history reader before its new inset has settled.
                // Geometry can settle after the phase becomes idle. Always
                // recognize returning to the bottom, but only a real history
                // gesture may opt out of following it.
                guard !historyNavigationInProgress else { return }
                if bottom && includesLatest { nearBottom = true }
                else if historyInteracting { nearBottom = false }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.height.rounded()
            } action: { previousHeight, height in
                guard previousHeight > 0, height != previousHeight,
                      !historyInteracting, nearBottom else { return }
                // Like Telegram's inset transaction, respond to actual history
                // layout, not a timer or a keyboard notification's guessed frame.
                alignLatest(proxy)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 240
            } action: { _, isFar in
                farFromBottom = isFar
            }
            .onChange(of: changeKey) {
                renderWindow.prepare(store.messages, conversationID: store.activeConversationID)
                if nearBottom {
                    alignLatest(proxy)
                }
            }
            .onChange(of: store.activeConversationID) {
                tailScrollTask?.cancel()
                historyNavigationInProgress = false
                renderWindow = CoveChatRenderWindow()
                renderWindow.prepare(store.messages, conversationID: store.activeConversationID)
                outgoingArrival = nil
                if store.locateInFlightMessageID != nil {
                    // A search locate owns the target scroll position; aligning
                    // to the bottom here would cover it before it lands.
                    nearBottom = false
                } else {
                    nearBottom = true
                    farFromBottom = false
                    alignLatest(proxy)
                }
            }
            .onChange(of: store.latestMessageRequest) { _, request in
                guard request != nil else { return }
                tailScrollTask?.cancel()
                historyNavigationInProgress = false
                historyInteracting = false
                alignLatest(proxy)
            }
            .onChange(of: store.scrollRequest) { _, request in
                guard let request else { return }
                locateHistory(request, proxy: proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                // Keep this outside the lazy rows and above the composer. The
                // threshold avoids a floating button for tiny history nudges;
                // nearBottom also suppresses it during keyboard re-layout.
                if store.canReturnToCurrentChat {
                    Button {
                        tailScrollTask?.cancel()
                        historyNavigationInProgress = false
                        historyInteracting = false
                        Task { @MainActor in
                            await store.returnFromMessageSearch()
                            alignLatest(proxy)
                        }
                    } label: {
                        Label("返回当前聊天", systemImage: "arrow.down.to.line")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .modifier(CoveGlassControlSurface(shape: Capsule()))
                    }
                    .buttonStyle(CoveChatPressStyle())
                    .disabled(store.isLocatingMessage)
                    .accessibilityIdentifier("chat.returnFromSearch")
                    .padding(.trailing, 12).padding(.bottom, 10)
                } else if !nearBottom && (farFromBottom || !includesLatest) {
                    Button { alignLatest(proxy) } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(CoveStyle.teal)
                            .frame(width: 44, height: 44)
                            .modifier(CoveGlassControlSurface(shape: Circle()))
                    }
                    .buttonStyle(CoveChatPressStyle())
                    .accessibilityLabel("回到最新消息")
                    .accessibilityIdentifier("chat.jumpToLatest")
                    .padding(.trailing, 12).padding(.bottom, 10)
                }
            }
            // Use a real, shorter history viewport, not an inset over a full-
            // height scroll view. The keyboard and growing editor now resize
            // the same layout whose bottom we anchor the latest message to.
            // Eager offscreen rows must never win hit testing over the input
            // panel after history expands. Keep this sibling above the scroll.
            composer(proxy: proxy).zIndex(1)
          }
          .onAppear {
              historyInteracting = false
              renderWindow.prepare(store.messages, conversationID: store.activeConversationID)
              if let request = store.scrollRequest, store.messageHighlight != nil {
                  locateHistory(request, proxy: proxy)
              } else {
                  // Offscreen compaction needs a fresh anchor on re-entry, not
                  // the old expanded window's (now invalid) content offset.
                  alignLatest(proxy)
              }
          }
          .onChange(of: composerFrame.minY) { previous, current in
              guard previous > 0, current > 0, previous != current,
                    nearBottom, !historyInteracting else { return }
              alignLatest(proxy)
          }
        }
    }

    private func locateHistory(_ request: CoveScrollRequest, proxy: ScrollViewProxy) {
        nearBottom = false
        tailScrollTask?.cancel()
        historyNavigationInProgress = true
        renderWindow.locate(request.messageID, in: store.messages, conversationID: store.activeConversationID)
        let conversationID = store.activeConversationID
        tailScrollTask = Task { @MainActor in
            // Materialize the bounded eager window before targeting its row.
            await Task.yield()
            guard !Task.isCancelled, conversationID == store.activeConversationID,
                  store.scrollRequest == request else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(request.messageID, anchor: .center) }
            store.completeScrollRequest(request)
            await Task.yield()
            if !Task.isCancelled { historyNavigationInProgress = false }
        }
    }

    private func alignLatest(_ proxy: ScrollViewProxy) {
        guard !historyNavigationInProgress else { return }
        nearBottom = true
        renderWindow.latest(store.messages, conversationID: store.activeConversationID)
        tailScrollTask?.cancel()
        let conversationID = store.activeConversationID
        tailScrollTask = Task { @MainActor in
            // Coalesce changes after the eager rows enter the view tree.
            // No lazy estimated-height sentinel or on-send window compaction.
            await Task.yield()
            guard !Task.isCancelled, nearBottom, !historyInteracting,
                  conversationID == store.activeConversationID,
                  store.locateInFlightMessageID == nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
    }

    private func expandHistory(_ proxy: ScrollViewProxy, earlier: Bool) {
        guard !historyNavigationInProgress else { return }
        tailScrollTask?.cancel()
        tailScrollTask = Task { @MainActor in await expandHistoryAndWait(proxy, earlier: earlier) }
    }

    @MainActor private func expandHistoryAndWait(_ proxy: ScrollViewProxy, earlier: Bool) async {
        guard !historyNavigationInProgress else { return }
        let range = renderWindow.range(in: store.messages, conversationID: store.activeConversationID)
        guard !range.isEmpty, earlier ? range.lowerBound > 0 : range.upperBound < store.messages.count else { return }
        let anchor = store.messages[earlier ? range.lowerBound : range.upperBound - 1].id
        let conversationID = store.activeConversationID
        nearBottom = false
        historyNavigationInProgress = true
        if earlier { renderWindow.earlier(store.messages, conversationID: conversationID) }
        else { renderWindow.later(store.messages, conversationID: conversationID) }
        await Task.yield()
        guard !Task.isCancelled, conversationID == store.activeConversationID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(anchor, anchor: earlier ? .top : .bottom) }
        await Task.yield()
        if !Task.isCancelled { historyNavigationInProgress = false }
    }

    // Native bar buttons provide the hit area; 44pt label frames get additional
    // glass padding on iOS 26 and squeeze the centered principal title.
    private var terminalButton: some View {
        Button { composerFocused = false; showingTerminal = true } label: {
            Image(systemName: "terminal").font(.body)
        }.accessibilityLabel("终端").accessibilityIdentifier("chat.terminal")
    }

    private var searchButton: some View {
        Button { composerFocused = false; showingSearch = true } label: {
            Label("记录", systemImage: "magnifyingglass").font(.subheadline)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }.tint(Color(uiColor: .secondaryLabel))
            .accessibilityLabel("聊天记录：搜索与日历").accessibilityIdentifier("chat.search")
    }

    private var conversationButton: some View {
        Menu {
            Button("聊天记录", systemImage: "calendar") { composerFocused = false; showingSearch = true }
            Button("返回当前聊天", systemImage: "arrow.down.to.line") {
                composerFocused = false
                Task { await store.returnFromMessageSearch() }
            }.disabled(store.isLocatingMessage)
                .accessibilityIdentifier("chat.menu.returnToCurrent")
            Button("会话管理", systemImage: "bubble.left.and.bubble.right") { showingConversations = true }
            Button("实时通话", systemImage: "phone.fill") {
                composerFocused = false
                showingRealtime = true
            }.disabled(!store.canSendMessages)
            if store.isBusy {
                Button("停止回复及待处理回复", systemImage: "stop.fill") {
                    Task { await store.interrupt() }
                }.accessibilityIdentifier("chat.stop")
            }
        } label: {
            Image(systemName: "ellipsis").font(.body)
        }.accessibilityLabel("会话与通话").accessibilityIdentifier("chat.conversations")
    }

    private func cancelVoiceContext() {
        voiceRecorder.cancel()
        showingVoice = false
    }

    private func sendVoice(_ data: Data, _ filename: String, _ mime: String, _ caption: String) async throws {
        let retainedDraft = store.draft
        let conversationID = voiceConversationID
        guard await store.sendAttachments(files: [.init(data: data, filename: filename, mime: mime)],
            caption: "", expectedConversationID: voiceConversationID, waitForDelivery: false) else {
            throw CoveError.message(store.errorMessage ?? "语音未加入发件箱，请重试。")
        }
        if store.activeConversationID == conversationID, store.draft.isEmpty { store.draft = retainedDraft }
        nearBottom = true
        showingVoice = false
    }

    private var voiceHoldDisabled: Bool {
        store.previewMode || !store.canSendMessages || voiceSending || (voiceRecorder.preview != nil && !voiceRecorder.isHolding)
    }

    private var voiceHoldTitle: String {
        if voiceSending { return "正在保存语音…" }
        if voiceRecorder.isRequestingPermission { return "等待麦克风权限…" }
        if voiceRecorder.isRecording { return "松开发送  \(coveVoiceTime(voiceRecorder.duration))  ·  上滑取消" }
        return "按住说话"
    }

    private func startVoiceHold() {
        guard !store.previewMode, !voiceRecorder.hasDraft, !voiceSending else { return }
        voiceConversationID = store.activeConversationID
        composerFocused = false
        voiceRecorder.startFromExplicitAction()
    }

    private func showAccessibleVoiceRecorder() {
        guard !store.previewMode, !voiceRecorder.hasDraft, !voiceSending else { return }
        voiceConversationID = store.activeConversationID
        composerFocused = false
        showingVoice = true
    }

    private func finishVoiceHold() {
        guard !voiceSending, let data = voiceRecorder.finishHoldForSending() else { return }
        queueVoice(data)
    }

    private func queueVoice(_ data: Data) {
        guard !voiceSending else { return }
        let conversationID = voiceConversationID
        let retainedDraft = store.draft
        voiceSending = true
        Task { @MainActor in
            defer { voiceSending = false }
            guard store.activeConversationID == conversationID, voiceRecorder.preview == data else { return }
            guard await store.sendAttachments(files: [.init(data: data, filename: "voice-\(UUID().uuidString).m4a", mime: "audio/mp4")],
                caption: "", expectedConversationID: conversationID, waitForDelivery: false) else {
                if voiceRecorder.preview == data { voiceRecorder.errorMessage = store.errorMessage ?? "语音未加入发件箱，录音已保留，请重试。" }
                return
            }
            if voiceRecorder.preview == data { _ = voiceRecorder.consumePreview() }
            if store.activeConversationID == conversationID, store.draft.isEmpty { store.draft = retainedDraft }
            nearBottom = true
        }
    }

    @ViewBuilder private func composer(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if let messageID = store.replyToMessageID, let message = store.messages.first(where: { $0.id == messageID }) {
                HStack(spacing: 10) {
                    Rectangle().fill(CoveStyle.teal).frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("回复 \(message.role == "user" ? "用户" : "Assistant")").font(.caption.weight(.semibold)).foregroundStyle(CoveStyle.teal)
                        Text(message.previewText()).font(.caption).foregroundStyle(CoveStyle.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Button { store.replyToMessageID = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("取消引用")
                }.frame(height: 44).padding(.leading, 12)
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
            }
            if isUploading || store.attachmentUploadStatus != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(store.attachmentUploadStatus ?? "正在准备 \(uploadCount) 个附件…").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8).accessibilityIdentifier("chat.attachmentProgress")
            }
            if voiceRecorder.isRecording && !showingVoice {
                CoveVoiceHoldFeedback(levels: voiceRecorder.levels)
                    .padding(.horizontal, 60).padding(.top, 6)
            }
            if (voiceRecorder.preview != nil || voiceRecorder.errorMessage != nil) && !showingVoice {
                CoveVoiceComposer(recorder: voiceRecorder, send: sendVoice)
                    .padding(.horizontal, 12).padding(.top, 8)
                    .accessibilityIdentifier("chat.voiceDraft").disabled(voiceSending)
            }
            if voiceInputMode {
                CoveAudioModePicker(selection: $audioComposerMode,
                    disabled: voiceSending || voiceRecorder.hasDraft || voiceRecorder.isRecording,
                    reduceMotion: reduceMotion,
                    onSelect: { voiceRecorder.cancel() })
                .padding(.horizontal, 56).padding(.top, 7).padding(.bottom, 3)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button {
                        composerFocused = false
                        attachmentComposer.reset(conversationID: store.activeConversationID, caption: store.draft)
                        selectedSystemPhotos = []
                        photoDraftGeneration = attachmentComposer.generation
                        if store.previewMode {
                            #if DEBUG && targetEnvironment(simulator)
                            if ProcessInfo.processInfo.arguments.contains("--test-native-photo-picker") {
                                showingSystemPhotos = true
                            } else { showingAttachments = true }
                            #else
                            showingAttachments = true
                            #endif
                        } else {
                            showingSystemPhotos = true
                        }
                    } label: {
                        Label("照片", systemImage: "photo")
                    }.accessibilityIdentifier("chat.attachments.photos")
                    Button {
                        composerFocused = false
                        attachmentComposer.reset(conversationID: store.activeConversationID, caption: store.draft)
                        attachmentComposer.category = "files"
                        if store.previewMode {
                            #if DEBUG && targetEnvironment(simulator)
                            if ProcessInfo.processInfo.arguments.contains("--test-native-file-picker") {
                                showingFileImporter = true
                            } else { showingAttachments = true }
                            #else
                            showingAttachments = true
                            #endif
                        } else { showingFileImporter = true }
                    } label: {
                        Label("文件", systemImage: "doc")
                    }.accessibilityIdentifier("chat.attachments.files")
                } label: {
                    if isUploading { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "paperclip").font(.title3).frame(width: 44, height: 44) }
                }.buttonStyle(CoveChatPressStyle())
                    .disabled(voiceRecorder.hasDraft || isUploading || (!store.canSendMessages && !store.previewMode))
                    .accessibilityLabel("添加附件")
                    .accessibilityHint("选择照片或文件")
                    .accessibilityIdentifier("chat.attachments")
                if voiceInputMode {
                    audioInputControl
                    CoveVoiceModeButton(voiceMode: voiceInputMode, disabled: voiceSending) {
                        voiceRecorder.cancel()
                        voiceInputMode.toggle()
                        composerFocused = !voiceInputMode
                    }.frame(width: 44, height: 44)
                        .contentShape(Rectangle()).disabled(voiceSending)
                } else {
                    CoveTextComposerControls(
                        draftState: store.composerDraft,
                        focused: $composerFocused,
                        showingStickers: showingStickers,
                        reduceMotion: reduceMotion,
                        voiceSending: voiceSending,
                        hasVoiceDraft: voiceRecorder.hasDraft,
                        canSend: store.canSendMessages || store.isLocalSendQA,
                        openStickers: {
                        returnToKeyboardAfterStickers = false
                        composerFocused = false
                        showingStickers = true
                        },
                        toggleVoiceMode: {
                            voiceRecorder.cancel()
                            voiceInputMode = true
                            composerFocused = false
                        },
                        send: {
                            // Sending and cancelling are different intents. A running
                            // reply never takes ownership of the user's send button.
                            nearBottom = true
                            let previousCount = store.messages.count
                            store.send()
                            if store.messages.count > previousCount, let message = store.messages.last, message.role == "user" {
                                sendFeedback += 1
                                outgoingArrival = .init(id: message.id, origin: composerFrame)
                            }
                        },
                        frameChanged: { composerFrame = $0 }
                    )
                    .sensoryFeedback(.impact(weight: .light, intensity: 0.35), trigger: sendFeedback) { _, _ in sendHaptics }
                }
            }.padding(.horizontal, 4).padding(.vertical, 4)
        }
        .background(.ultraThinMaterial.opacity(0.55))
    }

    @ViewBuilder private var audioInputControl: some View {
        if audioComposerMode == .note {
            CoveVoiceHoldButton(title: voiceHoldTitle, recording: voiceRecorder.isRecording,
                disabled: voiceHoldDisabled,
                allowsNewRecording: !store.previewMode && store.canSendMessages && !voiceSending && !voiceRecorder.hasDraft,
                begin: startVoiceHold, cancel: { voiceRecorder.cancel() }, end: finishVoiceHold,
                accessibleRecord: showAccessibleVoiceRecorder)
                .frame(maxWidth: .infinity).frame(height: 44)
                .modifier(CoveGlassControlSurface(shape: RoundedRectangle(cornerRadius: 22)))
                .disabled(voiceHoldDisabled)
        } else {
            Button {
                composerFocused = false
                showingRealtime = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "phone.waveform.fill")
                    Text("开始实时通话").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .modifier(CoveGlassControlSurface(shape: RoundedRectangle(cornerRadius: 22)))
            .disabled(store.previewMode || !store.canSendMessages || store.isBusy)
            .accessibilityHint("打开与 Assistant 的实时语音通话")
            .accessibilityIdentifier("chat.realtime")
        }
    }

}

private struct ChatHistoryRows: View, Equatable {
    let messages: [ChatMessage]
    let visibleRange: Range<Int>
    let isConnected: Bool
    let reactingMessageIDs: Set<String>
    let healthRequests: [CoveHealthRequest]
    let deviceRequests: [CoveDeviceRequest]
    let outgoingArrival: CoveOutgoingArrival?
    var onEarlier: () -> Void
    var onLater: () -> Void
    var onConnect: () -> Void
    var onReply: (String) -> Void
    var onRetry: (ChatMessage) -> Void
    var onLike: (ChatMessage, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.visibleRange == rhs.visibleRange && lhs.isConnected == rhs.isConnected
            && lhs.reactingMessageIDs == rhs.reactingMessageIDs
            && lhs.healthRequests == rhs.healthRequests
            && lhs.deviceRequests == rhs.deviceRequests
            && lhs.outgoingArrival == rhs.outgoingArrival
    }

    var body: some View {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Match CCC: real heights for a small eager window, not an estimated
        // height for the entire variable-height Markdown conversation.
        VStack(alignment: .leading, spacing: 4) {
            if visibleRange.lowerBound > 0 {
                Button("载入更早消息", action: onEarlier)
                    .font(.footnote).frame(maxWidth: .infinity).frame(minHeight: 44)
                    .accessibilityIdentifier("chat.loadEarlier")
            }
            if messages.isEmpty {
                VStack(spacing: 10) {
                    Avatar(name: "Assistant", size: 44)
                    Text("想说什么，就从这里开始。").font(.subheadline.weight(.medium))
                    Text(isConnected ? "消息会保存在你的私有服务。" : "先连接服务，再继续我们的对话。")
                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    if !isConnected { Button("连接 Assistant", action: onConnect).buttonStyle(.bordered).frame(minHeight: 44) }
                }.frame(maxWidth: .infinity).padding(.vertical, 48)
            }
            ForEach(Array(messages[visibleRange].enumerated()), id: \.element.id) { offset, message in
                let index = visibleRange.lowerBound + offset
                let previous = index > 0 ? messages[index - 1] : nil
                let next = index + 1 < messages.count ? messages[index + 1] : nil
                let firstInGroup = previous.map { !CoveChatPresentation.joinsGroup($0, message) } ?? true
                let lastInGroup = next.map { !CoveChatPresentation.joinsGroup(message, $0) } ?? true
                if index == visibleRange.lowerBound || previous == nil || !Calendar.current.isDate(previous!.createdAt, inSameDayAs: message.createdAt) {
                    Text(message.createdAt, format: .dateTime.month().day().weekday())
                        .font(.caption2.weight(.medium)).foregroundStyle(CoveStyle.dateText)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(CoveStyle.dateBackground, in: Capsule())
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                ChatBubble(message: message,
                           quote: CoveChatPresentation.displayedQuote(message, messagesByID: byID),
                           showName: firstInGroup, isLastInGroup: lastInGroup,
                           arrivalOrigin: outgoingArrival?.id == message.id ? outgoingArrival?.origin : nil,
                           isReacting: reactingMessageIDs.contains(message.id),
                           onReply: onReply, onRetry: onRetry, onLike: onLike)
                    .id(message.id)
            }
            if visibleRange.upperBound < messages.count {
                Button("载入后续消息", action: onLater)
                    .font(.footnote).frame(maxWidth: .infinity).frame(minHeight: 44)
                    .accessibilityIdentifier("chat.loadLater")
            }
            // Messages, request cards and bottom anchor share real layout.
            ForEach(Array(healthRequests.filter { $0.status == "pending" }.prefix(20).reversed())) { item in
                CoveHealthRequestCard(item: item).padding(.horizontal, 2).padding(.vertical, 3)
            }
            ForEach(Array(deviceRequests.filter(\.showsInChat).prefix(20).reversed())) { item in
                CoveDeviceRequestCard(item: item).padding(.horizontal, 2).padding(.vertical, 3)
            }
            Color.clear.frame(height: 1).id("chat-bottom")
        }
    }
}

enum CoveChatPresentation {
    static func joinsGroup(_ first: ChatMessage, _ second: ChatMessage) -> Bool {
        first.role == second.role && second.createdAt.timeIntervalSince(first.createdAt) >= 0
            && second.createdAt.timeIntervalSince(first.createdAt) <= 120
            && Calendar.current.isDate(first.createdAt, inSameDayAs: second.createdAt)
    }

    static func displayedQuote(_ message: ChatMessage, messagesByID: [String: ChatMessage]) -> ChatMessage? {
        // The service links an assistant response to its originating message.
        // Explicit user quote replies are the only quotes shown in the bubble.
        guard message.role == "user", let replyID = message.replyTo else { return nil }
        return messagesByID[replyID]
    }
}

private struct CoveBubbleWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let proposed = proposal.width ?? 420
        let width = proposed.isFinite ? max(1, min(proposed, 420)) : 420
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct CoveBubbleBackground: View {
    let outgoing: Bool
    let firstInGroup: Bool
    let lastInGroup: Bool
    let fill: Color

    var body: some View {
        fill.mask {
            Canvas { context, size in
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                // Geometry follows TelegramPresentationData's
                // ChatMessageBubbleImages.messageBubbleImage: a 33pt source
                // corner, a 6pt extension, and the lower ellipse minus the
                // upper ellipse. Only the group-ending message has a tail.
                // Neighbor corners use the theme's 16pt / 8pt radii.
                if !outgoing {
                    context.translateBy(x: size.width, y: 0)
                    context.scaleBy(x: -1, y: 1)
                }
                let radius = min(CGFloat(16), size.height / 2)
                let joined = min(CGFloat(8), size.height / 2)
                let tail: CGFloat = lastInGroup ? 6 : 0
                let bodyRect = CGRect(x: 0, y: 0, width: max(0, size.width - tail), height: size.height)
                let body = UnevenRoundedRectangle(
                    topLeadingRadius: radius,
                    bottomLeadingRadius: radius,
                    bottomTrailingRadius: lastInGroup ? radius : joined,
                    topTrailingRadius: firstInGroup ? radius : joined,
                    style: .circular
                ).path(in: bodyRect)
                context.drawLayer { layer in
                    layer.fill(body, with: .color(.white))
                    guard lastInGroup else { return }
                    let origin = CGPoint(x: bodyRect.maxX - 33, y: size.height - 33)
                    let lower = CGRect(x: origin.x + 24, y: origin.y + 16, width: 27, height: 17)
                    var tailPath = Path()
                    tailPath.move(to: CGPoint(x: lower.minX, y: lower.midY))
                    tailPath.addQuadCurve(to: CGPoint(x: lower.midX, y: lower.maxY),
                                          control: CGPoint(x: lower.minX, y: lower.maxY))
                    tailPath.addQuadCurve(to: CGPoint(x: lower.maxX, y: lower.midY),
                                          control: CGPoint(x: lower.maxX, y: lower.maxY))
                    tailPath.closeSubpath()
                    layer.fill(tailPath, with: .color(.white))
                    // Telegram fills this bridge before subtracting the upper
                    // ellipse; without it the rounded body exposes a notch at
                    // the tail's root instead of one continuous contour.
                    layer.fill(Path(CGRect(x: origin.x + 16.5, y: origin.y + 16,
                                           width: 16.5, height: 9)), with: .color(.white))
                    layer.blendMode = .destinationOut
                    layer.fill(Path(ellipseIn: CGRect(x: origin.x + 33, y: origin.y + 14,
                                                     width: 23, height: 21)), with: .color(.white))
                }
            }
        }.allowsHitTesting(false)
    }
}

private struct CoveOutlinedBubbleBackground: View {
    let outgoing: Bool
    let firstInGroup: Bool
    let lastInGroup: Bool
    let fill: Color
    let outline: Color

    // CCC uses a 0.5pt centered hairline: only half of it sits outside the
    // opaque bubble. This outline is built outside the existing mask, so use
    // 0.25pt here to keep the same restrained visible weight.
    private let width: CGFloat = 0.25

    var body: some View {
        let diagonal = width / sqrt(2)
        let offsets = [
            CGSize(width: -width, height: 0), CGSize(width: width, height: 0),
            CGSize(width: 0, height: -width), CGSize(width: 0, height: width),
            CGSize(width: -diagonal, height: -diagonal), CGSize(width: diagonal, height: -diagonal),
            CGSize(width: -diagonal, height: diagonal), CGSize(width: diagonal, height: diagonal)
        ]
        ZStack {
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, offset in
                    CoveBubbleBackground(outgoing: outgoing, firstInGroup: firstInGroup,
                                         lastInGroup: lastInGroup, fill: outline)
                        .offset(x: offset.width, y: offset.height)
                }
            }
            .compositingGroup()
            .opacity(0.35)
            CoveBubbleBackground(outgoing: outgoing, firstInGroup: firstInGroup,
                                 lastInGroup: lastInGroup, fill: fill)
        }
        .allowsHitTesting(false)
    }
}

/// CCC ThinkingChip's Telegram presentation, using Cove's semantic colors.
private struct CoveLittleThoughtsChip: View {
    let text: String
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var preview: String {
        String(text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CoveStyle.accent.opacity(colorScheme == .dark ? 0.38 : 0.42))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("little thoughts")
                            .font(.system(size: 12, weight: .medium, design: .serif)).italic()
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold, design: .serif))
                        if !expanded {
                            Text(preview)
                                .font(.system(size: 12, design: .serif)).italic()
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    if expanded {
                        Text(text)
                            .font(.system(size: 13, design: .serif))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(CoveStyle.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CoveStyle.card.opacity(colorScheme == .dark ? 0.82 : 0.72))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CoveStyle.accent.opacity(colorScheme == .dark ? 0.16 : 0.14), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 3, x: 0, y: 2)
            .frame(maxWidth: 330, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .accessibilityLabel("little thoughts，碎碎念")
        .accessibilityValue(expanded ? "已展开" : "已折叠")
        .accessibilityHint("点按展开或收起写给你的碎碎念")
    }
}

private struct ChatBubble: View {
    @EnvironmentObject private var store: CoveStore
    @State private var savingSticker: ChatAttachment?
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let quote: ChatMessage?
    let showName: Bool
    let isLastInGroup: Bool
    let arrivalOrigin: CGRect?
    let isReacting: Bool
    var onReply: (String) -> Void
    var onRetry: (ChatMessage) -> Void
    var onLike: (ChatMessage, Bool) -> Void
    private var own: Bool { message.role == "user" }
    private var isSearchTarget: Bool {
        store.messageHighlight?.conversationID == message.conversationID && store.messageHighlight?.messageID == message.id
    }
    private var searchQuery: String { isSearchTarget ? (store.messageHighlight?.query ?? "") : "" }
    private var stickerOnly: Bool { message.stickerID != nil && message.text.isEmpty && quote == nil }
    private var saveableImages: [ChatAttachment] {
        (message.attachments ?? []).filter { ["image/png", "image/jpeg", "image/gif", "image/webp"].contains($0.mime.lowercased()) }
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if own { Spacer(minLength: 44) }
            VStack(alignment: own ? .trailing : .leading, spacing: 3) {
                if !own, message.status == "complete", let thought = message.littleThoughts,
                   !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CoveLittleThoughtsChip(text: thought)
                        .id(message.id + "-little-thoughts")
                        .accessibilityIdentifier("chat.littleThoughts.\(message.id)")
                }
                CoveBubbleWidth {
                    VStack(alignment: .leading, spacing: 5) {
                        if let quote {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2).fill(CoveStyle.teal).frame(width: 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quote.role == "user" ? "用户" : "Assistant").font(.caption2.weight(.semibold)).foregroundStyle(CoveStyle.teal)
                                    Text(quote.previewText())
                                        .font(.caption).foregroundStyle(CoveStyle.secondaryText).lineLimit(2)
                                }
                            }.padding(6).background(CoveStyle.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("chat.quote.\(message.id)")
                        }
                        if let attachments = message.attachments, !attachments.isEmpty {
                            ForEach(attachments) { attachment in
                                if message.stickerID != nil { CoveStickerView(attachment: attachment) }
                                else if attachment.mime.lowercased().hasPrefix("audio/") {
                                    CoveVoiceMessageView(attachment: attachment, isOutgoing: message.role == "user") { file in try await store.attachmentData(file.url) }
                                } else { CoveAttachmentView(attachment: attachment) }
                            }
                        } else if let path = message.attachmentURL {
                            CoveAttachmentView(attachment: ChatAttachment(id: message.id + "-legacy", filename: "图片.jpg", mime: "image/jpeg", size: 0, url: path))
                        }
                        if !message.text.isEmpty {
                            MarkdownMessageView(text: message.text, id: message.id, searchQuery: searchQuery,
                                                widgetContext: message.role == "assistant" && message.status == "complete"
                                                    ? CoveWidgetMarkdownIndex.digest(store.serverURL + ":" + message.conversationID + ":" + message.id) : nil,
                                                onWidgetSend: { text, key in try store.sendWidget(text, source: message, widgetKey: key) })
                                .foregroundStyle(CoveStyle.text).tint(CoveStyle.teal)
                                .accessibilityIdentifier("chat.message.\(message.id)")
                        } else if message.status == "streaming" {
                            Text("正在回复…").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                        }
                        if !own, message.status != "streaming", let attribution = message.weatherAttribution {
                            CoveWeatherAttributionView(attribution: attribution)
                        }
                        if message.status == "failed" && !own {
                            Text(message.error ?? "这次回复未完成。")
                                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                .accessibilityIdentifier("chat.error.\(message.id)")
                        }
                    }
                    .padding(.leading, isLastInGroup && !own ? 17 : 11)
                    .padding(.trailing, isLastInGroup && own ? 17 : 11)
                    .padding(.vertical, 7)
                    .background {
                        if !stickerOnly {
                            if !own && colorScheme == .light {
                                CoveOutlinedBubbleBackground(outgoing: false, firstInGroup: showName,
                                                             lastInGroup: isLastInGroup,
                                                             fill: CoveStyle.incoming,
                                                             outline: CoveStyle.accent)
                            } else {
                                CoveBubbleBackground(outgoing: own, firstInGroup: showName,
                                                     lastInGroup: isLastInGroup,
                                                     fill: own ? CoveStyle.outgoing(colorScheme == .dark) : CoveStyle.incoming)
                            }
                        }
                    }
                    .overlay {
                        if isSearchTarget {
                            RoundedRectangle(cornerRadius: 13).stroke(CoveStyle.teal, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chat.bubble.\(message.id)")
                    .contentShape(Rectangle())
                    .contextMenu {
                        if !message.text.isEmpty {
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                        }
                        ForEach(saveableImages) { attachment in
                            Button(saveableImages.count == 1 ? "收藏为表情包" : "收藏：\(attachment.filename)", systemImage: "face.smiling") {
                                savingSticker = attachment
                            }
                        }
                        Button("引用回复", systemImage: "arrowshape.turn.up.left") { onReply(message.id) }
                        Button(message.isLiked == true ? "取消点赞" : "点赞",
                               systemImage: message.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup") {
                            onLike(message, message.isLiked != true)
                        }.disabled(isReacting).accessibilityIdentifier("chat.like.\(message.id)")
                        if own && message.status == "failed" { Button("重试", systemImage: "arrow.clockwise") { onRetry(message) } }
                    }
                    .modifier(CoveSwipeReply(own: own, enabled: MarkdownPlainText.isPlain(message.text) && message.attachments?.isEmpty != false && message.attachmentURL == nil,
                                             reply: { onReply(message.id) }))
                    .accessibilityAction(named: "引用回复") { onReply(message.id) }
                }
                if isSearchTarget {
                    Button { store.clearMessageHighlight() } label: {
                        Label("已定位 · 取消高亮", systemImage: "xmark.circle")
                            .font(.caption).foregroundStyle(CoveStyle.teal).frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityIdentifier("chat.search.clearHighlight")
                }
                HStack(spacing: 3) {
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .accessibilityIdentifier("chat.timestamp.\(message.id)")
                    if own && message.status != "failed" { CoveDeliveryStatusView(message: message) }
                    if message.status == "interrupted" { Text("已停止") }
                    if own && message.status == "failed" {
                        Button { onRetry(message) } label: {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).frame(width: 44, height: 44)
                        }.accessibilityLabel("消息发送失败，点击重试")
                    }
                }.font(.caption2).foregroundStyle(CoveStyle.dateText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                if message.isLiked == true {
                    Button { onLike(message, false) } label: {
                        HStack(spacing: 4) {
                            Text("👍").font(.subheadline)
                            Text("1").font(.caption.weight(.semibold))
                        }.foregroundStyle(CoveStyle.accentText)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(CoveStyle.card, in: Capsule())
                            .overlay { Capsule().stroke(CoveStyle.teal.opacity(0.35), lineWidth: 1) }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(isReacting)
                        .accessibilityLabel("已点赞，1个点赞；点击取消")
                        .accessibilityIdentifier("chat.reaction.\(message.id)")
                }
            }
            .modifier(CoveMessageArrival(origin: arrivalOrigin))
            if !own { Spacer(minLength: 44) }
        }.padding(.top, showName ? 5 : 0)
        .sheet(item: $savingSticker) { attachment in CoveSaveStickerSheet(attachment: attachment) }
    }
}

private struct CoveDeliveryStatusView: View {
    let message: ChatMessage
    @ScaledMetric(relativeTo: .caption2) private var markHeight: CGFloat = 9

    private var accepted: Bool { message.status == "sent" || message.status == "complete" }
    private var read: Bool { accepted && message.readAt != nil }
    private var statusLabel: String { accepted ? (read ? "已读" : "已发送") : "正在发送" }

    var body: some View {
        Group {
            if accepted {
                // Telegram generateCheckImage is 11 × 9pt with a 0.99pt
                // stroke; DateAndStatusNode places the partial check 6pt
                // after the full check. Keep its actual painted width here.
                Canvas { context, size in
                    let scale = size.height / 9
                    context.scaleBy(x: scale, y: scale)
                    var marks = Path()
                    marks.move(to: CGPoint(x: 1, y: 5))
                    marks.addLine(to: CGPoint(x: 3.95157047, y: 7.95157047))
                    marks.addCurve(to: CGPoint(x: 4.04490857, y: 7.95157047),
                                   control1: CGPoint(x: 3.97734507, y: 7.97734507),
                                   control2: CGPoint(x: 4.01913396, y: 7.97734507))
                    marks.addLine(to: CGPoint(x: 10.5, y: 1))
                    if read {
                        marks.move(to: CGPoint(x: 7.5, y: 8))
                        marks.addLine(to: CGPoint(x: 14, y: 1))
                    }
                    context.stroke(marks, with: .color(read ? CoveStyle.accentText : CoveStyle.dateText),
                                   style: StrokeStyle(lineWidth: 0.99, lineCap: .round, lineJoin: .round))
                }.frame(width: markHeight * (read ? 15.0 / 9 : 11.0 / 9), height: markHeight)
            } else {
                Image(systemName: "clock").font(.caption2)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(statusLabel)
            .accessibilityIdentifier("chat.delivery.\(message.id)")
    }
}

private struct ConversationSheet: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button { Task { await store.newConversation(); dismiss() } } label: { Label("新对话", systemImage: "square.and.pencil") }.disabled(!store.isConnected || store.previewMode)
                ForEach(store.conversations) { conversation in
                    Button {
                        Task { await store.selectConversation(conversation.id); dismiss() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conversation.title.isEmpty ? "与 Assistant 的对话" : conversation.title).foregroundStyle(CoveStyle.text)
                                Text(conversation.createdAt, format: .dateTime.month().day()).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                            }
                            Spacer()
                            if conversation.id == store.activeConversationID { Image(systemName: "checkmark").foregroundStyle(CoveStyle.teal) }
                        }.padding(.vertical, 4)
                    }
                }
            }.navigationTitle("对话").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

private struct HealthView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var confirmDelete = false
    @State private var confirmClearLocal = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CoveCollarPanel(conversationID: store.activeConversationID,
                                isConnected: store.isConnected,
                                previewMode: store.previewMode,
                                load: { try await store.loadCollarPermissions() },
                                save: { read, measure in
                                    try await store.saveCollarPermissions(readSummary: read, requestMeasurement: measure)
                                })
                    .id(store.collarScopeID)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Apple 健康", systemImage: "heart.fill").font(.headline)
                        Spacer()
                        if store.isSyncingHealth { ProgressView() }
                    }
                    Text("读取睡眠阶段、心率/HRV、血氧、呼吸率、步数、能量、距离、站立与锻炼、身体指标和健身记录。你可在系统授权页选择允许的项目；缺少权限或数据会保持未知。开启持续读取后，可用数据会自动同步给 Assistant；关闭时手动读取只保存在本机。")
                        .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    Button { Task { await store.syncHealth() } } label: { Label(store.isSyncingHealth ? "正在读取…" : store.healthSharingEnabled ? "读取并同步" : "在本机读取", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(store.isSyncingHealth || store.previewMode)
                    if !store.healthSyncStatus.isEmpty { Text(store.healthSyncStatus).font(.footnote).foregroundStyle(CoveStyle.secondaryText) }
                }.coveCard()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("允许 Assistant 持续读取和代记生活数据", isOn: Binding(
                        get: { store.healthSharingEnabled },
                        set: { enabled in Task { await store.setHealthDataAccess(enabled: enabled) } }
                    ))
                    .disabled(store.previewMode || !store.isConnected || !store.healthDataAccessKnown || store.isUpdatingHealthDataAccess)
                    .accessibilityIdentifier("health.standingAccess")
                    if store.isUpdatingHealthDataAccess { ProgressView("正在更新授权…") }
                    Text(store.previewMode ? "界面预览，不会读取或更改真实授权。" : store.healthDataAccessStatus)
                    Text("持续授权跨对话保留，涵盖已接入的健康、App 使用记录与 Cove 个人账本。Assistant 可以直接读取整本账本并代记、更正或作废记录，不再逐笔确认；这不包含银行付款。健康自动读取仍限制为北京时间每天最多两次，至少间隔 6 小时。关闭后停止继续同步与直接读写；不会自动删除已有副本。")
                    if !store.healthRequestsStatus.isEmpty { Text(store.healthRequestsStatus) }
                }.font(.caption).foregroundStyle(CoveStyle.secondaryText).padding(.horizontal, 4)

                CoveAppActivityView().id(store.appActivityScopeID)

                Text("健康数据用于让 Assistant 了解你的近况，本页不展示指标明细或历史记录。Cove 目前仍会在本机保存已读取的记录；不会修改 Apple 健康原始数据，也不代表手机全部历史或实时监测。")
                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    .accessibilityIdentifier("health.storageExplanation")
                Button("清除本机健康历史", role: .destructive) { confirmClearLocal = true }.frame(minHeight: 44)
                    .disabled(store.previewMode || store.healthArchiveEntries.isEmpty || store.isSyncingHealth || !store.respondingHealthRequestIDs.isEmpty)
                Button("删除服务器已分享的健康数据", role: .destructive) { confirmDelete = true }.frame(minHeight: 44).disabled(store.previewMode || !store.isConnected || store.isSyncingHealth)
            }.padding(20).frame(maxWidth: 680)
        }.frame(maxWidth: .infinity).background(CoveStyle.background)
            .navigationTitle("健康").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .confirmationDialog("删除私有服务中已分享的健康数据？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除已分享数据", role: .destructive) { Task { await store.deleteSharedHealth() } }
            } message: { Text("同时关闭持续读取、撤销各对话的 Collar 授权并清除服务端摘要副本。本机健康历史、Apple 健康与 Collar 原始记录保留；已进入聊天的数据和已发出的测量不能撤回。") }
            .confirmationDialog("清除 Cove 本机健康历史？", isPresented: $confirmClearLocal, titleVisibility: .visible) {
                Button("清除本机记录", role: .destructive) { store.clearLocalHealthHistory() }
            } message: { Text("只删除此设备上 Cove 保存的读取历史，不能撤销。不会删除 Apple 健康原始数据，也不会删除已分享的服务端副本。") }
    }
}

private struct SettingsView: View {
    @State private var confirmHandoff = false
    @AppStorage("cove.sendHaptics") private var sendHaptics = true
    @EnvironmentObject private var store: CoveStore
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Avatar(name: "Assistant")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cove").font(.headline)
                        Text("用户与 Assistant 的日常").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                    }
                }.padding(.vertical, 4)
            }
            Section("外观") {
                NavigationLink("聊天壁纸") { CoveWallpaperSettingsView() }
                    .accessibilityIdentifier("settings.wallpaper")
            }
            Section("附近设备") {
                NavigationLink { CoveBluetoothView() } label: {
                    Label("啵啵贝连接", systemImage: "antenna.radiowaves.left.and.right")
                }.accessibilityIdentifier("settings.bluetooth")
            }
            Section("系统能力") {
                NavigationLink { CoveSystemCapabilitiesView(preview: store.previewMode) } label: {
                    Label("提醒事项、日历与闹钟", systemImage: "checklist")
                }.accessibilityIdentifier("settings.systemCapabilities")
            }
            Section("连接") {
                TextField("服务地址 https://…", text: $store.serverURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Assistant 服务地址").accessibilityIdentifier("settings.url")
                SecureField("配对密钥", text: $store.accessToken).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("配对密钥").accessibilityIdentifier("settings.token")
                HStack { Text("状态"); Spacer(); Text(store.connectionStatus).foregroundStyle(CoveStyle.secondaryText).multilineTextAlignment(.trailing) }
                Button { Task { await store.connect() } } label: { Label("保存并连接", systemImage: "link") }.disabled(store.previewMode).accessibilityIdentifier("settings.connect")
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                if let usage = store.usage {
                    HStack { Text("订阅"); Spacer(); Text(CoveUsagePresentation.planName(usage.plan)).foregroundStyle(CoveStyle.secondaryText) }
                    ForEach(CoveUsagePresentation.accountWindows(usage.windows)) { window in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(window.title); Spacer(); Text("已用 \(Int(min(max(window.usedPercent, 0), 100)))%").font(.caption).foregroundStyle(CoveStyle.secondaryText) }
                            ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                            if let reset = window.resetsAt { Text("重置 \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText) }
                        }.padding(.vertical, 4)
                    }
                    if CoveUsagePresentation.accountWindows(usage.windows).isEmpty && usage.error == nil {
                        Text("账号暂未返回 5 小时或周额度窗口。")
                            .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    }
                    SnapshotTime(date: usage.updatedAt)
                    if let error = usage.error { Text(error).font(.footnote).foregroundStyle(CoveStyle.secondaryText) }
                } else {
                    Text("订阅与额度未知").foregroundStyle(CoveStyle.secondaryText)
                    Text("连接后读取账号的实际额度窗口。暂时无法获取时会保留更新时间。").font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                }
                Button { Task { await store.refresh() } } label: { Label("刷新订阅信息", systemImage: "arrow.clockwise") }.disabled(!store.isConnected || store.previewMode)
            } header: { Text("订阅用量") }
            Section {
                if let context = store.sessionContext, context.conversationID == store.activeConversationID,
                   let tokens = context.usedTokens {
                    LabeledContent("当前上下文", value: "\(tokens.formatted()) tokens")
                        .accessibilityIdentifier("usage.contextTokens")
                    if let progress = context.progress { ProgressView(value: progress) }
                    Text(context.recommendsSwitch ? "已达到 200k，建议接续到新窗口。" : "建议在 200,000 tokens 前换窗，给记忆交接留出余量。")
                        .font(.footnote).foregroundStyle(context.recommendsSwitch ? CoveStyle.teal : CoveStyle.secondaryText)
                    if let updatedAt = context.updatedAt { SnapshotTime(date: updatedAt) }
                } else {
                    Text("当前上下文用量未知").foregroundStyle(CoveStyle.secondaryText)
                    Text("等待当前 session 返回真实 token 用量，不用累计账单或消息条数估算。")
                        .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                }
                if let context = store.sessionContext, context.conversationID == store.activeConversationID {
                    VStack(alignment: .leading, spacing: 6) {
                        if let count = context.compactionCount, count >= 0 {
                            LabeledContent("本窗口压缩", value: "\(count) 次")
                                .accessibilityIdentifier("usage.compactionCount")
                            if let date = context.lastCompactedAt {
                                Text("最近压缩：\(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                                    .accessibilityIdentifier("usage.lastCompactedAt")
                            }
                            if let reminder = context.compactionReminder {
                                Text(reminder).font(.footnote).foregroundStyle(CoveStyle.teal)
                                    .accessibilityIdentifier("usage.compactionReminder")
                            }
                        } else {
                            Text(context.compactionError ?? "压缩次数暂不可用")
                                .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                                .accessibilityIdentifier("usage.compactionUnknown")
                        }
                    }
                }
                if let error = store.sessionContextError { Text(error).font(.footnote).foregroundStyle(CoveStyle.secondaryText) }
                if let error = store.sessionContext?.handoffError { Text(error).font(.footnote).foregroundStyle(CoveStyle.secondaryText) }
                if let handoff = store.sessionHandoff {
                    HStack {
                        if handoff.isRunning { ProgressView() }
                        Text(handoff.statusText).font(.subheadline)
                    }.accessibilityIdentifier("usage.handoffStatus")
                }
                if let error = store.handoffError { Text(error).font(.footnote).foregroundStyle(.red) }
                if store.isSwitchingSession {
                    Button("查询换窗进度") { Task { await store.refreshSessionContext() } }
                        .disabled(store.handoffRequestPending).accessibilityIdentifier("usage.handoffRefresh")
                    if store.handoffError != nil {
                        Button("重试原换窗请求") { Task { await store.beginSessionHandoff() } }
                            .disabled(store.handoffRequestPending)
                    }
                } else {
                    Button { confirmHandoff = true } label: {
                        Label("保存交接并换窗", systemImage: "arrow.right.square")
                    }.disabled(!store.canStartSessionHandoff).accessibilityIdentifier("usage.handoff")
                }
                Button("刷新上下文用量") { Task { await store.refreshSessionContext() } }
                    .disabled(!store.isConnected || store.previewMode)
            } header: { Text("当前 Session") } footer: {
                Text("这是最近一次模型请求的上下文占用，不是累计用量。换窗保存本地交接，并接续近期记录；OB 长期记忆属于开发者可选集成，需另行配置和授权。旧对话与草稿保留。")
            }
            Section("偏好") {
                Picker("外观", selection: $store.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Toggle("发送轻触反馈", isOn: $sendHaptics)
                Toggle("新回复通知", isOn: $store.notificationsEnabled)
                Picker("通知预览", selection: $store.notificationPreviewMode) {
                    Text("只显示有新消息").tag("generic")
                    Text("显示消息内容").tag("content")
                }.disabled(!store.notificationsEnabled || store.previewMode)
                    .accessibilityIdentifier("settings.notificationPreview")
                Text("使用 App 时不弹系统通知。显示内容会将回复摘要放入推送；锁屏是否展示还取决于 iOS 的“显示预览”设置。")
                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                if let error = store.notificationSyncError { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section("Developer-only · 可选集成") {
                Text("Pulse、Ombre 记忆、Collar、蓝牙硬件、旅行和实验终端需自行部署或适配。界面入口不代表服务已接通；本公开仓不提供账号、密钥、外部后端或硬件。请先阅读仓库的 Developer-only 功能说明。")
                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
            }
            Section {
                Text("对话由你自己的服务保存。健康可逐次分享，也可由你开启跨对话的持续读取；持续授权同时涵盖已接入的生活数据与账本代记，不包含银行付款。关闭授权不会自动删除已有副本。")
                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                LabeledContent("版本", value: "0.1.0 · 公开源码更新 2026-10-29")
                if !store.previewMode { Button("查看示例预览") { store.enablePreview() } }
            } header: { Text("数据与关于") } footer: { Text("示例预览使用明确标注的样例，不会发送消息或上传健康数据。") }
        }
        .scrollContentBackground(.hidden)
        .background(CoveStyle.background)
        .listRowBackground(CoveStyle.card)
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshSessionContext() }
        .confirmationDialog("保存交接并接续到新窗口？", isPresented: $confirmHandoff, titleVisibility: .visible) {
            Button("保存并换窗") { Task { await store.beginSessionHandoff() } }
        } message: {
            Text(store.sessionHandoff?.status == "failed"
                 ? "会重新整理交接并接续最近 20 轮，确认完成才切换。待记清单保留，结果不确定的 OB 写入不会自动重发；旧窗和草稿保留。"
                 : "会保存本窗交接与未完事项，再接续最近 20 轮，消耗正常模型额度。值得长期保留的内容进入待记清单继续写入 OB，不再强制写 Pulse。接续成功后才切换；不会删除聊天或重新授予健康权限。")
        }
    }
}

private struct SnapshotTime: View {
    let date: Date
    var body: some View {
        Text("记录于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText)
    }
}

private struct EmptyCard: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(CoveStyle.teal).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading).coveCard()
    }
}

private extension View {
    func coveCard() -> some View {
        padding(16).background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}


/// UIKit owns cancellation and touchUpInside. Feedback changes the decoration,
/// never the 44pt hit region; dragging away from Send cannot commit a message.
private struct CoveComposerNativeButton: UIViewRepresentable {
    let isBusy: Bool
    let disabled: Bool
    let reduceMotion: Bool
    let action: () -> Void
    func makeUIView(context: Context) -> Control { Control(frame: .zero) }
    func updateUIView(_ control: Control, context: Context) {
        control.action = action
        control.configure(busy: isBusy, disabled: disabled, reduced: reduceMotion)
    }
    final class Control: UIButton {
        private let visual = UIView()
        private let disc = UIView()
        private let glyph = UIImageView()
        private var busy: Bool?
        private var reduced = false
        private var cancelledGesture = false
        var action: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            visual.isUserInteractionEnabled = false
            glyph.contentMode = .center
            visual.addSubview(disc); visual.addSubview(glyph); addSubview(visual)
            isAccessibilityElement = true
            addTarget(self, action: #selector(activate), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 44) }
        override func layoutSubviews() {
            super.layoutSubviews()
            visual.bounds = CGRect(origin: .zero, size: bounds.size)
            visual.center = CGPoint(x: bounds.midX, y: bounds.midY)
            disc.frame = CGRect(x: (bounds.width - 34) / 2, y: (bounds.height - 34) / 2, width: 34, height: 34)
            disc.layer.cornerRadius = 17
            glyph.frame = visual.bounds
        }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            cancelledGesture = !isEnabled || !bounds.contains(touch.location(in: self))
            guard !cancelledGesture else { return false }
            return super.beginTracking(touch, with: event)
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard !cancelledGesture, bounds.contains(touch.location(in: self)) else {
                cancelTracking(with: event)
                return false
            }
            return super.continueTracking(touch, with: event)
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard !cancelledGesture, let touch, bounds.contains(touch.location(in: self)) else {
                cancelTracking(with: event)
                return
            }
            super.endTracking(touch, with: event)
        }
        override func cancelTracking(with event: UIEvent?) {
            cancelledGesture = true
            isHighlighted = false
            super.cancelTracking(with: event)
        }
        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            action?()
            return true
        }
        override var isHighlighted: Bool {
            didSet {
                guard oldValue != isHighlighted else { return }
                let changes = {
                    self.visual.alpha = self.feedbackAlpha
                }
                if isHighlighted || reduced {
                    visual.layer.removeAllAnimations()
                    changes()
                } else {
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: changes)
                }
            }
        }
        private var feedbackAlpha: CGFloat { !isEnabled || isHighlighted ? 0.4 : 1 }
        func configure(busy: Bool, disabled: Bool, reduced: Bool) {
            let changed = self.busy != nil && self.busy != busy
            if isTracking && (changed || disabled) { cancelTracking(with: nil) }
            self.busy = busy; self.reduced = reduced
            isEnabled = !disabled
            accessibilityLabel = busy ? "停止回复" : "发送消息"
            accessibilityIdentifier = busy ? "chat.stop" : "chat.send"
            let render = {
                self.disc.backgroundColor = UIColor(CoveStyle.teal)
                self.glyph.image = UIImage(systemName: busy ? "stop.fill" : "paperplane.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: busy ? 13 : 19, weight: .medium))
                self.glyph.tintColor = .white
                // Store updates during a press must not erase its highlight.
                self.visual.alpha = self.feedbackAlpha
            }
            if changed && !reduced && window != nil {
                UIView.transition(with: visual, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState], animations: render)
            } else { render() }
            if reduced { visual.transform = .identity }
        }
        @objc private func activate() { guard isEnabled, !cancelledGesture else { return }; action?() }
    }
}

private struct CoveChatPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.4 : 1)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

private struct CoveOutgoingArrival: Equatable {
    let id: String
    let origin: CGRect
}

/// New rows may fade in, but never retain a screen-space translation while
/// the keyboard is changing the history viewport underneath them.
private struct CoveMessageArrival: ViewModifier {
    let origin: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    func body(content: Content) -> some View {
        content
            .opacity(origin == nil || reduceMotion || appeared ? 1 : 0.75)
            .onAppear {
                guard origin != nil, !reduceMotion else { appeared = true; return }
                withAnimation(.easeOut(duration: 0.16)) { appeared = true }
            }
    }
}

/// One horizontal recognizer per plain-text bubble. UIKit rejects vertical
/// intent before recognition, leaving scrolling, keyboard dismissal and native
/// text-selection/context-menu gestures in charge of their normal interactions.
private struct CoveReplyPan: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, Bool) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) { recognizer.isEnabled = enabled }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: changed(translation)
        case .ended: ended(translation, true)
        case .cancelled, .failed: ended(translation, false)
        default: break
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.5
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== gestureRecognizer.view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }
}

private struct CoveSwipeReply: ViewModifier {
    let own: Bool
    let enabled: Bool
    let reply: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("cove.sendHaptics") private var haptics = true
    @State private var translation: CGFloat = 0
    @State private var feedbackPlayed = false
    @State private var feedback: UIImpactFeedbackGenerator?
    private var threshold: CGFloat { own ? 60 : 45 }

    func body(content: Content) -> some View {
        content
            .offset(x: translation)
            .background(alignment: .trailing) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CoveStyle.teal)
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
                    .scaleEffect(reduceMotion ? 1 : min(1, abs(translation) / threshold))
                    .opacity(min(1, abs(translation) / threshold))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .gesture(CoveReplyPan(enabled: enabled, changed: { raw in
                if feedback == nil && haptics {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    feedback = generator
                }
                let distance = max(0, -raw)
                // Direct tracking before the threshold; bounded resistance after.
                let excess = max(0, distance - threshold)
                translation = -min(distance, threshold + 42 * (1 - exp(-excess / 85)))
                if distance >= threshold && !feedbackPlayed {
                    feedbackPlayed = true
                    if haptics { feedback?.impactOccurred() }
                }
            }, ended: { raw, committed in
                if committed && -raw >= threshold { reply() }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12)) { translation = 0 }
                feedback = nil
                feedbackPlayed = false
            }))
    }
}

#if DEBUG
/// Isolated UI control fixture. No CoveStore.send/network/HealthKit calls.
private struct CoveComposerControlFixture: View {
    @State private var commits = 0
    @State private var draft = "拖出不能发送"
    @State private var disabled = false
    @State private var reduced = false
    @State private var busy = false
    var body: some View {
        VStack(spacing: 24) {
            Text("本地按钮验收 · 不发送消息")
            Text("\(commits)").accessibilityIdentifier("composer.qa.count")
            TextField("本地输入", text: $draft).accessibilityIdentifier("composer.qa.input")
            CoveComposerNativeButton(isBusy: busy, disabled: disabled, reduceMotion: reduced) { commits += 1 }
                .frame(width: 44, height: 44)
            Toggle("停用按钮", isOn: $disabled).accessibilityIdentifier("composer.qa.disabled")
            Toggle("减少动态", isOn: $reduced).accessibilityIdentifier("composer.qa.reduced")
            Toggle("停止角色", isOn: $busy).accessibilityIdentifier("composer.qa.busy")
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(CoveStyle.background)
            .accessibilityElement(children: .contain).accessibilityIdentifier("composer.qa.fixture")
    }
}
#endif

private struct CoveHealthRequestCard: View {
    @EnvironmentObject private var store: CoveStore
    let item: CoveHealthRequest
    #if DEBUG
    var simulatedDecision: ((Bool) -> Void)? = nil
    #endif
    private var controlsConnected: Bool {
        #if DEBUG
        if simulatedDecision != nil { return true }
        #endif
        return store.isConnected
    }
    private func respond(allow: Bool) {
        #if DEBUG
        if let simulatedDecision { simulatedDecision(allow); return }
        #endif
        Task { await store.respondToHealthRequest(item, allow: allow) }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // This is an action prompt, not a permanent transcript attachment.
            // Keep it while consent is pending; successful responses and expiry remove it.
            if item.canRespond(conversationID: store.activeConversationID, now: context.date) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Assistant 请求读取健康", systemImage: "heart.text.square").font(.subheadline.weight(.semibold))
                    Text(item.metrics.map(CoveHealthScope.title).joined(separator: " · ")).font(.subheadline)
                    Text("\(item.startAt.formatted(date: .abbreviated, time: .shortened)) — \(item.endAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText).accessibilityIdentifier("health.range.\(item.id)")
                    if !item.reason.isEmpty { Text(item.reason).font(.footnote) }
                    Text(store.healthSharingEnabled
                         ? "长期授权已开启，Cove 会自动读取并只分享这次请求的摘要，不再要你逐窗确认。"
                         : "仅分享这次请求的摘要到当前会话，不发送完整历史。心率是已有记录，不会启动实时测量。")
                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    if !store.healthSharingEnabled {
                        ViewThatFits(in: .horizontal) {
                            HStack { allowButton; denyButton }
                            VStack(alignment: .leading) { allowButton; denyButton }
                        }.disabled(store.respondingHealthRequestIDs.contains(item.id) || !controlsConnected)
                    }
                    if store.respondingHealthRequestIDs.contains(item.id) { ProgressView("正在处理…").font(.caption) }
                    if store.readingHealthRequestIDs.contains(item.id) {
                        Button("取消本次读取") { store.cancelHealthRequestRead(item.id) }.frame(minHeight: 44)
                    }
                    Text("有效至 \(item.expiresAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(CoveStyle.secondaryText)
                    if let error = store.healthRequestErrors[item.id] { Text(error).font(.caption).foregroundStyle(.red) }
                    if !controlsConnected { Text("连接中断；重新连接后刷新状态，不自动重发健康数据。").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(CoveStyle.incoming, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("health.request.\(item.id)")
            }
        }
    }
    private var allowButton: some View {
        Button("允许这次") { respond(allow: true) }
            .buttonStyle(.borderedProminent).frame(minHeight: 44)
            .accessibilityIdentifier("health.allow.\(item.id)")
    }
    private var denyButton: some View {
        Button("拒绝") { respond(allow: false) }
            .buttonStyle(.bordered).frame(minHeight: 44)
            .accessibilityIdentifier("health.deny.\(item.id)")
    }
}

#if DEBUG
private struct CoveHealthRequestFixture: View {
    @State private var item = Self.pending()
    private static func pending() -> CoveHealthRequest {
        let now = Date().addingTimeInterval(-1)
        return .init(id: "mock-health", conversationID: "preview", metrics: ["sleep", "restingHeartRate", "heartRate", "steps", "hrv"], startAt: now.addingTimeInterval(-86400), endAt: now, createdAt: now, expiresAt: now.addingTimeInterval(600), status: "pending", reason: "模拟请求：查看昨晚与今天的健康近况", respondedAt: nil, readAt: nil)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("本地测试 · 模拟健康请求").font(.headline)
                Text("不调用 HealthKit，不读取旧健康数据，不联网或分享任何数据。").font(.footnote)
                CoveHealthRequestCard(item: item, simulatedDecision: { allow in
                    item.status = allow ? "allowed" : "denied"
                    item.continuationStatus = allow ? "queued" : nil
                })
                Button("模拟过期") { item.expiresAt = Date().addingTimeInterval(-1); item.status = "expired" }.frame(minHeight: 44)
                Button("重置模拟请求") { item = Self.pending() }.frame(minHeight: 44)
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(CoveStyle.background)
            .accessibilityElement(children: .contain).accessibilityIdentifier("health.qa.fixture")
    }
}
#endif
