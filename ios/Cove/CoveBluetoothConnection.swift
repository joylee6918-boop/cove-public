import Foundation
import Combine
import CoreBluetooth

enum CoveToyKind: String, Codable, Equatable {
    case bobobei
    case fenxin

    var displayName: String { self == .bobobei ? "啵啵贝" : "分欣" }

    static func detect(_ name: String?) -> CoveToyKind? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return nil }
        if value.hasPrefix("SOSEXY") { return .bobobei }
        if value.hasPrefix("SL278") { return .fenxin }
        return nil
    }
}

struct CoveNearbyDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let signal: Int?
    let kind: CoveToyKind

    init(id: UUID, name: String, signal: Int?, kind: CoveToyKind? = nil) {
        self.id = id
        self.name = name
        self.signal = signal
        self.kind = kind ?? CoveToyKind.detect(name) ?? .bobobei
    }

    static func matches(_ name: String?) -> Bool {
        CoveToyKind.detect(name) != nil
    }
}

enum CoveBluetoothEvent {
    case scanning
    case unavailable(String)
    case found(CoveNearbyDevice)
    case connected(UUID)
    case controlReady(UUID)
    case controlUnavailable(UUID, String)
    case writeCompleted(String?)
    case notification(Data)
    case reconnecting(UUID, String?)
    case disconnected(UUID, String?)
}

@MainActor
protocol CoveBluetoothTransport: AnyObject {
    var onEvent: ((CoveBluetoothEvent) -> Void)? { get set }
    func scan()
    func stopScan()
    func connect(_ id: UUID)
    func reconnect()
    func disconnect()
    func write(_ data: Data)
}

@MainActor
final class CoveBluetoothConnection: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, scanning, ready, connecting, connected, disconnecting, unavailable
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var devices: [CoveNearbyDevice] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var selectedKind: CoveToyKind?
    @Published private(set) var status = "尚未连接设备"
    @Published private(set) var controlReady = false
    @Published private(set) var lastNotification: Data?
    @Published private(set) var previewMode: Bool
    var onSessionEnded: (() -> Void)?
    private let transport: any CoveBluetoothTransport
    private let scanDuration: Duration
    private let connectionDuration: Duration
    private var timeout: Task<Void, Never>?
    private struct PendingWrite {
        let id: UUID
        let packets: [Data]
        var index: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pendingWrite: PendingWrite?
    private var writeTimeout: Task<Void, Never>?

    init(previewMode: Bool = false, transport: (any CoveBluetoothTransport)? = nil,
         scanDuration: Duration = .seconds(12), connectionDuration: Duration = .seconds(20)) {
        self.previewMode = previewMode
        self.transport = transport ?? CoveCoreBluetoothTransport()
        self.scanDuration = scanDuration
        self.connectionDuration = connectionDuration
        self.transport.onEvent = { [weak self] in self?.receive($0) }
    }

    var canScan: Bool {
        !previewMode && [.idle, .ready, .unavailable].contains(phase)
    }

    var hasSession: Bool {
        [.preparing, .scanning, .connecting, .connected, .disconnecting].contains(phase)
    }

    var writeInProgress: Bool { pendingWrite != nil }

    func scanFromUserAction() {
        guard canScan else { return }
        devices = []
        selectedID = nil
        selectedKind = nil
        controlReady = false
        phase = .preparing
        status = "正在准备蓝牙；首次使用需要系统授权"
        timeout?.cancel()
        timeout = Task { [weak self, connectionDuration] in
            do { try await Task.sleep(for: connectionDuration) } catch { return }
            guard let self, self.phase == .preparing else { return }
            self.endSession()
            self.status = "蓝牙尚未就绪，查找已取消；请确认权限后重新查找"
        }
        transport.scan()
    }

    func setPreviewMode(_ enabled: Bool) {
        guard enabled != previewMode else { return }
        endSession()
        previewMode = enabled
    }

    func finishScan() {
        guard phase == .scanning || phase == .preparing else { return }
        timeout?.cancel()
        transport.stopScan()
        phase = .ready
        status = devices.isEmpty ? "未发现设备。请确认设备已开机、靠近手机，且未被其他 App 占用。" : "请选择你手边的设备；不会自动连接"
    }

    func selectFromUserAction(_ id: UUID) {
        guard !previewMode, phase == .scanning || phase == .ready,
              devices.contains(where: { $0.id == id }) else { return }
        timeout?.cancel()
        transport.stopScan()
        selectedID = id
        selectedKind = devices.first(where: { $0.id == id })?.kind
        controlReady = false
        phase = .connecting
        status = "正在建立蓝牙连接…"
        timeout = Task { [weak self, connectionDuration] in
            do { try await Task.sleep(for: connectionDuration) } catch { return }
            guard let self, self.phase == .connecting, self.selectedID == id else { return }
            self.endSession(reason: "连接超时，已请求取消连接；不会自动重试")
        }
        transport.connect(id)
    }

    func endSession(reason: String = "已请求断开蓝牙连接") {
        timeout?.cancel()
        failPendingWrite("蓝牙连接正在断开")
        transport.stopScan()
        devices = []
        controlReady = false
        if selectedID != nil {
            phase = .disconnecting
            status = reason
            transport.disconnect()
        } else {
            phase = .idle
            status = "连接会话已结束"
        }
    }

    func enteredBackground() {
        guard hasSession || !devices.isEmpty else { return }
        if controlReady {
            Task { [weak self] in
                try? await self?.stopToy()
                self?.endSession(reason: "Cove 已进入后台，已全停并请求断开蓝牙连接")
            }
        } else {
            endSession(reason: "Cove 已进入后台，已请求断开蓝牙连接")
        }
    }

    func setToyLevels(motion: Int, vibration: Int, rotation: Int) async throws {
        switch selectedKind {
        case .bobobei:
            try await writePackets(CoveBobobeiProtocol.packets(
                motion: motion, vibration: vibration, rotation: rotation))
        case .fenxin:
            try await writePackets([CoveFenxinProtocol.packet(level: motion)])
        case nil:
            throw CoveError.message("尚未选择玩具。")
        }
    }

    func stopToy() async throws {
        switch selectedKind {
        case .bobobei: try await writePackets(CoveBobobeiProtocol.stopPackets)
        case .fenxin: try await writePackets(CoveFenxinProtocol.stopPackets)
        case nil: throw CoveError.message("尚未选择玩具。")
        }
    }

    func keepToyAlive(motion: Int, vibration: Int, rotation: Int) async throws {
        switch selectedKind {
        case .bobobei:
            try await writePackets([CoveBobobeiProtocol.keepAlivePacket(
                motion: motion, vibration: vibration, rotation: rotation)])
        case .fenxin:
            try await writePackets([CoveFenxinProtocol.packet(level: motion)])
        case nil:
            throw CoveError.message("尚未选择玩具。")
        }
    }

    private func writePackets(_ packets: [Data]) async throws {
        guard !previewMode, phase == .connected, controlReady, selectedID != nil else {
            throw CoveError.message("玩具控制通道尚未就绪。")
        }
        guard pendingWrite == nil, !packets.isEmpty else {
            throw CoveError.message("上一条玩具指令尚未写完。")
        }
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pendingWrite = PendingWrite(id: id, packets: packets, index: 0, continuation: continuation)
            transport.write(packets[0])
            writeTimeout?.cancel()
            writeTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.pendingWrite?.id == id else { return }
                self.failPendingWrite("玩具写入超时")
                self.transport.reconnect()
            }
        }
    }

    private func advancePendingWrite(error: String?) {
        guard var pending = pendingWrite else { return }
        if let error {
            failPendingWrite(error)
            return
        }
        pending.index += 1
        if pending.index >= pending.packets.count {
            writeTimeout?.cancel()
            pendingWrite = nil
            pending.continuation.resume()
        } else {
            pendingWrite = pending
            transport.write(pending.packets[pending.index])
        }
    }

    private func failPendingWrite(_ reason: String) {
        guard let pending = pendingWrite else { return }
        writeTimeout?.cancel()
        pendingWrite = nil
        pending.continuation.resume(throwing: CoveError.message(reason))
    }

    private func receive(_ event: CoveBluetoothEvent) {
        // A cancellation acknowledgement can arrive after entering preview.
        if previewMode {
            if case .disconnected(let id, _) = event, selectedID == id {
                selectedID = nil
                selectedKind = nil
                phase = .idle
            } else if case .unavailable = event {
                selectedID = nil
                selectedKind = nil
                phase = .idle
            }
            return
        }
        switch event {
        case .scanning:
            guard phase == .preparing else { transport.stopScan(); return }
            phase = .scanning
            status = "正在查找附近设备…"
            timeout?.cancel()
            timeout = Task { [weak self, scanDuration] in
                do { try await Task.sleep(for: scanDuration) } catch { return }
                self?.finishScan()
            }
        case .unavailable(let reason):
            timeout?.cancel()
            failPendingWrite(reason)
            phase = .unavailable
            devices = []
            selectedID = nil
            selectedKind = nil
            controlReady = false
            status = reason
            onSessionEnded?()
        case .found(let device):
            guard phase == .scanning, CoveNearbyDevice.matches(device.name) else { return }
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
            else { devices.append(device) }
        case .connected(let id):
            guard phase == .connecting, selectedID == id else { return }
            timeout?.cancel()
            phase = .connected
            status = "蓝牙链路已连接，正在验证\(selectedKind?.displayName ?? "玩具")控制通道…"
        case .controlReady(let id):
            guard phase == .connected, selectedID == id else { return }
            controlReady = true
            status = "\(selectedKind?.displayName ?? "玩具")已连接，可以交给助手"
        case .controlUnavailable(let id, let reason):
            guard selectedID == id else { return }
            controlReady = false
            status = "已连接，但控制通道不可用：\(reason)"
        case .writeCompleted(let error):
            advancePendingWrite(error: error)
        case .notification(let data):
            lastNotification = data
        case .reconnecting(let id, let error):
            guard selectedID == id else { return }
            timeout?.cancel()
            failPendingWrite(error ?? "蓝牙链路中断，正在重连")
            controlReady = false
            phase = .connecting
            status = error.map { "蓝牙短暂断开：\($0)；正在自动重连…" } ?? "蓝牙短暂断开，正在自动重连…"
        case .disconnected(let id, let error):
            guard selectedID == id else { return }
            timeout?.cancel()
            failPendingWrite(error ?? "蓝牙连接已结束")
            selectedID = nil
            selectedKind = nil
            devices = []
            controlReady = false
            phase = .idle
            status = error.map { "连接未保持：\($0)；不会自动重连" } ?? "蓝牙连接已结束；不会自动重连"
            onSessionEnded?()
        }
    }
}

@MainActor
final class CoveCoreBluetoothTransport: NSObject, CoveBluetoothTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onEvent: ((CoveBluetoothEvent) -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheralKinds: [UUID: CoveToyKind] = [:]
    private var selected: CBPeripheral?
    private var selectedKind: CoveToyKind?
    private var wantsScan = false
    private var wantsConnection = false
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingCharacteristicServices = 0
    private var reconnectTask: Task<Void, Never>?
    private var writeUUID: CBUUID {
        CBUUID(string: selectedKind == .fenxin
            ? "0000ffe1-0000-1000-8000-00805f9b34fb"
            : "0000ee03-0000-1000-8000-00805f9b34fb")
    }
    private var notifyUUID: CBUUID {
        CBUUID(string: selectedKind == .fenxin
            ? "0000ffe2-0000-1000-8000-00805f9b34fb"
            : "0000ee02-0000-1000-8000-00805f9b34fb")
    }

    func scan() {
        guard selected == nil else { return }
        wantsScan = true
        peripherals = [:]
        peripheralKinds = [:]
        if let central { centralManagerDidUpdateState(central) }
        else { central = CBCentralManager(delegate: self, queue: .main,
                                         options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
    }

    func connect(_ id: UUID) {
        stopScan()
        reconnectTask?.cancel()
        guard let central, central.state == .poweredOn, let device = peripherals[id] else {
            onEvent?(.disconnected(id, "设备已不可用，请重新扫描"))
            return
        }
        selected = device
        selectedKind = peripheralKinds[id]
        wantsConnection = true
        writeCharacteristic = nil
        notifyCharacteristic = nil
        // Omit auto-reconnect entirely. Passing that option requires the newer
        // reconnect-aware delegate callback even when the value is false, and
        // otherwise CoreBluetooth rejects the connection as invalid.
        central.connect(device, options: nil)
    }

    func reconnect() {
        guard wantsConnection, let selected else { return }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingCharacteristicServices = 0
        onEvent?(.reconnecting(selected.identifier, "控制写入未获回应"))
        if selected.state == .disconnected { scheduleReconnect(selected) }
        else { central?.cancelPeripheralConnection(selected) }
    }

    func disconnect() {
        stopScan()
        wantsConnection = false
        reconnectTask?.cancel()
        guard let selected else { return }
        if selected.state == .disconnected {
            self.selected = nil
            self.selectedKind = nil
            onEvent?(.disconnected(selected.identifier, nil))
        } else { central?.cancelPeripheralConnection(selected) }
    }

    func write(_ data: Data) {
        guard let selected, selected.state == .connected, let characteristic = writeCharacteristic else {
            onEvent?(.writeCompleted("玩具写入特征不可用"))
            return
        }
        if selectedKind == .fenxin {
            guard characteristic.properties.contains(.writeWithoutResponse) else {
                onEvent?(.writeCompleted("分欣写入特征不支持无响应写入"))
                return
            }
            selected.writeValue(data, for: characteristic, type: .withoutResponse)
            onEvent?(.writeCompleted(nil))
        } else {
            guard characteristic.properties.contains(.write) else {
                onEvent?(.writeCompleted("啵啵贝写入特征不支持响应写入"))
                return
            }
            selected.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan {
                // This model may omit its service UUID from advertisements. Scan
                // briefly, retain only matching names; do not enumerate other data.
                central.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                onEvent?(.scanning)
            } else if wantsConnection, let selected, selected.state == .disconnected {
                scheduleReconnect(selected)
            }
        case .unknown where selected == nil:
            break // Initial manager setup is bounded by the preparation timer.
        default:
            wantsScan = false
            wantsConnection = false
            selected = nil
            selectedKind = nil
            peripherals = [:]
            peripheralKinds = [:]
            let message: String
            switch central.state {
            case .unauthorized: message = "蓝牙权限未开放。可在系统设置中允许 Cove 使用蓝牙。"
            case .poweredOff: message = "手机蓝牙已关闭，请在系统设置中开启后重新扫描。"
            case .unsupported: message = "当前设备不支持所需蓝牙功能。"
            case .resetting: message = "系统蓝牙正在重置，本次连接已失效；请稍后重新扫描。"
            default: message = "蓝牙暂不可用，请稍后重试。"
            }
            onEvent?(.unavailable(message))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantsScan else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard let kind = CoveToyKind.detect(name), let name else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheralKinds[peripheral.identifier] = kind
        onEvent?(.found(.init(id: peripheral.identifier, name: name,
                             signal: RSSI.intValue == 127 ? nil : RSSI.intValue, kind: kind)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard wantsConnection, selected?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        reconnectTask?.cancel()
        onEvent?(.connected(peripheral.identifier))
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionEnded(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionEnded(peripheral, error: error)
    }

    private func connectionEnded(_ peripheral: CBPeripheral, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingCharacteristicServices = 0
        if wantsConnection {
            onEvent?(.reconnecting(peripheral.identifier, error?.localizedDescription))
            scheduleReconnect(peripheral)
        } else {
            selected = nil
            selectedKind = nil
            onEvent?(.disconnected(peripheral.identifier, error?.localizedDescription))
        }
    }

    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self, weak peripheral] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, let peripheral, self.wantsConnection,
                  self.selected?.identifier == peripheral.identifier,
                  let central = self.central, central.state == .poweredOn else { return }
            central.connect(peripheral, options: nil)
        }
    }


    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        if let error {
            onEvent?(.controlUnavailable(peripheral.identifier, error.localizedDescription))
            return
        }
        let services = peripheral.services ?? []
        pendingCharacteristicServices = services.count
        guard !services.isEmpty else {
            onEvent?(.controlUnavailable(peripheral.identifier, "设备没有公开 GATT 服务"))
            return
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        if error == nil {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
                if characteristic.uuid == notifyUUID { notifyCharacteristic = characteristic }
            }
        }
        pendingCharacteristicServices = max(0, pendingCharacteristicServices - 1)
        guard pendingCharacteristicServices == 0 else { return }
        guard let writeCharacteristic else {
            onEvent?(.controlUnavailable(peripheral.identifier, "没有找到玩具写入特征"))
            return
        }
        let canWrite = selectedKind == .fenxin
            ? writeCharacteristic.properties.contains(.writeWithoutResponse)
            : writeCharacteristic.properties.contains(.write)
        guard canWrite else {
            onEvent?(.controlUnavailable(peripheral.identifier, "玩具写入方式与抓包协议不匹配"))
            return
        }
        if let notifyCharacteristic, notifyCharacteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        }
        onEvent?(.controlReady(peripheral.identifier))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selectedKind == .bobobei, selected?.identifier == peripheral.identifier,
              characteristic.uuid == writeUUID else { return }
        onEvent?(.writeCompleted(error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier, characteristic.uuid == notifyUUID,
              error == nil, let data = characteristic.value else { return }
        onEvent?(.notification(data))
    }
}

enum CoveBobobeiProtocol {
    private static func packet(channel: UInt8, level: Int, responseChannel: UInt8) -> Data {
        Data([0x01, 0x01, 0x00, 0x02, 0x00, channel, 0x11,
              UInt8(max(0, min(100, level))), 0x00, responseChannel, 0x11, 0x01])
    }

    static func packets(motion: Int, vibration: Int, rotation: Int) -> [Data] {
        [packet(channel: 0x07, level: motion, responseChannel: 0x08),
         packet(channel: 0x01, level: vibration, responseChannel: 0x02),
         packet(channel: 0x03, level: rotation, responseChannel: 0x04)]
    }

    // The original desktop relay keeps the BLE link alive with one repeated
    // packet every 400 ms.  Re-sending all three channels each tick triples
    // write-with-response traffic and can make real control writes contend.
    static func keepAlivePacket(motion: Int, vibration: Int, rotation: Int) -> Data {
        if motion > 0 { return packet(channel: 0x07, level: motion, responseChannel: 0x08) }
        if vibration > 0 { return packet(channel: 0x01, level: vibration, responseChannel: 0x02) }
        if rotation > 0 { return packet(channel: 0x03, level: rotation, responseChannel: 0x04) }
        return packet(channel: 0x07, level: 0, responseChannel: 0x08)
    }

    static let stopPackets = packets(motion: 0, vibration: 0, rotation: 0)
}

enum CoveFenxinProtocol {
    static func packet(level: Int) -> Data {
        let clamped = max(0, min(100, level))
        let scaled = UInt8((clamped * 255 + 50) / 100)
        return Data([0x55, 0x04, 0x00, 0x00, clamped == 0 ? 0x00 : 0x01, scaled, 0xaa])
    }

    // Captured from the existing “交给助手” SL278 relay. Only the first
    // (suction) channel has a verified non-zero frame, so Cove does not expose
    // the other two channels until they are physically mapped.
    static let stopPackets = [
        Data([0x55, 0x04, 0x00, 0x00, 0x01, 0x00, 0xaa]),
        Data([0x55, 0x03, 0x03, 0x01, 0x00, 0x00, 0xaa]),
        Data([0x55, 0x05, 0x00, 0x00, 0x01, 0x00, 0xaa]),
    ]
}

struct CoveToySession: Codable, Equatable {
    let id: String
    let status: String
    let createdAt: Date
    let expiresAt: Date
    let lastPhoneAt: Date?
    let device: CoveToyKind?
}

struct CoveToySessionEnvelope: Decodable {
    let active: Bool
    let session: CoveToySession?
}

struct CoveToyCommand: Decodable, Identifiable {
    let id: String
    let kind: String
    let device: CoveToyKind?
    let motion: Int?
    let vibration: Int?
    let rotation: Int?
    let level: Int?
    let createdAt: Date?
    let expiresAt: Date?
}

struct CoveToyCommandsEnvelope: Decodable {
    let active: Bool
    let session: CoveToySession?
    let cursor: Int
    let commands: [CoveToyCommand]
}

@MainActor
final class CoveToyControl: ObservableObject {
    @Published private(set) var session: CoveToySession?
    @Published private(set) var status = "尚未交给助手"
    @Published private(set) var isWorking = false
    @Published private(set) var lastLevels = (motion: 0, vibration: 0, rotation: 0)

    private weak var store: CoveStore?
    private weak var bluetooth: CoveBluetoothConnection?
    private var polling: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var cursor = 0
    private var generation = UUID()

    var isGranted: Bool { session?.status == "active" && session.map { $0.expiresAt > Date() } == true }

    func bind(store: CoveStore, bluetooth: CoveBluetoothConnection) {
        self.store = store
        self.bluetooth = bluetooth
        bluetooth.onSessionEnded = { [weak self] in self?.connectionEnded() }
    }

    func grant() async {
        guard !isWorking, let store, let bluetooth else { return }
        guard store.isConnected else { status = "先连接 Cove 服务"; return }
        guard bluetooth.controlReady, let device = bluetooth.selectedKind else { status = "先连接并验证玩具"; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await store.grantToyControl(device: device)
            guard result.active, let granted = result.session else {
                throw CoveError.message("服务器没有确认玩具授权。")
            }
            generation = UUID()
            cursor = 0
            session = granted
            status = "已交给助手"
            startPolling(generation)
            startKeepAlive(generation, sessionID: granted.id)
        } catch {
            status = error.localizedDescription
        }
    }

    func stopAndRevoke() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await stopAndRevoke(reason: "已全停并收回控制权")
    }

    func enteredBackground() {
        if session != nil {
            status = "助手仍在控制"
            return
        }
        bluetooth?.enteredBackground()
    }

    func connectionEnded() {
        guard session != nil else { return }
        generation = UUID()
        polling?.cancel()
        keepAlive?.cancel()
        let old = session
        session = nil
        status = "蓝牙连接已结束，控制权已收回"
        if let old, let store {
            Task { try? await store.revokeToyControl(sessionID: old.id) }
        }
    }

    private func startPolling(_ token: UUID) {
        polling?.cancel()
        polling = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled, self.generation == token, let current = self.session {
                guard let bluetooth = self.bluetooth, bluetooth.hasSession else {
                    await self.stopAndRevoke(reason: "蓝牙会话已结束，控制权已收回")
                    return
                }
                if !bluetooth.controlReady {
                    self.status = "蓝牙正在自动重连，控制权仍由助手保留"
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    continue
                }
                do {
                    guard let store = self.store else { return }
                    let result = try await store.pollToyCommands(sessionID: current.id, after: self.cursor)
                    guard !Task.isCancelled, self.generation == token else { return }
                    let recovered = consecutiveFailures > 0
                    consecutiveFailures = 0
                    if recovered { self.status = "助手仍在控制" }
                    guard result.active else {
                        await self.stopAndRevoke(reason: "授权已失效，玩具已全停", revokeServer: false)
                        return
                    }
                    if let refreshed = result.session { self.session = refreshed }
                    for command in result.commands {
                        guard !Task.isCancelled, self.generation == token else { return }
                        await self.execute(command, sessionID: current.id, token: token)
                        if let value = Int(command.id) { self.cursor = max(self.cursor, value) }
                    }
                    if result.commands.isEmpty { self.cursor = max(self.cursor, result.cursor) }
                } catch {
                    if Task.isCancelled { return }
                    consecutiveFailures += 1
                    status = "Cove 服务暂时失联，保持当前状态并继续重连"
                }
                let delay: Duration = consecutiveFailures == 0 ? .milliseconds(350) : .seconds(1)
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func execute(_ command: CoveToyCommand, sessionID: String, token: UUID) async {
        guard let bluetooth, let store else { return }
        keepAlive?.cancel()
        do {
            guard command.expiresAt.map({ $0 > Date() }) != false else {
                throw CoveError.message("指令已过期，不会补执行。")
            }
            let commandDevice = command.device ?? session?.device ?? .bobobei
            guard commandDevice == bluetooth.selectedKind else {
                throw CoveError.message("指令与当前玩具不匹配。")
            }
            let levels: (motion: Int, vibration: Int, rotation: Int)
            switch commandDevice {
            case .bobobei:
                guard let motion = command.motion, let vibration = command.vibration,
                      let rotation = command.rotation,
                      [motion, vibration, rotation].allSatisfy({ (0...100).contains($0) }) else {
                    throw CoveError.message("服务器下发了无效的啵啵贝指令。")
                }
                levels = (motion, vibration, rotation)
            case .fenxin:
                guard let level = command.level, (0...100).contains(level) else {
                    throw CoveError.message("服务器下发了无效的分欣指令。")
                }
                levels = (level, 0, 0)
            }
            while generation == token, session?.id == sessionID {
                guard command.expiresAt.map({ $0 > Date() }) != false else {
                    throw CoveError.message("指令已过期，不会在重连后补执行。")
                }
                guard bluetooth.hasSession else { throw CoveError.message("蓝牙会话已结束。") }
                if !bluetooth.controlReady || bluetooth.writeInProgress {
                    status = "蓝牙正在自动重连；过期指令不会补执行"
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                do {
                    if command.kind == "stop" { try await bluetooth.stopToy() }
                    else {
                        try await bluetooth.setToyLevels(
                            motion: levels.motion, vibration: levels.vibration, rotation: levels.rotation)
                    }
                    break
                } catch {
                    guard bluetooth.hasSession else { throw error }
                    status = "蓝牙写入未确认，正在自动重连并重试"
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            guard generation == token, session?.id == sessionID else { return }
            if command.kind == "stop" {
                lastLevels = (0, 0, 0)
                status = "助手已停下"
                try await store.acknowledgeToyCommand(sessionID: sessionID, commandID: command.id,
                                                      status: "stopped", startedAt: Date(), stopAt: Date(), error: nil)
                startKeepAlive(token, sessionID: sessionID)
                return
            }
            let started = Date()
            lastLevels = levels
            status = "助手正在控制"
            try await store.acknowledgeToyCommand(sessionID: sessionID, commandID: command.id,
                                                  status: "started", startedAt: started, stopAt: nil, error: nil)
            startKeepAlive(token, sessionID: sessionID)
        } catch {
            try? await store.acknowledgeToyCommand(sessionID: sessionID, commandID: command.id,
                                                   status: "failed", startedAt: nil, stopAt: nil,
                                                   error: error.localizedDescription)
            status = "这条指令没有写成功，控制权仍由助手保留"
            if generation == token, session?.id == sessionID {
                startKeepAlive(token, sessionID: sessionID)
            }
        }
    }

    private func startKeepAlive(_ token: UUID, sessionID: String) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, self.generation == token, self.session?.id == sessionID,
                      let bluetooth = self.bluetooth else { return }
                guard bluetooth.hasSession else {
                    await self.stopAndRevoke(reason: "蓝牙会话已结束，控制权已收回")
                    return
                }
                if !bluetooth.controlReady || bluetooth.writeInProgress {
                    self.status = "蓝牙正在自动重连，控制权仍由助手保留"
                    continue
                }
                do {
                    try await bluetooth.keepToyAlive(
                        motion: self.lastLevels.motion,
                        vibration: self.lastLevels.vibration,
                        rotation: self.lastLevels.rotation)
                } catch {
                    if bluetooth.hasSession {
                        self.status = "蓝牙写入未确认，正在自动重连"
                        continue
                    }
                    return
                }
            }
        }
    }

    private func stopAndRevoke(reason: String, revokeServer: Bool = true) async {
        let old = session
        generation = UUID()
        polling?.cancel()
        keepAlive?.cancel()
        if let bluetooth { try? await bluetooth.stopToy() }
        lastLevels = (0, 0, 0)
        session = nil
        status = reason
        if revokeServer, let old, let store { try? await store.revokeToyControl(sessionID: old.id) }
    }
}
