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
        component == volumeMarker || component == partialsDirectory
    }
}
