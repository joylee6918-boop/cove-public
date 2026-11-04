import Foundation

@MainActor enum CoveGeofences {
    static func configure(preview: Bool = false) {
        guard !preview, !ProcessInfo.processInfo.arguments.contains("--preview") else {
            GeofenceSharing.shared.disconnect(); return
        }
        GeofenceSharing.shared.configure {
            guard let raw = UserDefaults.standard.string(forKey: "cove.serverURL"),
                  let url = URL(string: raw), url.scheme == "https",
                  let token = CoveKeychainCredentials().read(account: raw), !token.isEmpty else { return nil }
            return (url.appendingPathComponent("v1/location/geofences"), token, "Authorization")
        }
    }
}
