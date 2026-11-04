import Foundation

@main struct GeofenceTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = GeofenceArchive()
        check(!state.enabled && state.valid && !state.dirty, "default off")
        state.observe(placeID: "home", state: "inside", kind: "transition", at: start)
        check(state.outbox.isEmpty, "off produces no events")
        state.places = [.init(id: "home", latitude: 1, longitude: 2, address: "Synthetic fixture", radiusMeters: 300)]
        state.enabled = true; state.revise()
        state.observe(placeID: "home", state: "inside", kind: "initial", at: start)
        check(state.outbox.count == 1 && state.outbox[0].kind == "initial", "initial is not an arrival")
        check(state.outbox[0].summary.contains("状态确认"), "initial UI distinction")
        state.observe(placeID: "home", state: "inside", kind: "transition", at: start.addingTimeInterval(5))
        check(state.outbox.count == 1, "duplicate state suppressed")
        state.observe(placeID: "home", state: "outside", kind: "transition", at: start.addingTimeInterval(20))
        check(state.outbox.count == 2 && state.states["home"]?.state == "outside", "exit retained even near entry")
        state.observe(placeID: "home", state: "outside", kind: "reconcile", at: start.addingTimeInterval(30))
        check(state.outbox.count == 2, "duplicate state confirmation coalesced")
        state.observe(placeID: "home", state: "outside", kind: "reconcile", at: start.addingTimeInterval(120))
        check(state.outbox.count == 3 && state.outbox.last?.kind == "reconcile", "relaunch observation not transition")
        let data = try JSONEncoder().encode(state)
        let loaded = try JSONDecoder().decode(GeofenceArchive.self, from: data)
        check(loaded == state, "durable queue exact roundtrip including IDs")
        let wire = try JSONSerialization.data(withJSONObject: state.configuration(expectedRevision: "fixture-old"))
        let text = String(decoding: wire, as: UTF8.self)
        check(!text.contains("latitude") && !text.contains("address") && !text.contains("Synthetic"), "centers stay on phone")
        let eventWire = String(decoding: try JSONEncoder().encode(state.outbox[0]), as: UTF8.self)
        check(!eventWire.contains("latitude") && !eventWire.contains("address"), "events are not GPS fixes")
        state.observe(placeID: "unknown", state: "inside", kind: "transition", at: start)
        check(state.outbox.count == 3, "unknown region rejected")
        let oldRevision = state.revision
        state.enabled = false; state.revise()
        check(state.revision != oldRevision && state.outbox.isEmpty && state.states.isEmpty && state.dirty, "revoke invalidates pending")
        state.enabled = true; state.revise()
        for i in 0..<70 {
            state.observe(placeID: "home", state: i % 2 == 0 ? "inside" : "outside", kind: "transition", at: start.addingTimeInterval(Double(i)))
        }
        check(state.outbox.count == 64 && state.droppedCount == 6, "bounded outbox reports gaps")
        check(state.outbox.last?.sequence == 70 && state.states["home"]?.state == "outside", "latest state retained")
        state.expire(at: start.addingTimeInterval(8*86400))
        check(state.outbox.isEmpty && state.droppedCount == 70, "old offline data expires explicitly")
        var bad = state; bad.places[0].latitude = .nan
        check(!bad.valid, "nonfinite point invalid")
        bad = state; bad.version = 99
        check(!bad.valid, "future file does not load")
        bad = state; bad.places[0].radiusMeters = 99
        check(!bad.valid, "bounded radius")
        check(GeofencePresence.state(distance: 20, accuracy: 30, radius: 300) == "inside", "fresh fix at home establishes presence")
        check(GeofencePresence.state(distance: 600, accuracy: 50, radius: 300) == "outside", "fresh outside state")
        check(GeofencePresence.state(distance: 290, accuracy: 40, radius: 300) == nil, "boundary accuracy stays uncertain")
        check(GeofencePresence.state(distance: 20, accuracy: -1, radius: 300) == nil, "invalid accuracy rejected")
        var presence = GeofenceArchive()
        presence.places = [.init(id: "home", latitude: 1, longitude: 2, address: "Synthetic home"),
                           .init(id: "work", latitude: 3, longitude: 4, address: "Synthetic work")]
        presence.enabled = true
        check(GeofencePresence.title(places: presence.places, states: presence.states, now: start) == "位置待确认", "no empty status")
        presence.observe(placeID: "home", state: "inside", kind: "initial", at: start)
        presence.observe(placeID: "work", state: "outside", kind: "initial", at: start)
        check(GeofencePresence.title(places: presence.places, states: presence.states, now: start) == "在家", "initial state displays at home without a crossing")
        check(presence.outbox.allSatisfy { $0.kind == "initial" }, "foreground confirmation is not a transition")
        presence.observe(placeID: "home", state: "outside", kind: "reconcile", at: start.addingTimeInterval(60))
        presence.observe(placeID: "work", state: "inside", kind: "reconcile", at: start.addingTimeInterval(60))
        check(GeofencePresence.title(places: presence.places, states: presence.states, now: start.addingTimeInterval(60)) == "在公司", "company presence")
        check(GeofencePresence.title(places: presence.places, states: presence.states, now: start.addingTimeInterval(1000)) == "上次确认：在公司", "old state not called current")
        presence.observe(placeID: "work", state: "outside", kind: "reconcile", at: start.addingTimeInterval(120))
        check(GeofencePresence.title(places: presence.places, states: presence.states, now: start.addingTimeInterval(120)) == "不在家或公司范围内", "both outside")
        print("\(checks) actual Swift model checks passed; all locations synthetic.")
    }
}
