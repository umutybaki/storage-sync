@preconcurrency import AppKit
import Foundation

public enum VolumeEvent: Sendable {
    case mounted(URL)
    case willUnmount(URL)
    case unmounted(URL)
    case renamed(URL)
}

public final class VolumeEventMonitor: @unchecked Sendable {
    public init() {}

    public func updates() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let observers = [
                center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { notification in
                    if let url = Self.volumeURL(notification) { continuation.yield(.mounted(url)) }
                },
                center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { notification in
                    if let url = Self.volumeURL(notification) { continuation.yield(.willUnmount(url)) }
                },
                center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { notification in
                    if let url = Self.volumeURL(notification) { continuation.yield(.unmounted(url)) }
                },
                center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: nil) { notification in
                    if let url = Self.volumeURL(notification) { continuation.yield(.renamed(url)) }
                }
            ]
            continuation.onTermination = { _ in
                for observer in observers { center.removeObserver(observer) }
            }
        }
    }

    private static func volumeURL(_ notification: Notification) -> URL? {
        notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }
}
