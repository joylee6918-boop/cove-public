import SwiftUI

struct CoveToyHomeCard: View {
    var usesHomeSurface = false
    var showsDetailsLink = true
    @EnvironmentObject private var connection: CoveBluetoothConnection
    @EnvironmentObject private var toy: CoveToyControl
    @EnvironmentObject private var store: CoveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: toy.isGranted ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                    .font(.title2)
                    .foregroundStyle(toy.isGranted ? CoveStyle.accentText : CoveStyle.teal)
                    .frame(width: 44, height: 44)
                    .background(CoveStyle.softAccent, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.selectedKind?.displayName ?? "附近玩具").font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                        .accessibilityIdentifier("toy.status")
                }
                Spacer(minLength: 0)
                statusBadge
            }

            if toy.isGranted {
                HStack {
                    Label("助手控制中", systemImage: "hand.raised.fingers.spread.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(CoveStyle.accentText)
                    Spacer()
                    Text("直到你收回").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                }
                HStack(spacing: 8) {
                    if connection.selectedKind == .fenxin {
                        level("吸", toy.lastLevels.motion)
                    } else {
                        level("动", toy.lastLevels.motion)
                        level("震", toy.lastLevels.vibration)
                        level("转", toy.lastLevels.rotation)
                    }
                }
                Button(role: .destructive) {
                    Task { await toy.stopAndRevoke() }
                } label: {
                    Label(toy.isWorking ? "正在全停…" : "全停并收回控制权", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(CoveStyle.error)
                .disabled(toy.isWorking)
                .accessibilityIdentifier("toy.panic")
            } else {
                discoveryControls
            }

            if showsDetailsLink {
                NavigationLink {
                    CoveBluetoothView()
                } label: {
                    HStack {
                        Text("蓝牙与控制详情")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(CoveStyle.secondaryText)
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("toy.details")
            }
        }
        .padding(16)
        .modifier(CoveHomeModuleSurface(enabled: usesHomeSurface))
        .task { toy.bind(store: store, bluetooth: connection) }
    }

    private var summary: String {
        if store.previewMode { return "示例预览，不使用真实蓝牙" }
        if toy.isGranted { return toy.status }
        if connection.controlReady { return toy.status }
        return connection.status
    }

    @ViewBuilder private var statusBadge: some View {
        let ready = connection.controlReady
        Label(toy.isGranted ? "已交给助手" : ready ? "已连接" : "未连接",
              systemImage: toy.isGranted ? "lock.open.fill" : ready ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(toy.isGranted || ready ? CoveStyle.teal : CoveStyle.secondaryText)
            .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var discoveryControls: some View {
        if !connection.devices.isEmpty && connection.selectedID == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择你手边的设备").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                ForEach(connection.devices) { device in
                    Button {
                        connection.selectFromUserAction(device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).foregroundStyle(CoveStyle.text)
                                Text(device.kind.displayName)
                                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                Text("标识尾号 \(device.id.uuidString.suffix(6))")
                                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "link")
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else if connection.controlReady {
            Button {
                Task { await toy.grant() }
            } label: {
                Label(toy.isWorking ? "正在交给助手…" : "交给助手", systemImage: "hand.raised.fingers.spread")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(toy.isWorking || store.previewMode || !store.isConnected)
            .accessibilityIdentifier("toy.grant")
            if !store.isConnected {
                Text("先在设置里连接 Cove，蓝牙仍可单独连接。")
                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            }
        } else if connection.phase == .preparing || connection.phase == .scanning || connection.phase == .connecting || connection.phase == .connected {
            HStack(spacing: 10) {
                ProgressView()
                Text(connection.status).font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
            }
            if connection.phase == .preparing || connection.phase == .scanning {
                Button("停止查找") { connection.finishScan() }.frame(minHeight: 44)
            }
        } else {
            Button {
                connection.scanFromUserAction()
            } label: {
                Label("查找附近玩具", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.previewMode || !connection.canScan)
            .accessibilityIdentifier("toy.scan")
        }
    }

    private func level(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(CoveStyle.secondaryText)
            Text(value, format: .number).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(CoveStyle.softAccent.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)通道 \(value)")
    }
}

struct CoveBluetoothView: View {
    @EnvironmentObject private var connection: CoveBluetoothConnection
    @EnvironmentObject private var toy: CoveToyControl
    @EnvironmentObject private var store: CoveStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoveToyHomeCard(showsDetailsLink: false)

                VStack(alignment: .leading, spacing: 10) {
                    Label("这条链路怎么工作", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.headline)
                    Text("Cove 在手机上直接连接啵啵贝或分欣，不再需要 Mac 蓝牙中继。你亲手点“交给助手”后，助手可以持续控制，直到你收回或连接真正断开。")
                    Text("进入后台、蓝牙断开、服务器连续失联或授权到期，Cove 会停止动作并收回控制权。红色全停键永远优先。")
                    Text("啵啵贝使用三个已捕获通道；分欣目前只开放抓包确认过的吸力通道。所有迟到超过 12 秒的指令都会作废，不会在重连后补执行。")
                }
                .font(.footnote)
                .foregroundStyle(CoveStyle.secondaryText)
                .padding(16)
                .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))

                if connection.selectedID != nil && !toy.isGranted {
                    Button("断开蓝牙连接", role: .destructive) {
                        connection.endSession()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("bluetooth.disconnect")
                }
            }
            .padding(20)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .background(CoveStyle.background)
        .navigationTitle("附近玩具")
        .navigationBarTitleDisplayMode(.inline)
        .task { toy.bind(store: store, bluetooth: connection) }
    }
}
