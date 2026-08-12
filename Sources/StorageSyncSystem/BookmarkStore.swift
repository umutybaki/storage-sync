import Foundation

public enum BookmarkStoreError: Error, LocalizedError {
    case notFound(String)
    case accessDenied(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let reference): "The saved folder permission \(reference) could not be found."
        case .accessDenied(let path): "StorageSync no longer has permission to access \(path)."
        }
    }
}

public final class ScopedURLAccess: @unchecked Sendable {
    public let url: URL
    private let didStartAccess: Bool

    public init(url: URL, didStartAccess: Bool) {
        self.url = url
        self.didStartAccess = didStartAccess
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public actor BookmarkStore {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func create(for url: URL, reference: String = UUID().uuidString) throws -> String {
        // An implicit-scope bookmark can be passed to a launch agent and resolved there.
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.volumeUUIDStringKey, .fileResourceIdentifierKey],
            relativeTo: nil
        )
        try data.write(to: fileURL(reference: reference), options: [.atomic, .completeFileProtection])
        return reference
    }

    public func resolve(reference: String) throws -> ScopedURLAccess {
        let bookmarkURL = fileURL(reference: reference)
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else {
            throw BookmarkStoreError.notFound(reference)
        }
        let data = try Data(contentsOf: bookmarkURL)
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let didStart = url.startAccessingSecurityScopedResource()
        // Built before the refresh below so its deinit owns the release even if
        // re-persisting throws.
        let access = ScopedURLAccess(url: url, didStartAccess: didStart)
        if stale {
            // A bookmark that resolved is usable whether or not it can be rewritten,
            // so a failed refresh only costs another stale resolution next time.
            _ = try? create(for: url, reference: reference)
        }
        return access
    }

    public func remove(reference: String) throws {
        let url = fileURL(reference: reference)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(reference: String) -> URL {
        directory.appendingPathComponent(reference, isDirectory: false).appendingPathExtension("bookmark")
    }
}
