import SwiftUI
import CoreLocation
import MapKit
import Combine
import CryptoKit
import Contacts

// Location grants and device bindings are scoped to this app/backend instance.
struct SharedLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let capturedAt: String
    let source: String
    var name: String?
    var address: String?
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: capturedAt) ?? ISO8601DateFormatter().date(from: capturedAt)
    }
    var valid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && accuracyMeters.isFinite && (0...100000).contains(accuracyMeters)
            && ["current", "selected"].contains(source) && date != nil
            && (name?.count ?? 0) <= 240 && (address?.count ?? 0) <= 240
    }
    static func label(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return value.isEmpty ? nil : String(value.prefix(240))
    }
    var displayName: String { Self.label(name) ?? (source == "current" ? "当前位置" : "选定地点") }
    var displayAddress: String { Self.label(address) ?? "地址未能解析 · \(coordinateText)" }
    var coordinateText: String { String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude) }
    func addressed(with place: CLPlacemark?) -> Self {
        guard let place else { return self }
        var copy = self
        let postal = place.postalAddress.flatMap { Self.label(CNPostalAddressFormatter.string(from: $0, style: .mailingAddress)) }
        // Keep actual service components; never invent a street/house number.
        var parts: [String] = []
        for part in [place.country, place.administrativeArea, place.locality, place.subLocality, place.thoroughfare, place.subThoroughfare] {
            if let part = Self.label(part), !parts.contains(part) { parts.append(part) }
        }
        copy.address = Self.label(address) ?? postal ?? Self.label(parts.joined(separator: " "))
        if Self.label(name) == nil || ["当前位置", "地图选点"].contains(name ?? "") {
            copy.name = Self.label(place.name) ?? name
        }
        return copy // coordinates, accuracy, source and original capture time never change
    }
    var message: String {
        guard let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return "" }
        return "```location_share\n" + json + "\n```"
    }
    static func parse(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "```location_share\n", suffix = "\n```"
        guard value.count < 4096, value.hasPrefix(prefix), value.hasSuffix(suffix),
              let data = String(value.dropFirst(prefix.count).dropLast(suffix.count)).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.valid else { return nil }
        return decoded
    }
}
struct LocationGrant: Codable, Equatable { let enabled: Bool; let revision: String; let deviceID: String? }
struct PhoneLocationRequest: Decodable, Identifiable, Equatable {
    let id: String
    let reason: String
    let createdAt: Date
    let expiresAt: Date
    let status: String
    let revision: String
    let deviceID: String
    let snapshot: SharedLocation?
    let error: String?
}
struct LocationWire: Decodable {
    let access: LocationGrant?
    let requests: [PhoneLocationRequest]?
    let request: PhoneLocationRequest?
    let ok: Bool?
}
enum LocationFailure: String, LocalizedError {
    case permission_denied, location_disabled, timeout, unavailable
    var errorDescription: String? {
        switch self {
        case .permission_denied: return "定位权限未开启，请在 iPhone 设置中允许使用期间定位。"
        case .location_disabled: return "系统定位服务已关闭。"
        case .timeout: return "暂未取得新位置，可以稍后再试。"
        case .unavailable: return "定位暂不可用，尚未分享位置。"
        }
    }
}

@MainActor protocol LocationGeocoding: AnyObject {
    func lookup(_ location: CLLocation, completion: @escaping ([CLPlacemark]?, Error?) -> Void)
    func cancelLookup()
}
extension CLGeocoder: LocationGeocoding {
    func lookup(_ location: CLLocation, completion: @escaping ([CLPlacemark]?, Error?) -> Void) {
        reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_Hans_CN"), completionHandler: completion)
    }
    func cancelLookup() { cancelGeocode() }
}

// Resolve only newly captured/explicitly selected points, never historical cards.
// A bounded best-effort lookup must not turn a successful GPS fix into a failed share.
@MainActor final class LocationAddressResolver {
    private let geocoder: any LocationGeocoding
    private let timeout: Duration
    private var pending: CheckedContinuation<CLPlacemark?, Error>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    var busy: Bool { pending != nil }
    init(geocoder: any LocationGeocoding = CLGeocoder(), timeout: Duration = .seconds(8)) {
        self.geocoder = geocoder; self.timeout = timeout
    }
    func resolve(_ snapshot: SharedLocation) async throws -> SharedLocation {
        try Task.checkCancellation()
        cancel()
        let token = UUID(); generation = token
        let place: CLPlacemark? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.generation == token else { return }
                    self.finish(.success(nil))
                }
                geocoder.lookup(CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)) { [weak self] places, _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.finish(.success(places?.first))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.cancel()
            }
        }
        try Task.checkCancellation()
        return snapshot.addressed(with: place)
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ value: Result<CLPlacemark?, Error>) {
        generation = UUID()
        timer?.cancel(); timer = nil
        let continuation = pending; pending = nil
        geocoder.cancelLookup()
        continuation?.resume(with: value)
    }
}

// CoreLocation delivers delegate callbacks on the run loop where the manager was created (main).
@MainActor final class PhoneLocationCapture: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var permission: CheckedContinuation<Void, Error>?
    private var result: CheckedContinuation<CLLocation, Error>?
    private var timer: Task<Void, Never>?
    private var started = Date.distantPast
    private let addressResolver = LocationAddressResolver()
    var busy: Bool { permission != nil || result != nil || addressResolver.busy }
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    func authorize() async throws {
        guard CLLocationManager.locationServicesEnabled() else { throw LocationFailure.location_disabled }
        guard !busy, UIApplication.shared.applicationState == .active else { throw LocationFailure.unavailable }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return
        case .notDetermined:
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
                permission = value
                manager.requestWhenInUseAuthorization()
            }
        default: throw LocationFailure.permission_denied
        }
    }
    func capture() async throws -> SharedLocation {
        try await authorize()
        try Task.checkCancellation()
        guard !busy, UIApplication.shared.applicationState == .active else { throw LocationFailure.unavailable }
        started = Date()
        let location: CLLocation = try await withCheckedThrowingContinuation { value in
            result = value
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finish(.failure(LocationFailure.timeout))
            }
            manager.requestLocation()
        }
        try Task.checkCancellation()
        guard Date().timeIntervalSince(location.timestamp) <= 120 else { throw LocationFailure.timeout }
        let snapshot = SharedLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                      accuracyMeters: location.horizontalAccuracy, capturedAt: location.timestamp.ISO8601Format(),
                                      source: "current", name: "当前位置")
        return try await resolveAddress(snapshot)
    }
    func resolveAddress(_ snapshot: SharedLocation) async throws -> SharedLocation {
        try await addressResolver.resolve(snapshot)
    }
    func cancel() {
        addressResolver.cancel()
        manager.stopUpdatingLocation()
        permission?.resume(throwing: CancellationError()); permission = nil
        finish(.failure(CancellationError()))
    }
    private func finish(_ value: Result<CLLocation, Error>) {
        timer?.cancel(); timer = nil
        manager.stopUpdatingLocation()
        result?.resume(with: value); result = nil
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: permission?.resume(); permission = nil
        case .denied, .restricted:
            permission?.resume(throwing: LocationFailure.permission_denied); permission = nil
            finish(.failure(LocationFailure.permission_denied))
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard result != nil,
              let value = locations.last(where: {
                  $0.horizontalAccuracy >= 0 && $0.timestamp >= started.addingTimeInterval(-5)
                      && $0.timestamp <= Date().addingTimeInterval(15)
                      && CLLocationCoordinate2DIsValid($0.coordinate)
              }) else { return } // don't relabel a cached fix with the current time
        finish(.success(value))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        finish(.failure((error as? CLError)?.code == .denied ? LocationFailure.permission_denied : .unavailable))
    }
}

@MainActor final class LocationSharing: ObservableObject {
    typealias Transport = (String, Data?) async throws -> LocationWire
    @Published private(set) var access: LocationGrant?
    @Published private(set) var requests: [PhoneLocationRequest] = []
    @Published private(set) var paused = false
    @Published private(set) var changing = false
    @Published private(set) var error: String?
    let capture = PhoneLocationCapture()
    private(set) var identity = ""
    private var transport: Transport?
    private var epoch = UUID()
    private var refreshing = false
    private var uploading = false
    private var pending: [String: Data] = [:]
    private var lastAttempt = Date.distantPast
    private let deviceID: String
    private var pauseKey: String { "location.pause." + identity }
    var enabled: Bool { access?.enabled == true && access?.deviceID == deviceID && !paused }
    var latest: SharedLocation? { requests.first(where: { $0.snapshot != nil && $0.revision == access?.revision })?.snapshot }
    init() {
        let key = "location.device.v1"
        deviceID = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(deviceID, forKey: key)
    }
    func bind(identity raw: String, transport: @escaping Transport) {
        let key = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        if identity != key {
            invalidate()
            identity = key; access = nil; requests = []; pending = [:]; lastAttempt = .distantPast
            paused = UserDefaults.standard.bool(forKey: pauseKey)
        }
        self.transport = transport
    }
    func invalidate() {
        epoch = UUID(); capture.cancel()
    }
    func refresh() async {
        guard let transport, !refreshing, !changing, UIApplication.shared.applicationState == .active else { return }
        refreshing = true
        defer { refreshing = false }
        let token = epoch
        do {
            let wire = try await transport("status", nil)
            guard token == epoch, !Task.isCancelled else { return }
            if access != wire.access { access = wire.access }
            let next = wire.requests ?? []
            if requests != next { requests = next }
            pending = pending.filter { id, data in
                guard next.contains(where: { $0.id == id && $0.status == "pending" }) else { return false }
                // Only after an authoritative pending status may an unaccepted,
                // now-stale sample be replaced. Accepted ACKs never reacquire GPS.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let raw = object["snapshot"], let bytes = try? JSONSerialization.data(withJSONObject: raw),
                   let value = try? JSONDecoder().decode(SharedLocation.self, from: bytes), let date = value.date {
                    return Date().timeIntervalSince(date) < 115
                }
                return true
            }
            if paused {
                // A locally requested revoke survives an offline/unknown ACK.
                if let access, access.enabled, access.deviceID == deviceID { await setEnabled(false) }
                return
            }
            if enabled, !uploading, !capture.busy,
               Date().timeIntervalSince(lastAttempt) > 5,
               let item = requests.last(where: { $0.status == "pending" && $0.expiresAt > Date()
                   && $0.expiresAt.timeIntervalSince($0.createdAt) <= 601 && $0.revision == access?.revision && $0.deviceID == deviceID }) {
                await fulfill(item)
            }
        } catch { if token == epoch { self.error = "位置连接未确认：\(error.localizedDescription)" } }
    }
    func setEnabled(_ value: Bool) async {
        guard let transport, !changing, UIApplication.shared.applicationState == .active else { return }
        invalidate()
        let token = epoch
        changing = true
        if !value { paused = true; UserDefaults.standard.set(true, forKey: pauseKey); pending = [:] }
        defer { changing = false }
        do {
            if value { try await capture.authorize() }
            guard token == epoch, !Task.isCancelled else { return }
            let fresh = try await transport("status", nil)
            guard token == epoch, let grant = fresh.access else { throw LocationFailure.unavailable }
            let body = try JSONSerialization.data(withJSONObject: ["enabled": value, "revision": grant.revision, "deviceID": deviceID])
            let reply = try await transport("access", body)
            guard token == epoch, let updated = reply.access, updated.enabled == value else { throw LocationFailure.unavailable }
            access = updated; paused = !value; error = nil
            UserDefaults.standard.set(!value, forKey: pauseKey)
        } catch { if token == epoch { self.error = "授权保存未确认：\(error.localizedDescription)" } }
    }
    private func fulfill(_ item: PhoneLocationRequest) async {
        guard let transport, enabled else { return }
        let token = epoch
        uploading = true; lastAttempt = Date()
        defer { uploading = false }
        do {
            if pending[item.id] == nil {
                var body: [String: Any] = ["requestID": item.id, "revision": item.revision, "deviceID": deviceID]
                do {
                    let value = try await capture.capture()
                    body["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                } catch is CancellationError { return }
                catch {
                    body["error"] = (error as? LocationFailure ?? .unavailable).rawValue
                }
                guard token == epoch, enabled, item.expiresAt > Date(), !Task.isCancelled,
                      UIApplication.shared.applicationState == .active else { return }
                pending[item.id] = try JSONSerialization.data(withJSONObject: body)
            }
            guard token == epoch, enabled, !Task.isCancelled else { return }
            let result = try await transport("response", pending[item.id])
            guard token == epoch, result.ok == true else { return }
            pending[item.id] = nil
            if let updated = result.request, let index = requests.firstIndex(where: { $0.id == updated.id }) { requests[index] = updated }
            error = nil
        } catch { if token == epoch { self.error = "位置回传未确认，将核对原请求后重试。" } }
    }
}

struct LocationShareSettings: View {
    @ObservedObject var sharing: LocationSharing
    let companion: String
    var body: some View {
        Form {
            Section {
                Toggle("允许\(companion)按需查看位置", isOn: Binding(get: { sharing.enabled }, set: { value in Task { await sharing.setEnabled(value) } }))
                    .disabled(sharing.changing)
                Text("开启一次后，无需逐次确认。App 在前台时自动回传一次新定位；后台收到请求后，打开 App 即可继续。关闭立即停止本机取位，并同步撤销服务端授权。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("不持续追踪、不记录移动路线。系统的“使用 App 期间”权限与此持续授权是两层独立设置。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = sharing.error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: { Text("持续授权") }
            if let location = sharing.latest {
                Section("最近一次回传") { SharedLocationCard(location: location) }
            }
            Section("近期请求") {
                ForEach(sharing.requests.prefix(10)) { request in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.reason)
                        Text(label(request)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("位置共享")
        .task { await sharing.refresh() }
    }
    private func label(_ request: PhoneLocationRequest) -> String {
        switch request.status {
        case "succeeded": return "已回传 · " + request.createdAt.formatted(date: .abbreviated, time: .shortened)
        case "pending": return request.expiresAt > Date() ? "等待手机取得新位置" : "已过期"
        case "revoked": return "授权已关闭"
        case "expired": return "已过期，未取得位置"
        default: return "未取得位置 · " + (LocationFailure(rawValue: request.error ?? "")?.localizedDescription ?? "暂不可用")
        }
    }
}

struct SharedLocationCard: View {
    let location: SharedLocation
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(.init(center: location.coordinate, span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008))), interactionModes: []) {
                Marker(location.displayName, coordinate: location.coordinate)
            }.frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(location.displayName).font(.headline)
            Text(location.displayAddress).font(.subheadline).textSelection(.enabled)
            if let date = location.date {
                Text((location.source == "current" ? "定位于 " : "选点于 ") + date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if location.source == "current" { Text("精度约 \(Int(location.accuracyMeters.rounded())) 米").font(.caption2).foregroundStyle(.secondary) }
            else { Text("手动选定地点，不代表实际所在位置").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .contentShape(Rectangle()).onTapGesture { expanded = true }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                VStack(spacing: 12) {
                    Map(initialPosition: .region(.init(center: location.coordinate, span: .init(latitudeDelta: 0.015, longitudeDelta: 0.015)))) {
                        Marker(location.displayName, coordinate: location.coordinate)
                    }
                    Text(location.displayAddress).textSelection(.enabled).padding(.horizontal).padding(.bottom)
                }.navigationTitle(location.displayName).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { expanded = false } } }
            }
        }
    }
}

struct LocationPickerSheet: View {
    let send: (SharedLocation) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var capture = PhoneLocationCapture()
    @State private var location: SharedLocation?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var busy = false
    @State private var error: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var searchGeneration = UUID()
    @State private var selectionGeneration = UUID()
    @State private var selectionTask: Task<Void, Never>?
    @State private var resolvingAddress = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("搜索地点", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                    Button("搜索") { Task { await search() } }
                }.padding(.horizontal)
                Button { Task { await current() } } label: { Label("使用当前位置", systemImage: "location.fill") }.disabled(busy)
                if let location {
                    MapReader { proxy in
                        Map(position: $camera) { Marker(location.name ?? "选定位置", coordinate: location.coordinate) }
                            .onTapGesture { point in
                                if let coordinate = proxy.convert(point, from: .local) { choose(coordinate, name: "地图选点", address: nil) }
                            }
                    }.frame(minHeight: 200, maxHeight: 300)
                    Text(location.displayName).font(.headline)
                    Text(resolvingAddress ? "正在解析地址…" : location.displayAddress)
                        .font(.subheadline).padding(.horizontal)
                    Text(location.source == "current" ? "仅发送这次定位，精度约 \(Int(location.accuracyMeters)) 米" : "这是选定地点，不表示你已经在那里")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !results.isEmpty {
                    List(Array(results.enumerated()), id: \.offset) { _, item in
                        Button { choose(item.placemark.coordinate, name: item.name, address: item.placemark.title) } label: {
                            VStack(alignment: .leading) { Text(item.name ?? "地点"); Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).font(.footnote).padding(.horizontal) }
                Spacer(minLength: 0)
            }
            .navigationTitle("发送位置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { Task {
                        guard let location, !busy, !resolvingAddress else { return }
                        busy = true
                        do { try await send(location); dismiss() } catch { self.error = error.localizedDescription }
                        busy = false
                    } }.disabled(location == nil || busy || resolvingAddress)
                }
            }
            .onDisappear { cancelSelection(); searchGeneration = UUID() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancelSelection(); searchGeneration = UUID() }
            }
        }
    }
    private func cancelSelection() {
        selectionGeneration = UUID()
        selectionTask?.cancel(); selectionTask = nil
        capture.cancel(); resolvingAddress = false
    }
    private func choose(_ coordinate: CLLocationCoordinate2D, name: String?, address: String?) {
        guard !busy else { return }
        cancelSelection(); error = nil
        let value = SharedLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, accuracyMeters: 0,
                                   capturedAt: Date().ISO8601Format(), source: "selected",
                                   name: SharedLocation.label(name), address: SharedLocation.label(address))
        location = value
        camera = .region(.init(center: coordinate, span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008)))
        guard value.address == nil else { return }
        let token = selectionGeneration
        resolvingAddress = true
        selectionTask = Task {
            // Coalesce quick taps; late lookups cannot replace a new choice.
            do {
                try await Task.sleep(for: .milliseconds(300))
                let resolved = try await capture.resolveAddress(value)
                guard token == selectionGeneration, !Task.isCancelled else { return }
                location = resolved
                resolvingAddress = false
            } catch {
                if token == selectionGeneration { resolvingAddress = false }
            }
        }
    }
    private func current() async {
        guard !busy else { return }
        cancelSelection(); busy = true; error = nil
        let token = selectionGeneration
        defer { busy = false }
        do {
            let value = try await capture.capture()
            guard token == selectionGeneration, !Task.isCancelled else { return }
            location = value
            camera = .region(.init(center: value.coordinate, span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008)))
        } catch is CancellationError { }
        catch { if token == selectionGeneration { self.error = error.localizedDescription } }
    }
    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let token = UUID(); searchGeneration = token
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = term
        if let location { request.region = .init(center: location.coordinate, span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1)) }
        do {
            let found = try await MKLocalSearch(request: request).start()
            guard token == searchGeneration else { return }
            results = Array(found.mapItems.prefix(15)); error = results.isEmpty ? "没有找到匹配地点" : nil
        } catch { if token == searchGeneration { self.error = "地点搜索暂未成功" } }
    }
}
