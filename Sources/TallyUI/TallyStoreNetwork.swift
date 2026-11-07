import Foundation
import Network

/// Whether the Mac can reach the internet, as the system sees it.
public struct NetworkStatus: Sendable {
    /// Says whether the network is usable now, and again each time the system re-checks it.
    let changes: @Sendable () -> AsyncStream<Bool>

    init(changes: @escaping @Sendable () -> AsyncStream<Bool>) {
        self.changes = changes
    }

    public static let system = NetworkStatus {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "PR Tally network"))
        }
    }
}
