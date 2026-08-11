import CoreServices
import Foundation

public enum FileSystemEvent: Sendable {
    case changed
    case mustRescan
    case rootChanged
}

public struct FileSystemEventMonitor: Sendable {
    public init() {}

    public func updates(root: URL) -> AsyncStream<FileSystemEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let subscription = FSEventSubscription(root: root, continuation: continuation)
            continuation.onTermination = { _ in subscription.cancel() }
            subscription.start()
        }
    }
}

private final class FSEventBox: @unchecked Sendable {
    let continuation: AsyncStream<FileSystemEvent>.Continuation
    init(_ continuation: AsyncStream<FileSystemEvent>.Continuation) { self.continuation = continuation }
}

private final class FSEventSubscription: @unchecked Sendable {
    private let root: URL
    private let continuation: AsyncStream<FileSystemEvent>.Continuation
    private let queue = DispatchQueue(label: "app.photosync.filesystem-events", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var retainedBox: Unmanaged<FSEventBox>?
    private var isCancelled = false

    init(root: URL, continuation: AsyncStream<FileSystemEvent>.Continuation) {
        self.root = root
        self.continuation = continuation
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, stream == nil else { return }
        let box = Unmanaged.passRetained(FSEventBox(continuation))
        retainedBox = box
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            storageSyncFSEventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else {
            retainedBox?.release()
            retainedBox = nil
            continuation.finish()
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            retainedBox?.release()
            retainedBox = nil
            continuation.finish()
        }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else { lock.unlock(); return }
        isCancelled = true
        let current = stream
        stream = nil
        let box = retainedBox
        retainedBox = nil
        lock.unlock()
        if let current {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
        }
        box?.release()
    }

    deinit { cancel() }
}

private let storageSyncFSEventCallback: FSEventStreamCallback = {
    _, context, count, _, flags, _ in
    guard let context else { return }
    let box = Unmanaged<FSEventBox>.fromOpaque(context).takeUnretainedValue()
    var result: FileSystemEvent = .changed
    for index in 0..<count {
        let value = flags[index]
        if value & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            result = .rootChanged
            break
        }
        if value & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || value & UInt32(kFSEventStreamEventFlagUserDropped) != 0
            || value & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 {
            result = .mustRescan
        }
    }
    box.continuation.yield(result)
}
