import Foundation

public struct RuntimeLocations: Sendable {
    public var root: URL
    public var database: URL
    public var bookmarks: URL

    public init(root: URL) {
        self.root = root
        database = root.appendingPathComponent("PhotoSync.sqlite", isDirectory: false)
        bookmarks = root.appendingPathComponent("Bookmarks", isDirectory: true)
    }

    public static func standard() throws -> RuntimeLocations {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return RuntimeLocations(root: base.appendingPathComponent("PhotoSync", isDirectory: true))
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bookmarks, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bookmarks.path)
    }
}
