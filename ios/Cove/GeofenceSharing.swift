import SwiftUI
import CoreLocation
import CryptoKit
import Network
import Combine

private enum GeofenceUploadError: LocalizedError {
    case unavailable(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable(404): return "服务器尚未接通地理围栏，设置已保存在手机，接通后自动补传。"
        case .unavailable(401), .unavailable(403): return "连接授权需要核对，围栏设置仍保存在手机。"
        case .unavailable(let status): return "围栏服务暂未接收（HTTP \(status)），已保留待传记录。"
        }
    }
}

private final class GeofenceNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// Lifetime belongs to UIApplicationDelegate, not to a foreground SwiftUI sheet.
@MainActor final class GeofenceSharing: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = GeofenceSharing()
    typealias Connection = () -> (base: URL, token: String, header: String)?
    @Published private(set) var archive = GeofenceArchive()
    @Published private(set) var error: String?
    @Published private(set) var uploading = false
    @Published private(set) var monitoringCount = 0
    @Published private(set) var permissionText = "尚未检查"
    @Published private(set) var locating = false
    @Published private(set) var presenceNote: String?
    @Published private(set) var presenceUncertain = false
    private var presenceRequest: (key: String, started: Date)?
    private var presenceTimeout: Task<Void, Never>?
    private var lastPresenceAttempt = Date.distantPast
    private var lastPresenceKey = ""
    var presenceTitle: String {
        presenceUncertain ? "位置待确认" : GeofencePresence.title(places: archive.places, states: archive.states)
    }
    private let manager = CLLocationManager()
    private let monitor = NWPathMonitor()
    private var connection: Connection?
    private var scope = ""
    private var file: URL?
    private var storageReady = false
    private var task: Task<Void, Never>?
    private var wantsSync = false
    private var continueAlwaysRequest = false
    private var backgroundID = UIBackgroundTaskIdentifier.invalid
    private let prefix = "shared.geofence.v1."
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 15
        config.urlCache = nil
        return URLSession(configuration: config, delegate: GeofenceNoRedirect(), delegateQueue: nil)
    }()
    private override init() {
        super.init()
        manager.delegate = self
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied, let self else { return }
            Task { @MainActor in self.wake() }
        }
        monitor.start(queue: DispatchQueue(label: "geofence.network"))
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.wake() }
        }
    }
    func configure(connection: @escaping Connection) {
        self.connection = connection
        wake()
    }
    func disconnect() {
        task?.cancel(); connection = nil; cancelPresence(); stopRegions()
        scope = ""; file = nil; storageReady = false; archive = GeofenceArchive()
    }
    private func bind() -> Bool {
        guard let value = connection?(), value.base.scheme == "https", !value.token.isEmpty else {
            cancelPresence(); stopRegions(); return false
        }
        let raw = value.base.absoluteString + ":" + value.token
        let key = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        if scope != key || !storageReady {
            // On a CoreLocation cold launch, leave restored regions registered so
            // their pending boundary callbacks can reach this new delegate.
            if !scope.isEmpty && scope != key { cancelPresence(); stopRegions() }
            scope = key; storageReady = false
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Geofences", isDirectory: true)
            file = root.appendingPathComponent(key + ".json")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try (root as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
                if let file, FileManager.default.fileExists(atPath: file.path) {
                    let saved = try JSONDecoder().decode(GeofenceArchive.self, from: Data(contentsOf: file))
                    guard saved.valid else { throw LocationFailure.unavailable }
                    archive = saved
                } else { archive = GeofenceArchive() }
                storageReady = true; error = nil
            } catch {
                stopRegions(); archive = GeofenceArchive()
                self.error = "围栏本机记录暂不可读；已暂停监控，未覆盖原记录。"
                return false
            }
        }
        return true
    }
    @discardableResult private func save(_ next: GeofenceArchive) -> Bool {
        guard storageReady, let file, next.valid else { return false }
        do {
            try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            archive = next
            return true
        } catch {
            cancelPresence(); stopRegions(); storageReady = false
            self.error = "围栏记录保存失败，已暂停本机监控；上传状态未确认。"
            return false
        }
    }
    var canMonitor: Bool {
        CLLocationManager.locationServicesEnabled() && manager.authorizationStatus == .authorizedAlways
        && manager.accuracyAuthorization == .fullAccuracy && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }
    private func updatePermission() {
        if !CLLocationManager.locationServicesEnabled() { permissionText = "系统定位已关闭" }
        else if manager.authorizationStatus != .authorizedAlways { permissionText = "需要“始终允许”定位" }
        else if manager.accuracyAuthorization != .fullAccuracy { permissionText = "需要开启“精确位置”" }
        else if !CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) { permissionText = "此设备不支持地理围栏" }
        else if UIApplication.shared.backgroundRefreshStatus != .available { permissionText = "后台 App 刷新不可用，后台事件可能无法送达" }
        else { permissionText = "始终允许 · 精确位置 · 后台刷新可用" }
    }
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened, let self else { return }
            Task { @MainActor in self.error = "请在 iPhone 设置中打开此 App 的定位权限。" }
        }
    }
    func requestPermission() {
        guard UIApplication.shared.applicationState == .active else { return }
        if manager.authorizationStatus == .notDetermined {
            continueAlwaysRequest = true
            manager.requestWhenInUseAuthorization()
        }
        else if manager.authorizationStatus == .authorizedWhenInUse {
            continueAlwaysRequest = false
            manager.requestAlwaysAuthorization()
        }
        else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    func setEnabled(_ enabled: Bool) {
        guard bind() else { return }
        updatePermission()
        if enabled && archive.places.isEmpty {
            error = "请先设置家或公司的位置。"
            return
        }
        var next = archive; next.enabled = enabled; next.revise()
        if !enabled { cancelPresence(); stopRegions() } // revoke locally before any network/IO wait
        guard save(next) else { return }
        error = nil
        if enabled && (manager.authorizationStatus != .authorizedAlways || manager.accuracyAuthorization != .fullAccuracy) {
            requestPermission()
        }
        reconcileRegions(); refreshPresence(force: true); kick()
    }
    func setPlace(_ place: GeofencePlace) throws {
        guard bind(), place.valid else { throw LocationFailure.unavailable }
        if manager.maximumRegionMonitoringDistance > 0 && place.radiusMeters > manager.maximumRegionMonitoringDistance {
            throw LocationFailure.unavailable
        }
        var next = archive
        next.places.removeAll { $0.id == place.id }; next.places.append(place)
        next.places.sort { $0.id < $1.id }; next.revise()
        guard save(next) else { throw LocationFailure.unavailable }
        error = nil; reconcileRegions(); refreshPresence(force: true); kick()
    }
    func removePlace(_ id: String) {
        guard bind() else { return }
        var next = archive; next.places.removeAll { $0.id == id }
        if next.places.isEmpty { next.enabled = false }
        next.revise()
        guard save(next) else { return }
        cancelPresence(); reconcileRegions(); refreshPresence(force: true); kick()
    }
    func wake() {
        guard bind() else { return }
        updatePermission()
        // The switch records the owner's choice. System capability controls only
        // actual monitoring; neither permission callbacks nor offline upload flip it.
        reconcileRegions()
        refreshPresence()
        kick()
    }
    // One foreground fix establishes current presence without waiting for a
    // boundary crossing. No continuous GPS or reverse-geocoding request.
    func refreshPresence(force: Bool = false) {
        guard storageReady, archive.enabled, !archive.places.isEmpty,
              UIApplication.shared.applicationState == .active else { return }
        guard CLLocationManager.locationServicesEnabled(),
              [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) else {
            presenceNote = "允许定位后即可确认当前位置。"
            return
        }
        let key = scope + ":" + archive.revision
        if presenceRequest?.key == key { return }
        if !force && lastPresenceKey == key && Date().timeIntervalSince(lastPresenceAttempt) < 60 { return }
        cancelPresence()
        let started = Date()
        presenceRequest = (key, started); lastPresenceKey = key; lastPresenceAttempt = started
        locating = true; presenceNote = nil
        manager.desiredAccuracy = kCLLocationAccuracyBest
        presenceTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.presenceRequest?.started == started else { return }
            self.cancelPresence(); self.presenceUncertain = true
            self.presenceNote = "暂未取得新定位，可以点“更新位置”重试。"
        }
        manager.requestLocation()
    }
    private func cancelPresence() {
        presenceTimeout?.cancel(); presenceTimeout = nil
        presenceRequest = nil; locating = false
        manager.stopUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let request = presenceRequest, storageReady, archive.enabled,
              request.key == scope + ":" + archive.revision,
              let fix = locations.last(where: {
                  $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate)
                  && $0.timestamp >= request.started.addingTimeInterval(-5) && $0.timestamp <= Date().addingTimeInterval(15)
              }) else { return }
        cancelPresence()
        var next = archive
        var confirmed = 0, inside = false
        for place in archive.places {
            let center = CLLocation(latitude: place.latitude, longitude: place.longitude)
            guard let state = GeofencePresence.state(distance: fix.distance(from: center), accuracy: fix.horizontalAccuracy,
                                                      radius: place.radiusMeters) else { continue }
            confirmed += 1; inside = inside || state == "inside"
            next.observe(placeID: place.id, state: state, kind: next.states[place.id] == nil ? "initial" : "reconcile", at: fix.timestamp)
        }
        presenceUncertain = !inside && confirmed != archive.places.count
        presenceNote = presenceUncertain ? "定位精度暂不足以确认围栏状态，可稍后更新。" : nil
        if next != archive, save(next) { kick() }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard presenceRequest != nil else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        cancelPresence(); presenceUncertain = true
        presenceNote = "暂未取得当前位置，请检查定位权限后更新。"
    }
    private func stopRegions() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) { manager.stopMonitoring(for: region) }
        monitoringCount = 0
    }
    private func identifier(_ id: String) -> String { prefix + archive.revision + "." + id }
    private func placeID(_ region: CLRegion) -> String? {
        archive.places.first(where: { identifier($0.id) == region.identifier })?.id
    }
    private func reconcileRegions() {
        guard storageReady, archive.enabled else { stopRegions(); return }
        // Don't deregister intact regions just because low-power mode temporarily
        // disables Background App Refresh. The UI reports that limitation.
        guard canMonitor else { stopRegions(); return }
        let desired = Set(archive.places.map { identifier($0.id) })
        for old in manager.monitoredRegions where old.identifier.hasPrefix(prefix) && !desired.contains(old.identifier) {
            manager.stopMonitoring(for: old)
        }
        for place in archive.places {
            if let existing = manager.monitoredRegions.first(where: { $0.identifier == identifier(place.id) }) {
                if UIApplication.shared.applicationState == .active { manager.requestState(for: existing) }
            } else {
                let region = CLCircularRegion(center: .init(latitude: place.latitude, longitude: place.longitude),
                                              radius: place.radiusMeters, identifier: identifier(place.id))
                region.notifyOnEntry = true; region.notifyOnExit = true
                manager.startMonitoring(for: region)
            }
        }
        monitoringCount = manager.monitoredRegions.filter { desired.contains($0.identifier) }.count
    }
    private func observed(_ region: CLRegion, state: String, kind: String) {
        guard storageReady, archive.enabled, let id = placeID(region),
              manager.authorizationStatus == .authorizedAlways else { return }
        var next = archive
        next.observe(placeID: id, state: state, kind: kind, at: Date())
        guard next != archive, save(next) else { return }
        if state == "inside" { presenceUncertain = false; presenceNote = nil }
        kick()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if continueAlwaysRequest && archive.enabled && manager.authorizationStatus == .authorizedWhenInUse
            && UIApplication.shared.applicationState == .active {
            continueAlwaysRequest = false
            manager.requestAlwaysAuthorization()
        } else if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .denied {
            continueAlwaysRequest = false
        }
        wake()
    }
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard placeID(region) != nil, archive.enabled else { return }
        monitoringCount = manager.monitoredRegions.filter { placeID($0) != nil }.count
        manager.requestState(for: region)
    }
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region == nil || placeID(region!) != nil else { return }
        self.error = "系统未能注册围栏（\((error as NSError).code)）；请检查定位与网络。"
        if let region { manager.stopMonitoring(for: region) }
        monitoringCount = manager.monitoredRegions.filter { placeID($0) != nil }.count
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { observed(region, state: "inside", kind: "transition") }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { observed(region, state: "outside", kind: "transition") }
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let id = placeID(region), state != .unknown else { return }
        observed(region, state: state == .inside ? "inside" : "outside", kind: archive.states[id] == nil ? "initial" : "reconcile")
    }
    private func kick() {
        guard storageReady, archive.dirty || !archive.outbox.isEmpty else { return }
        if task != nil { wantsSync = true; return }
        wantsSync = false
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Geofence upload") { [weak self] in
            Task { @MainActor in self?.task?.cancel(); self?.endBackground() }
        }
        task = Task { [weak self] in
            guard let self else { return }
            await self.sync()
            self.task = nil; self.endBackground()
            if self.wantsSync { self.wantsSync = false; self.kick() }
        }
    }
    private func endBackground() {
        if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
    }
    private func request(_ action: String, body: Data? = nil, scope: String) async throws -> GeofenceWire {
        guard self.scope == scope, let value = connection?() else { throw CancellationError() }
        let current = SHA256.hash(data: Data((value.base.absoluteString + ":" + value.token).utf8)).map { String(format: "%02x", $0) }.joined()
        guard current == scope, value.base.scheme == "https", !value.token.isEmpty else { throw CancellationError() }
        let url = value.base.appendingPathComponent(action)
        var req = URLRequest(url: url); req.httpMethod = body == nil ? "GET" : "POST"; req.httpBody = body
        req.setValue(value.header == "Authorization" ? "Bearer " + value.token : value.token, forHTTPHeaderField: value.header)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard self.scope == scope else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw LocationFailure.unavailable }
        guard http.statusCode == 200 else { throw GeofenceUploadError.unavailable(http.statusCode) }
        return try JSONDecoder().decode(GeofenceWire.self, from: data)
    }
    private func sync() async {
        guard storageReady else { return }
        let revision = archive.revision, scope = scope
        uploading = true
        defer { uploading = false }
        do {
            let status = try await request("status", scope: scope)
            guard self.scope == scope, archive.revision == revision, let access = status.access else { return }
            if archive.dirty {
                if access.revision != revision || access.deviceID != archive.deviceID || access.enabled != archive.enabled {
                    let body = try JSONSerialization.data(withJSONObject: archive.configuration(expectedRevision: access.revision))
                    let reply = try await request("config", body: body, scope: scope)
                    guard self.scope == scope, archive.revision == revision else { return }
                    guard reply.ok == true, reply.access?.revision == revision else { throw LocationFailure.unavailable }
                }
                var next = archive; next.dirty = false
                guard save(next) else { return }
            } else if access.revision != revision || access.deviceID != archive.deviceID || access.enabled != archive.enabled {
                stopRegions()
                var next = archive; next.enabled = false; next.outbox = []; next.states = [:]
                guard save(next) else { return }
                error = "服务端围栏授权已改变；本机已暂停，请重新确认开启。"; return
            }
            var next = archive; next.expire(at: Date())
            if next != archive && !save(next) { return }
            // Ordered durable queue. Unknown ACK retries the same event, not GPS.
            while let event = archive.outbox.first, self.scope == scope, archive.revision == revision {
                let reply = try await request("event", body: JSONEncoder().encode(event), scope: scope)
                guard self.scope == scope, archive.revision == revision else { return }
                guard reply.ok == true, reply.eventID == event.id else { throw LocationFailure.unavailable }
                var next = archive; next.outbox.removeAll { $0.id == event.id }; next.lastUploadedAt = Date()
                guard save(next) else { return }
            }
            error = nil
        } catch is CancellationError { }
        catch {
            if self.scope == scope && archive.revision == revision {
                self.error = (error as? GeofenceUploadError)?.localizedDescription
                    ?? "暂未连上围栏服务；设置和待传事件已保存在手机，联网或回到 App 后补传。"
            }
        }
    }
}

struct GeofenceSettings: View {
    @ObservedObject var sharing: GeofenceSharing
    let companion: String
    @State private var editing: String?
    @State private var radius: Double = 300
    var body: some View {
        Form {
            Section("所在位置") {
                HStack(spacing: 12) {
                    Image(systemName: "location.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(!sharing.archive.enabled ? "自动分享已暂停" : sharing.locating && sharing.archive.states.isEmpty
                             ? "正在定位…" : sharing.presenceTitle).font(.title3.weight(.semibold))
                        if let note = sharing.presenceNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if sharing.locating { ProgressView() }
                }.padding(.vertical, 6)
                Button { sharing.refreshPresence(force: true) } label: { Label("更新位置", systemImage: "location") }
                    .buttonStyle(.borderless).disabled(sharing.locating || !sharing.archive.enabled)
            }
            Section("自动分享") {
                Toggle("自动分享给\(companion)", isOn: Binding(get: { sharing.archive.enabled }, set: sharing.setEnabled))
                Text("只分享进入或离开家、公司的事件，平时不上传移动路线。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("家与公司") {
                placeRow("home", title: "家")
                placeRow("work", title: "公司")
            }
            Section("状态") {
                Label(!sharing.archive.enabled ? "自动分享已暂停" : sharing.monitoringCount == 0
                      ? "已开启 · 等待系统允许监控" : "正在监控 \(sharing.monitoringCount) 个地点",
                      systemImage: sharing.monitoringCount > 0 ? "location.circle.fill" : "location.circle")
                    .font(.subheadline.weight(.medium))
                VStack(alignment: .leading, spacing: 8) {
                    Text(sharing.permissionText).font(.caption).foregroundStyle(.secondary)
                    if sharing.uploading { ProgressView("正在同步…").font(.caption) }
                    else { Text(sharing.archive.dirty ? "设置已保存到手机 · 等待同步" : "待上传事件：\(sharing.archive.outbox.count)").font(.caption) }
                    if let date = sharing.archive.lastUploadedAt {
                        Text("最近上传 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = sharing.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if sharing.archive.droppedCount > 0 { Text("\(sharing.archive.droppedCount) 条过期或超出容量的事件未保留").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 12) {
                    Button { sharing.openSystemSettings() } label: { Label("系统权限", systemImage: "gearshape") }
                    Spacer(minLength: 0)
                    Button { sharing.wake() } label: { Label("同步", systemImage: "arrow.clockwise") }
                }.buttonStyle(.bordered).controlSize(.regular)
            }
            Section("最近观察") {
                if sharing.archive.states.isEmpty { Text("尚无围栏事件，不代表在家或公司。").foregroundStyle(.secondary) }
                ForEach(sharing.archive.states.values.sorted { $0.sequence > $1.sequence }) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.summary)
                        if let date = event.date { Text(date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                Text("系统检测可能稍有延迟。断网时保留记录，联网后补传；首次状态确认不会算作刚到达。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("地理围栏")
        .onAppear { sharing.wake() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let id = editing {
                LocationPickerSheet(title: id == "home" ? "家的围栏" : "公司的围栏", actionTitle: "保存", radiusBinding: $radius,
                                    removePlace: sharing.archive.places.contains(where: { $0.id == id }) ? {
                                        sharing.removePlace(id); editing = nil
                                    } : nil,
                                    initialLocation: sharing.archive.places.first(where: { $0.id == id }).map {
                                        SharedLocation(latitude: $0.latitude, longitude: $0.longitude, accuracyMeters: 0,
                                                       capturedAt: Date().ISO8601Format(), source: "selected", name: $0.title, address: $0.address)
                                    }) { point in
                    try sharing.setPlace(GeofencePlace(id: id, latitude: point.latitude, longitude: point.longitude,
                                                      address: point.displayAddress, radiusMeters: radius))
                    editing = nil
                }
            }
        }
    }
    @ViewBuilder private func placeRow(_ id: String, title: String) -> some View {
        let place = sharing.archive.places.first { $0.id == id }
        Button { radius = place?.radiusMeters ?? 300; editing = id } label: {
            HStack(spacing: 14) {
                Image(systemName: id == "home" ? "house.fill" : "building.2.fill")
                    .font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        if let place {
                            Text("\(Int(place.radiusMeters)) 米").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(place?.address ?? "点这里，在地图上选择地点")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
