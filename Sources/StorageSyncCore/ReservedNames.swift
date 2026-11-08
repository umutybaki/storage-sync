import Foundation

/// Path components StorageSync owns. They are excluded from every scan and from
/// reconciliation at any depth, so a sync targeting a nested folder cannot leak
/// StorageSync's own bookkeeping into a sync that targets a parent folder.
///
/// These live here, in the one module every other module depends on, because
/// the scanner, the reconciler, the executor, and the coordinator all have to
/// agree on them exactly. Three separate copies of the same string literal is
/// three chances for one of them to drift.
public enum ReservedName {
    /// Per-volume identity marker written at the root of a paired removable
    /// volume, used as a second factor alongside the filesystem UUID.
    public static let volumeMarker = ".storagesync-volume-id"

    /// Directory holding in-progress ranged downloads. A partial never appears
    /// under its final name, so it waits here until the whole object verifies.
    public static let partialsDirectory = ".storagesync-partials"

    public static func isReserved(_ component: some StringProtocol) -> Bool {
        let folded = Reconciler.canonicalLocalPath(String(component))
        return folded == volumeMarker || folded == partialsDirectory
    }
}

/// Names operating systems leave beside user files for their own use: Finder's
/// per-folder view state, AppleDouble sidecars on non-Apple filesystems,
/// Windows thumbnail caches, and volume-level indexes and trash. None is part
/// of a photo library, and several change on their own — `.DS_Store` whenever
/// a Finder window is resized — so copying them filled the bucket with junk
/// that was then copied again and again. They are skipped on both sides, at
/// any depth, the same way StorageSync's own names are.
public enum IgnoredName {
    private static let exact: Set<String> = [
        ".DS_Store",
        "Icon\r",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100"
    ]

    /// Windows names, which Windows itself treats case-insensitively.
    private static let caseInsensitive: Set<String> = [
        "thumbs.db",
        "ehthumbs.db",
        "ehthumbs_vista.db",
        "desktop.ini",
        "$recycle.bin",
        "system volume information"
    ]

    public static func isIgnored(_ component: some StringProtocol) -> Bool {
        let name = String(component)
        if exact.contains(name) { return true }
        // AppleDouble: macOS writes `._name` to hold the metadata of `name`
        // on filesystems that cannot store it, such as exFAT.
        if name.hasPrefix("._") { return true }
        return caseInsensitive.contains(name.lowercased())
    }

    public static func isIgnoredPath(_ path: String) -> Bool {
        Reconciler.pathComponents(path).contains(where: isIgnored)
    }
}
