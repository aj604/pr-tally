import Foundation
import Network

/// Whether the Mac can reach the internet, as the system sees it.
public struct NetworkStatus: Sendable {
    /// Says whether the network is usable now, and again each time the system re-checks it.
    let changes: @Sendable () -> AsyncStream<Bool>

    init(changes: @escaping @Sendable () -> AsyncStream<Bool>) {
        self.changes = changes
    }

    /// A path that comes up when something connects, such as an on-demand VPN, never reads as satisfied until
    /// a fetch tries it, so only an unsatisfied path counts as offline.
    static func isUsable(_ status: NWPath.Status) -> Bool {
        status != .unsatisfied
    }

    public static let system = NetworkStatus {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield(isUsable($0.status)) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "PR Tally network"))
        }
    }
}
