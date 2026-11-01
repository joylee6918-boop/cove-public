// Explicit synthetic fixtures; no GPS, Apple lookup, upload, model or app launch.
import Foundation
import CoreLocation
import MapKit
import Contacts

@MainActor final class FakeGeocoder: LocationGeocoding {
    var callbacks: [([CLPlacemark]?, Error?) -> Void] = []
    var coordinates: [CLLocationCoordinate2D] = []
    var cancellations = 0
    func lookup(_ location: CLLocation, completion: @escaping ([CLPlacemark]?, Error?) -> Void) {
        coordinates.append(location.coordinate); callbacks.append(completion)
    }
    func cancelLookup() { cancellations += 1 }
}

@main struct AddressTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let fixture = SharedLocation(latitude: 30, longitude: 110, accuracyMeters: 27,
                                     capturedAt: "2026-11-01T12:00:00Z", source: "current", name: "当前位置")
        let postal = CNMutablePostalAddress()
        postal.country = "中国"; postal.isoCountryCode = "CN"; postal.state = "测试省"
        postal.city = "测试市"; postal.street = "测试路100号（合成测试，非真实地址）"
        let place = MKPlacemark(coordinate: fixture.coordinate, postalAddress: postal)
        let addressed = fixture.addressed(with: place)
        check(addressed.address?.contains("测试路100号") == true, "readable service street included")
        check(addressed.address?.contains("\n") == false, "postal address flattened")
        check(addressed.latitude == fixture.latitude && addressed.longitude == fixture.longitude, "coordinates immutable")
        check(addressed.accuracyMeters == fixture.accuracyMeters && addressed.capturedAt == fixture.capturedAt && addressed.source == fixture.source, "GPS evidence immutable")
        check(addressed.valid, "wire remains valid")
        check(SharedLocation.parse(addressed.message) == addressed, "chat roundtrip retains address")
        let data = try JSONEncoder().encode(addressed)
        let ai = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(ai["address"] as? String == addressed.address, "model payload carries actual address")
        check(addressed.displayAddress == addressed.address, "card and payload agree")
        check(fixture.addressed(with: nil) == fixture, "missing place does not invent anything")
        check(SharedLocation.parse(fixture.message) == fixture, "old cards remain readable")
        check(fixture.displayAddress.hasPrefix("地址未能解析"), "missing address explicit")
        check(fixture.displayAddress.contains("30.00000, 110.00000"), "fallback retains coordinates")
        check(SharedLocation.label(" \n\t ") == nil, "blank label absent")
        check(SharedLocation.label(String(repeating: "测", count: 300))?.count == 240, "wire label bound")
        let selected = SharedLocation(latitude: 31, longitude: 111, accuracyMeters: 0,
                                      capturedAt: fixture.capturedAt, source: "selected", name: "合成选点名称")
        let chosen = selected.addressed(with: place)
        check(chosen.name == selected.name && chosen.source == "selected" && chosen.latitude == 31, "chosen POI and source retained")
        var search = selected; search.address = "搜索返回的测试地址"
        check(search.addressed(with: place).address == search.address, "search address not overwritten")

        func awaitCalls(_ geo: FakeGeocoder, _ count: Int) async throws {
            for _ in 0..<1000 {
                if geo.callbacks.count >= count { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            preconditionFailure("lookup did not start")
        }
        let geo = FakeGeocoder()
        let resolver = LocationAddressResolver(geocoder: geo, timeout: .seconds(2))
        let success = Task { try await resolver.resolve(fixture) }
        try await awaitCalls(geo, 1)
        check(resolver.busy, "lookup participates in busy guard")
        check(geo.coordinates[0].latitude == fixture.latitude && geo.coordinates[0].longitude == fixture.longitude, "lookup uses exact snapshot")
        geo.callbacks[0]([place], nil)
        check(try await success.value == addressed, "async successful enrichment")
        check(!resolver.busy, "completion releases busy state")

        let failure = Task { try await resolver.resolve(fixture) }
        try await awaitCalls(geo, 2)
        geo.callbacks[1](nil, NSError(domain: "SyntheticOffline", code: 1))
        check(try await failure.value == fixture, "lookup failure still shares real GPS")
        let empty = Task { try await resolver.resolve(fixture) }
        try await awaitCalls(geo, 3); geo.callbacks[2]([], nil)
        check(try await empty.value == fixture, "empty result preserved")

        let cancelled = Task { try await resolver.resolve(fixture) }
        try await awaitCalls(geo, 4); cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancellation swallowed") }
        catch is CancellationError { checks += 1 }
        check(!resolver.busy, "task cancellation releases busy state")
        let revoked = Task { try await resolver.resolve(fixture) }
        try await awaitCalls(geo, 5); resolver.cancel()
        do { _ = try await revoked.value; preconditionFailure("revoke swallowed") }
        catch is CancellationError { checks += 1 }

        let old = Task { try await resolver.resolve(fixture) }
        try await awaitCalls(geo, 6)
        let next = Task { try await resolver.resolve(selected) }
        try await awaitCalls(geo, 7)
        do { _ = try await old.value; preconditionFailure("old lookup survived replacement") }
        catch is CancellationError { checks += 1 }
        geo.callbacks[5]([place], nil)
        try await Task.sleep(for: .milliseconds(5))
        check(resolver.busy, "stale callback cannot complete new lookup")
        geo.callbacks[6]([place], nil)
        check(try await next.value == chosen, "new selection gets its own result")
        geo.callbacks[6]([place], nil) // duplicate callback must not double-resume
        try await Task.sleep(for: .milliseconds(5))
        check(!resolver.busy, "duplicate callback harmless")

        let slow = FakeGeocoder()
        let bounded = LocationAddressResolver(geocoder: slow, timeout: .milliseconds(25))
        let timedOut = try await bounded.resolve(fixture)
        check(timedOut == fixture && !bounded.busy, "timeout returns original GPS, not failure")
        slow.callbacks[0]([place], nil)
        try await Task.sleep(for: .milliseconds(5))
        check(!bounded.busy && slow.cancellations >= 2, "timeout cancels underlying service and ignores late result")
        print("PASS \(checks) actual Swift address/serialization/timeout/cancellation checks (fake geocoder)")
    }
}
