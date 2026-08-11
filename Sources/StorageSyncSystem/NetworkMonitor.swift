import Foundation
import Network

public enum NetworkAvailability: Sendable, Equatable {
    case available(isExpensive: Bool, isConstrained: Bool)
    case unavailable
}

public final class NetworkAvailabilityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.photosync.network-monitor")

    public init() {}

    public func updates() -> AsyncStream<NetworkAvailability> {
        AsyncStream { continuation in
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied {
                    continuation.yield(.available(isExpensive: path.isExpensive, isConstrained: path.isConstrained))
                } else {
                    continuation.yield(.unavailable)
                }
            }
            continuation.onTermination = { [monitor] _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
