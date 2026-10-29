import XCTest
@testable import Cove

@MainActor
final class CoveBluetoothConnectionTests: XCTestCase {
    private final class Transport: CoveBluetoothTransport {
        var onEvent: ((CoveBluetoothEvent) -> Void)?
        var scans = 0
        var stops = 0
        var connections: [UUID] = []
        var disconnects = 0
        var reconnects = 0
        var writes: [Data] = []
        func scan() { scans += 1 }
        func stopScan() { stops += 1 }
        func connect(_ id: UUID) { connections.append(id) }
        func reconnect() { reconnects += 1 }
        func disconnect() { disconnects += 1 }
        func write(_ data: Data) { writes.append(data); onEvent?(.writeCompleted(nil)) }
        func emit(_ event: CoveBluetoothEvent) { onEvent?(event) }
    }

    private let device = CoveNearbyDevice(id: UUID(), name: "SOSEXY-test", signal: -50)

    private func start(_ model: CoveBluetoothConnection, _ transport: Transport) {
        model.scanFromUserAction()
        transport.emit(.scanning)
        transport.emit(.found(device))
    }

    func testInitializationDoesNotTouchBluetooth() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(transport.scans + transport.stops + transport.disconnects, 0)
        XCTAssertTrue(transport.connections.isEmpty)
    }

    func testPreviewDoesNotScanConnectOrAcceptDiscovery() {
        let transport = Transport()
        let model = CoveBluetoothConnection(previewMode: true, transport: transport)
        start(model, transport)
        model.selectFromUserAction(device.id)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(transport.scans, 0)
        XCTAssertTrue(transport.connections.isEmpty)
        model.setPreviewMode(false)
        XCTAssertTrue(model.canScan)
    }

    func testDiscoveryFiltersDeduplicatesAndNeverAutoConnects() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        start(model, transport)
        transport.emit(.found(device))
        transport.emit(.found(.init(id: UUID(), name: "Unrelated", signal: -20)))
        XCTAssertEqual(model.devices, [device])
        XCTAssertTrue(transport.connections.isEmpty)
        XCTAssertTrue(CoveNearbyDevice.matches(" sosexy "))
        XCTAssertTrue(CoveNearbyDevice.matches("SL278H"))
        XCTAssertEqual(CoveToyKind.detect("SL278J"), .fenxin)
        XCTAssertFalse(CoveNearbyDevice.matches(nil))
        model.endSession()
    }

    func testFenxinPacketsMatchCapturedRelayFrames() {
        XCTAssertEqual(CoveFenxinProtocol.packet(level: 50),
                       Data([0x55, 0x04, 0x00, 0x00, 0x01, 0x80, 0xaa]))
        XCTAssertEqual(CoveFenxinProtocol.packet(level: 0),
                       Data([0x55, 0x04, 0x00, 0x00, 0x00, 0x00, 0xaa]))
        XCTAssertEqual(CoveFenxinProtocol.stopPackets, [
            Data([0x55, 0x04, 0x00, 0x00, 0x01, 0x00, 0xaa]),
            Data([0x55, 0x03, 0x03, 0x01, 0x00, 0x00, 0xaa]),
            Data([0x55, 0x05, 0x00, 0x00, 0x01, 0x00, 0xaa]),
        ])
    }

    func testOnlyDiscoveredSelectionConnectsAndCallbackGatesSuccess() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        start(model, transport)
        model.selectFromUserAction(UUID())
        XCTAssertTrue(transport.connections.isEmpty)
        model.selectFromUserAction(device.id)
        XCTAssertEqual(transport.connections, [device.id])
        XCTAssertEqual(model.phase, .connecting)
        transport.emit(.connected(UUID()))
        XCTAssertEqual(model.phase, .connecting)
        transport.emit(.connected(device.id))
        XCTAssertEqual(model.phase, .connected)
        XCTAssertFalse(model.controlReady)
        transport.emit(.controlReady(device.id))
        XCTAssertTrue(model.controlReady)
        XCTAssertTrue(model.status.contains("可以交给助手"))
        model.endSession()
    }

    func testDisconnectWaitsForAcknowledgementAndIgnoresLateConnection() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        start(model, transport)
        model.selectFromUserAction(device.id)
        model.endSession()
        XCTAssertEqual(model.phase, .disconnecting)
        XCTAssertEqual(transport.disconnects, 1)
        XCTAssertFalse(model.canScan)
        transport.emit(.connected(device.id))
        XCTAssertEqual(model.phase, .disconnecting)
        transport.emit(.disconnected(device.id, nil))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(transport.connections.count, 1)
    }

    func testUnexpectedDropKeepsSelectionAndCanBecomeReadyAgain() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        var ended = 0
        model.onSessionEnded = { ended += 1 }
        start(model, transport)
        model.selectFromUserAction(device.id)
        transport.emit(.connected(device.id))
        transport.emit(.controlReady(device.id))

        transport.emit(.reconnecting(device.id, "link lost"))
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertEqual(model.selectedID, device.id)
        XCTAssertFalse(model.controlReady)
        XCTAssertEqual(ended, 0)

        transport.emit(.connected(device.id))
        transport.emit(.controlReady(device.id))
        XCTAssertEqual(model.phase, .connected)
        XCTAssertTrue(model.controlReady)
        XCTAssertEqual(ended, 0)
    }

    func testBackgroundCancelsPreparationAndIgnoresLateScan() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        model.scanFromUserAction()
        model.enteredBackground()
        transport.emit(.scanning)
        transport.emit(.found(device))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(transport.scans, 1)
    }

    func testBackgroundDisconnectsPendingAndEstablishedConnections() {
        for connected in [false, true] {
            let transport = Transport()
            let model = CoveBluetoothConnection(transport: transport)
            start(model, transport)
            model.selectFromUserAction(device.id)
            if connected { transport.emit(.connected(device.id)) }
            model.enteredBackground()
            XCTAssertEqual(model.phase, .disconnecting)
            XCTAssertEqual(transport.disconnects, 1)
            transport.emit(.disconnected(device.id, nil))
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(transport.connections.count, 1)
            XCTAssertTrue(model.devices.isEmpty)
        }
    }

    func testRadioUnavailableClearsSessionWithoutReconnect() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        var ended = 0
        model.onSessionEnded = { ended += 1 }
        start(model, transport)
        model.selectFromUserAction(device.id)
        transport.emit(.connected(device.id))
        transport.emit(.unavailable("蓝牙已关闭"))
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(transport.scans, 1)
        XCTAssertEqual(transport.connections.count, 1)
        XCTAssertEqual(ended, 1)
    }

    func testEnteringPreviewDisconnectsAndAcceptsCancellationAcknowledgement() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        start(model, transport)
        model.selectFromUserAction(device.id)
        model.setPreviewMode(true)
        XCTAssertEqual(transport.disconnects, 1)
        transport.emit(.connected(device.id))
        XCTAssertEqual(model.phase, .disconnecting)
        transport.emit(.disconnected(device.id, nil))
        XCTAssertNil(model.selectedID)
        model.setPreviewMode(false)
        XCTAssertTrue(model.canScan)
    }

    func testScanTimeoutKeepsResultsForManualSelection() async throws {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport, scanDuration: .milliseconds(10))
        start(model, transport)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.devices, [device])
        XCTAssertTrue(transport.connections.isEmpty)
        model.enteredBackground()
        XCTAssertTrue(model.devices.isEmpty)
    }

    func testRadioLossWhileEnteringPreviewDoesNotStrandSelection() {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        start(model, transport)
        model.selectFromUserAction(device.id)
        model.setPreviewMode(true)
        transport.emit(.unavailable("蓝牙已关闭"))
        XCTAssertNil(model.selectedID)
        model.setPreviewMode(false)
        XCTAssertTrue(model.canScan)
    }

    func testConnectionTimeoutCancelsWithoutRetry() async throws {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport, connectionDuration: .milliseconds(10))
        start(model, transport)
        model.selectFromUserAction(device.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.phase, .disconnecting)
        XCTAssertEqual(transport.disconnects, 1)
        XCTAssertTrue(model.status.contains("连接超时"))
        transport.emit(.disconnected(device.id, nil))
        XCTAssertEqual(transport.connections.count, 1)
    }

    func testPreparationTimeoutDoesNotLeaveScanArmed() async throws {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport, connectionDuration: .milliseconds(10))
        model.scanFromUserAction()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertGreaterThan(transport.stops, 0)
        transport.emit(.scanning)
        XCTAssertEqual(model.phase, .idle)
    }

    func testControlPacketsAreAllowlistedAndAcknowledgedInOrder() async throws {
        let transport = Transport()
        let model = CoveBluetoothConnection(transport: transport)
        start(model, transport)
        model.selectFromUserAction(device.id)
        transport.emit(.connected(device.id))
        transport.emit(.controlReady(device.id))
        try await model.setToyLevels(motion: 35, vibration: 25, rotation: 20)
        XCTAssertEqual(transport.writes.map { $0.map { String(format: "%02x", $0) }.joined() }, [
            "010100020007112300081101",
            "010100020001111900021101",
            "010100020003111400041101"
        ])
        transport.writes = []
        try await model.stopToy()
        XCTAssertEqual(transport.writes.map { $0.map { String(format: "%02x", $0) }.joined() }, [
            "010100020007110000081101",
            "010100020001110000021101",
            "010100020003110000041101"
        ])
    }
}
