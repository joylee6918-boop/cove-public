import Foundation

// Phone-local centers. The wire config intentionally contains no coordinates/address.
struct GeofencePlace: Codable, Equatable, Identifiable {
    let id: String
    var latitude: Double
    var longitude: Double
    var address: String
    var radiusMeters: Double = 300
    var title: String { id == "home" ? "家" : "公司" }
    var valid: Bool {
        ["home", "work"].contains(id) && latitude.isFinite && longitude.isFinite
        && (-90...90).contains(latitude) && (-180...180).contains(longitude)
        && radiusMeters.isFinite && (100...1000).contains(radiusMeters) && address.count <= 500
    }
}
struct GeofenceEvent: Codable, Equatable, Identifiable {
    let id: String
    let revision: String
    let deviceID: String
    let sequence: Int
    let placeID: String
    let state: String
    let kind: String
    let observedAt: String
    var date: Date? { ISO8601DateFormatter().date(from: observedAt) }
    var summary: String {
        let place = placeID == "home" ? "家" : "公司"
        if kind == "transition" { return state == "inside" ? "进入\(place)的范围" : "离开\(place)的范围" }
        return "\(place)：\(state == "inside" ? "范围内" : "范围外")（状态确认）"
    }
}
struct GeofenceArchive: Codable, Equatable {
    var version = 1
    var deviceID = UUID().uuidString.lowercased()
    var revision = UUID().uuidString.lowercased()
    var enabled = false
    var places: [GeofencePlace] = []
    var dirty = false
    var sequence = 0
    var states: [String: GeofenceEvent] = [:]
    var outbox: [GeofenceEvent] = []
    var lastUploadedAt: Date?
    var droppedCount = 0
    var valid: Bool {
        version == 1 && places.count <= 2 && places.allSatisfy(\.valid)
        && Set(places.map(\.id)).count == places.count && outbox.count <= 64
        && (!enabled || !places.isEmpty)
        && outbox.allSatisfy { $0.revision == revision && $0.deviceID == deviceID }
    }
    mutating func revise() {
        revision = UUID().uuidString.lowercased()
        dirty = true; states = [:]; outbox = []; sequence = 0; lastUploadedAt = nil
    }
    mutating func observe(placeID: String, state: String, kind: String, at date: Date) {
        guard enabled, places.contains(where: { $0.id == placeID }), ["inside", "outside"].contains(state),
              ["initial", "transition", "reconcile"].contains(kind) else { return }
        if let last = states[placeID], last.state == state {
            if kind == "transition" || date.timeIntervalSince(last.date ?? date) < 60 { return }
        }
        sequence += 1
        let value = GeofenceEvent(id: UUID().uuidString.lowercased(), revision: revision, deviceID: deviceID,
                                  sequence: sequence, placeID: placeID, state: state, kind: kind,
                                  observedAt: date.ISO8601Format())
        states[placeID] = value; outbox.append(value)
        if outbox.count > 64 { droppedCount += outbox.count - 64; outbox.removeFirst(outbox.count - 64) }
    }
    mutating func expire(at date: Date) {
        let oldCount = outbox.count
        outbox.removeAll { date.timeIntervalSince($0.date ?? .distantPast) > 7 * 86400 }
        droppedCount += oldCount - outbox.count
    }
    func configuration(expectedRevision: String) -> [String: Any] {
        ["expectedRevision": expectedRevision, "revision": revision, "deviceID": deviceID, "enabled": enabled,
         "places": places.map { ["id": $0.id, "radiusMeters": $0.radiusMeters] as [String: Any] }]
    }
}
enum GeofencePresence {
    static func state(distance: Double, accuracy: Double, radius: Double) -> String? {
        guard distance.isFinite, accuracy.isFinite, radius.isFinite, distance >= 0, accuracy >= 0, radius > 0 else { return nil }
        if distance + accuracy <= radius { return "inside" }
        if distance - accuracy > radius { return "outside" }
        return nil // uncertain boundary/accuracy is not a fabricated arrival
    }
    static func title(places: [GeofencePlace], states: [String: GeofenceEvent], now: Date = Date()) -> String {
        let known = places.compactMap { place -> (GeofencePlace, GeofenceEvent)? in
            guard let event = states[place.id] else { return nil }
            return (place, event)
        }
        let fresh = known.filter { _, event in
            guard let date = event.date else { return false }
            return (-15...900).contains(now.timeIntervalSince(date))
        }
        let inside = fresh.filter { $0.1.state == "inside" }
        if inside.count > 1 { return "在家与公司的重叠范围" }
        if let place = inside.first?.0 { return "在" + place.title }
        if !places.isEmpty && fresh.count == places.count && fresh.allSatisfy({ $0.1.state == "outside" }) {
            return places.count == 2 ? "不在家或公司范围内" : "不在" + places[0].title + "的范围内"
        }
        if let old = known.filter({ $0.1.state == "inside" }).max(by: { $0.1.sequence < $1.1.sequence }) {
            return "上次确认：在" + old.0.title
        }
        return "位置待确认"
    }
}
struct GeofenceAccess: Decodable {
    let revision: String
    let enabled: Bool
    let deviceID: String?
}
struct GeofenceWire: Decodable {
    var access: GeofenceAccess?
    var ok: Bool?
    var eventID: String?
}
