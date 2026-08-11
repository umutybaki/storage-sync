import DiskArbitration
import Foundation

/// Participates in macOS's normal (non-forced) unmount approval flow. The
/// callback waits briefly for StorageSync to checkpoint affected transfers and
/// release file handles before allowing Disk Arbitration to continue.
public final class VolumeUnmountApprover: @unchecked Sendable {
    public typealias Handler = @Sendable (URL) async -> Bool

    private let session: DASession
    private let callbackQueue = DispatchQueue(label: "app.photosync.volume-unmount-approval")
    fileprivate let handler: Handler
    fileprivate let timeout: DispatchTimeInterval

    public init?(timeout: Duration = .seconds(20), handler: @escaping Handler) {
        guard let session = DASessionCreate(nil) else { return nil }
        self.session = session
        self.handler = handler
        let components = timeout.components
        let nanoseconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let attoseconds = components.attoseconds / 1_000_000_000
        let combined = nanoseconds.partialValue.addingReportingOverflow(attoseconds)
        self.timeout = .nanoseconds(
            combined.overflow || nanoseconds.overflow
                ? Int.max
                : max(0, Int(clamping: combined.partialValue))
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskUnmountApprovalCallback(
            session,
            nil,
            storageSyncDiskUnmountApproval,
            context
        )
        DASessionSetDispatchQueue(session, callbackQueue)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
    }
}

private final class UnmountApprovalResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func storageSyncDiskUnmountApproval(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<DADissenter>? {
    guard let context,
          let description = DADiskCopyDescription(disk) as? [CFString: Any],
          let volumeURL = description[kDADiskDescriptionVolumePathKey] as? URL else {
        return nil
    }

    let approver = Unmanaged<VolumeUnmountApprover>.fromOpaque(context).takeUnretainedValue()
    let semaphore = DispatchSemaphore(value: 0)
    let result = UnmountApprovalResult()
    Task.detached(priority: .userInitiated) {
        result.set(await approver.handler(volumeURL))
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + approver.timeout) == .success,
          result.get() else {
        let dissenter = DADissenterCreate(
            nil,
            DAReturn(kDAReturnBusy),
            "StorageSync is still safely checkpointing this drive. Try ejecting it again in a moment." as CFString
        )
        return Unmanaged.passRetained(dissenter)
    }
    return nil
}
