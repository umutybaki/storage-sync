import Foundation

public enum SafePathError: Error, LocalizedError {
    case invalidRelativePath(String)
    case escapesRoot(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path): "The object path “\(path)” cannot be represented safely on macOS."
        case .escapesRoot(let path): "The object path “\(path)” points outside the selected folder."
        }
    }
}

public enum SafePath {
    public static func resolve(_ relativePath: String, beneath root: URL) throws -> URL {
        guard Reconciler.isSafeRelativePath(relativePath) else {
            throw SafePathError.invalidRelativePath(relativePath)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path
        let destination = Reconciler.pathComponents(relativePath).reduce(resolvedRoot) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        let destinationPath = destination.path
        let descendantPrefix = rootPath == "/" ? "/" : rootPath + "/"
        guard destinationPath.hasPrefix(descendantPrefix) else {
            throw SafePathError.escapesRoot(relativePath)
        }
        guard destinationPath.utf8.count < 1_024 else {
            throw SafePathError.invalidRelativePath(relativePath)
        }

        var cursor = resolvedRoot
        for component in Reconciler.pathComponents(relativePath) {
            cursor.appendPathComponent(String(component), isDirectory: false)
            var uncached = cursor
            uncached.removeAllCachedResourceValues()
            if let values = try? uncached.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                throw SafePathError.escapesRoot(relativePath)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory) else {
                continue
            }
            guard cursor.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(descendantPrefix) else {
                throw SafePathError.escapesRoot(relativePath)
            }
        }
        return destination
    }
}
