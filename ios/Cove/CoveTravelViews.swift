import SwiftUI
import MapKit

/// One polling owner, only while the app is active; no GPS or location permission.
struct CoveTravelLifecycle: ViewModifier {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.scenePhase) private var phase
    private var scope: String { "\(store.appActivityScopeID)|\(store.activeConversationID)|\(phase)" }
    func body(content: Content) -> some View {
        content.environmentObject(store.travel)
            .task(id: scope) {
                store.travel.reset(scope: scope)
                guard phase == .active, store.isConnected, !store.previewMode else { return }
                while !Task.isCancelled {
                    await store.travel.refresh(store: store)
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
    }
}

struct CoveTravelEntry: View {
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var travel: CoveTravelModel
    var compact = false
    @State private var showingJourney = false
    var body: some View {
        Group {
            if !compact || travel.hasChatContent {
                VStack(alignment: .leading, spacing: 12) {
                    if let invitation = travel.snapshot?.invitation, travel.invitationPresentation != .hidden {
                        Label(travel.invitationPresentation == .failedDeparture ? "这次未能出发" : (travel.invitationPresentation == .unconfirmedDeparture ? "出发尚未确认" : "助手邀请你去旅行"), systemImage: "envelope.open").font(.headline)
                        Text(invitation.destination).font(.body)
                        if travel.invitationPresentation == .pending {
                            ViewThatFits(in: .horizontal) {
                                HStack { invitationButtons(invitation) }
                                VStack(alignment: .leading) { invitationButtons(invitation) }
                            }
                        } else if travel.invitationPresentation == .checking {
                            Label(travel.acting ? "正在提交并核对旅程…" : "邀请结果待核对，不会重复出发", systemImage: "hourglass").font(.subheadline)
                            if !travel.acting {
                                Button("核对旅程") { Task { await travel.refresh(store: store) } }.frame(minHeight: 44)
                            }
                        } else if travel.invitationPresentation == .failedDeparture {
                            Text("目的地未能定位，尚未落地。请结束这次旅程，核对地名后重新邀请。").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("这次出发没有可靠完成确认，已暂停。可以查看或结束旅程，不会自动重试。").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if compact, let journey = travel.snapshot?.journey {
                        Label(journey.destination, systemImage: "map").font(.headline)
                        Text(travel.invitationPresentation == .checking ? "正在核对出发状态" : journey.statusText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error = travel.error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("刷新旅程") { Task { await travel.refresh(store: store) } }.frame(minHeight: 44)
                    }
                    Button { showingJourney = true } label: {
                        HStack {
                            if compact {
                                Label("查看旅程", systemImage: "map")
                            } else {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("我们的旅行").font(.system(.title3, design: .serif, weight: .semibold))
                                    Text("把一起走过的地方，寄给以后的我们。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if travel.acting || travel.loading { ProgressView() }
                            Image(systemName: "chevron.right").font(.caption)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if !compact {
                        if let journey = travel.snapshot?.journey ?? travel.snapshot?.archives.first {
                            Button { showingJourney = true } label: {
                                CoveTravelPostcard(journey: journey)
                            }.buttonStyle(.plain)
                        } else {
                            Text("下一站，和你一起。")
                                .font(.system(.body, design: .serif)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .background {
                    if compact { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
                }
                .foregroundStyle(.primary)
                .sheet(isPresented: $showingJourney) { CoveTravelSheet().environmentObject(store).environmentObject(travel) }
            }
        }
    }
    @ViewBuilder private func invitationButtons(_ invitation: CoveTravelInvitation) -> some View {
        Button("接受邀请") { Task { await travel.respond(invitation, decision: "accept", store: store) } }
            .frame(minHeight: 44).buttonStyle(.borderedProminent)
            .disabled(travel.acting || travel.mutationUnconfirmed || !store.isConnected)
        Button("暂时不去") { Task { await travel.respond(invitation, decision: "decline", store: store) } }
            .frame(minHeight: 44).buttonStyle(.bordered)
            .disabled(travel.acting || travel.mutationUnconfirmed || !store.isConnected)
    }
}

struct CoveTravelSheet: View {
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var travel: CoveTravelModel
    @Environment(\.dismiss) private var dismiss
    private var journeys: [CoveTravelJourney] {
        (travel.snapshot?.journey.map { [$0] } ?? []) + (travel.snapshot?.archives ?? [])
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text("把走过的地方，留成一张张明信片。").font(.subheadline).foregroundStyle(.secondary)
                    if !store.isConnected { Text("连接 Cove 后查看旅程。").foregroundStyle(.secondary) }
                    else if travel.snapshot?.available == false { Text("旅行尚未启用。").foregroundStyle(.secondary) }
                    if let error = travel.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    if travel.loading { ProgressView("正在更新旅程…") }
                    if journeys.isEmpty && travel.snapshot?.available == true {
                        ContentUnavailableView("旅程还没开始", systemImage: "map", description: Text("在对话里和助手选一站，接受邀请后一起出发。"))
                    }
                    ForEach(journeys) { journey in
                        NavigationLink {
                            CoveTravelAlbumDetail(initialJourney: journey)
                        } label: { CoveTravelPostcard(journey: journey) }.buttonStyle(.plain)
                    }
                }.padding(20).frame(maxWidth: 680)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("旅行明信片").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.frame(minHeight: 44) } }
            .refreshable { await travel.refresh(store: store) }
        }
    }
}

struct CoveTravelMap: View {
    let journey: CoveTravelJourney
    private var points: [CLLocationCoordinate2D] {
        journey.path.filter(\.isValid).map { .init(latitude: $0.lat, longitude: $0.lon) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if journey.position?.isValid == true || !points.isEmpty {
                Map {
                    if points.count > 1 { MapPolyline(coordinates: points).stroke(CoveStyle.teal, lineWidth: 3) }
                    if let p = journey.position, p.isValid {
                        Marker(journey.destination, systemImage: "figure.walk", coordinate: .init(latitude: p.lat, longitude: p.lon)).tint(CoveStyle.teal)
                    }
                }.frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("\(journey.destination)的虚拟旅行位置与路线")
            } else { Label("这一站还没有地图位置", systemImage: "map").foregroundStyle(.secondary) }
            Text("虚拟旅行路线 · 不读取你的手机定位").font(.caption).foregroundStyle(.secondary)
        }
    }
}
