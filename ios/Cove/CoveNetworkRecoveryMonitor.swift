import Foundation
import Network

/// A path change is a recovery hint, never proof the Cove server is reachable.
/// Ignore the initial path report and coalesce actual changes on the main actor.
@MainActor
final class CoveNetworkRecoveryMonitor {
    private var monitor: NWPathMonitor?
    private var identity = UUID()
    private var previousSignature: String?
    private let queue = DispatchQueue(label: "com.example.cove.network-path")

    func start(onRecoveryHint: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        let id = UUID()
        identity = id
        let next = NWPathMonitor()
        monitor = next
        next.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted()
            let signature = "\(path.status)|\(interfaces.joined(separator: ","))|\(path.isConstrained)|\(path.isExpensive)"
            Task { @MainActor [weak self] in
                guard let self, self.identity == id, self.monitor != nil else { return }
                let previous = self.previousSignature
                self.previousSignature = signature
                if let previous, previous != signature, satisfied { onRecoveryHint() }
            }
        }
        next.start(queue: queue)
    }

    func stop() {
        identity = UUID()
        monitor?.cancel(); monitor = nil
        previousSignature = nil
    }
}
