import Foundation

public struct ReconciliationBaseline: Codable, Hashable, Sendable {
    public var relativePath: String
    public var localFingerprint: FileFingerprint
    public var remoteETag: String?
    public var remoteChecksum: String?
    public var remoteSize: Int64
    public var remoteLastModified: Date?

    public init(
        relativePath: String,
        localFingerprint: FileFingerprint,
        remoteETag: String?,
        remoteChecksum: String?,
        remoteSize: Int64,
        remoteLastModified: Date? = nil
    ) {
        self.relativePath = relativePath
        self.localFingerprint = localFingerprint
        self.remoteETag = remoteETag
        self.remoteChecksum = remoteChecksum
        self.remoteSize = remoteSize
        self.remoteLastModified = remoteLastModified
    }

    public func remoteMatches(_ object: RemoteObject) -> Bool {
        guard remoteSize == object.size else { return false }
        if let remoteChecksum, let checksum = object.checksum {
            return remoteChecksum == checksum
        }
        if let remoteETag = RemoteObject.comparableETag(remoteETag),
           let eTag = RemoteObject.comparableETag(object.eTag) {
            return remoteETag == eTag
        }
        if let remoteLastModified, let lastModified = object.lastModified {
            return remoteLastModified == lastModified
        }
        return false
    }
}

public struct TransferPlan: Hashable, Sendable {
    public var relativePath: String
    public var remoteKey: String
    public var kind: TransferKind
    public var totalBytes: Int64
    public var localFingerprint: FileFingerprint?
    public var remoteObject: RemoteObject?

    public init(
        relativePath: String,
        remoteKey: String,
        kind: TransferKind,
        totalBytes: Int64,
        localFingerprint: FileFingerprint?,
        remoteObject: RemoteObject?
    ) {
        self.relativePath = relativePath
        self.remoteKey = remoteKey
        self.kind = kind
        self.totalBytes = totalBytes
        self.localFingerprint = localFingerprint
        self.remoteObject = remoteObject
    }
}

/// What happened at the destination of a path StorageSync has copied before,
/// when its source has not changed since.
public enum DestinationDrift: Equatable, Sendable {
    /// Nothing, or the source changed too — ordinary planning decides.
    case unchanged
    /// The destination changed but kept its size: a timestamp that moved, an
    /// object re-encrypted or copied over itself. Take it as the current copy.
    case refreshed(ReconciliationBaseline)
    /// The destination now holds something else. Leave it and report it.
    case conflict
}

public struct ReconciliationResult: Sendable, Equatable {
    public var transfers: [TransferPlan]
    public var invalidRemoteKeys: [String]

    public init(transfers: [TransferPlan], invalidRemoteKeys: [String]) {
        self.transfers = transfers
        self.invalidRemoteKeys = invalidRemoteKeys
    }
}

public struct Reconciler: Sendable {
    public init() {}

    /// Reconciles whole manifests held in memory.
    ///
    /// Not the production path, and deliberately kept anyway. The engine
    /// reconciles through `SyncRepository.reconciliationRows` and
    /// `transferPlan`, which page against SQLite because the product contract
    /// covers libraries too large to hold at once; this version needs every
    /// file in an array and would defeat that. It stays because it is the
    /// executable specification of the pairing rules — prefix handling,
    /// reserved paths, unsafe keys, case folding — that the paged path has to
    /// reproduce, and the suite tests it directly. It is not moved into the
    /// test target because doing so would require publishing three private
    /// helpers, widening the module's surface to shrink it.
    public func reconcile(
        direction: SyncDirection,
        prefix: String,
        localFiles: [FileFingerprint],
        remoteObjects: [RemoteObject],
        baselines: [ReconciliationBaseline],
        localCaseSensitive: Bool = false
    ) -> ReconciliationResult {
        func canonical(_ path: String) -> String { Self.canonicalLocalPath(path, caseSensitive: localCaseSensitive) }
        let localByName = Dictionary(grouping: localFiles.filter {
            Self.isSafeRelativePath($0.relativePath) && !IgnoredName.isIgnoredPath($0.relativePath)
        }, by: { canonical($0.relativePath) })
        let baselineByPath = Dictionary(baselines.map { (Data($0.relativePath.utf8), $0) }, uniquingKeysWith: { _, last in last })
        var remoteByName: [String: [RemoteObject]] = [:]
        var invalidKeys: [String] = []
        // Repeated pages may list one exact S3 key twice. Distinct byte spellings
        // with the same local representation must remain distinct for collision detection.
        let objects = Dictionary(remoteObjects.map { (Data($0.key.utf8), $0) }, uniquingKeysWith: { _, last in last })
        for object in objects.values where !object.key.hasSuffix("/") {
            guard let path = Self.relativePath(for: object.key, prefix: prefix) else {
                if Self.belongsToPrefix(object.key, prefix: prefix) { invalidKeys.append(object.key) }
                continue
            }
            if Self.isReservedInternalPath(path) || IgnoredName.isIgnoredPath(path) { continue }
            guard Self.isSafeRelativePath(path), object.size >= 0 else { invalidKeys.append(object.key); continue }
            remoteByName[canonical(path), default: []].append(object)
        }
        var ambiguous = Set(remoteByName.filter { $0.value.count > 1 }.keys)
        ambiguous.formUnion(localByName.filter { $0.value.count > 1 }.keys)
        if direction == .download {
            for name in remoteByName.keys {
                var ancestor = ""
                for component in Self.pathComponents(name).dropLast() {
                    ancestor += ancestor.isEmpty ? component : "/" + component
                    if remoteByName[ancestor] != nil {
                        ambiguous.insert(ancestor)
                        ambiguous.insert(name)
                    }
                }
            }
        }
        for name in ambiguous { invalidKeys += remoteByName[name]?.map(\.key) ?? [] }
        let names = direction == .upload ? Array(localByName.keys) : Array(remoteByName.keys)
        var transfers: [TransferPlan] = []
        for name in names.sorted() where !ambiguous.contains(name) {
            let local = localByName[name]?.first
            let remote = remoteByName[name]?.first
            let path: String
            switch direction {
            case .upload:
                guard let local else { continue }
                path = local.relativePath
                let key = remote?.key ?? Self.remoteKey(relativePath: path, prefix: prefix)
                guard Self.isValidRemoteKey(key) else { invalidKeys.append(key); continue }
            case .download:
                guard let remote, let relative = Self.relativePath(for: remote.key, prefix: prefix) else { continue }
                path = relative
            }
            let baseline = baselineByPath[Data(path.utf8)]
            if baseline == nil, local != nil, remote != nil { continue }
            if let plan = transferPlan(direction: direction, prefix: prefix, relativePath: path,
                                       local: local, remote: remote, baseline: baseline, remoteKeyOverride: remote?.key) {
                transfers.append(plan)
            }
        }
        return ReconciliationResult(transfers: transfers.sorted { $0.relativePath < $1.relativePath }, invalidRemoteKeys: invalidKeys.sorted())
    }

    /// Reconciles one already validated manifest row. This is also used by the
    /// disk-backed coordinator so a very large sync never has to materialize a
    /// complete manifest in memory.
    public func transferPlan(
        direction: SyncDirection,
        prefix: String,
        relativePath: String,
        local: FileFingerprint?,
        remote: RemoteObject?,
        baseline: ReconciliationBaseline?,
        remoteKeyOverride: String? = nil
    ) -> TransferPlan? {
        switch direction {
        case .upload:
            guard let local else { return nil }
            let remoteKey = remoteKeyOverride ?? Self.remoteKey(relativePath: relativePath, prefix: prefix)
            guard Self.isValidRemoteKey(remoteKey),
                  !shouldSkipUpload(local: local, remote: remote, baseline: baseline) else {
                return nil
            }
            return TransferPlan(
                relativePath: relativePath,
                remoteKey: remoteKey,
                kind: .upload,
                totalBytes: local.size,
                localFingerprint: local,
                remoteObject: remote
            )
        case .download:
            guard let remote,
                  !shouldSkipDownload(local: local, remote: remote, baseline: baseline) else {
                return nil
            }
            return TransferPlan(
                relativePath: relativePath,
                remoteKey: remote.key,
                kind: .download,
                totalBytes: remote.size,
                localFingerprint: local,
                remoteObject: remote
            )
        }
    }

    /// A folder and bucket may already be partially copied before StorageSync is
    /// installed. On the first pairing of a relative path, preserve the
    /// existing destination and record both observed versions as the baseline.
    /// Later source changes are still detected against this baseline.
    ///
    /// Only a destination of the same size is adopted. Adoption means "this is
    /// already a copy of the source", and a different size proves it is not:
    /// another camera's `IMG_0001.JPG`, an object a different tool left
    /// truncated, or a file edited while its folder was outside the sync. Taking
    /// any of those as the copy reported the source as backed up when it never
    /// was. See `isConflictingExistingDestination` for what happens instead.
    public func initialAdoptionBaseline(
        relativePath: String,
        local: FileFingerprint?,
        remote: RemoteObject?,
        existingBaseline: ReconciliationBaseline?
    ) -> ReconciliationBaseline? {
        guard existingBaseline == nil, let local, let remote, local.size == remote.size else { return nil }
        return ReconciliationBaseline(
            relativePath: relativePath,
            localFingerprint: local,
            remoteETag: remote.eTag,
            remoteChecksum: remote.checksum,
            remoteSize: remote.size,
            remoteLastModified: remote.lastModified
        )
    }

    /// A first pairing whose two sides are visibly different files.
    ///
    /// Neither answer that moves bytes is safe here. Copying would overwrite a
    /// destination StorageSync has never seen a copy of — on a bucket without
    /// versioning, or a Mac without a backup, that file is then gone — and
    /// adopting would claim a copy that does not exist. The path is left alone
    /// on both sides and reported, and it is reconsidered every scan, so it
    /// resolves itself the moment either side is renamed, removed, or replaced.
    public func isConflictingExistingDestination(
        local: FileFingerprint?,
        remote: RemoteObject?,
        baseline: ReconciliationBaseline?
    ) -> Bool {
        guard baseline == nil, let local, let remote else { return false }
        return local.size != remote.size
    }

    /// The destination changed since StorageSync last copied to it, and the
    /// source did not.
    ///
    /// Copying in that case used to happen as a matter of course, because the
    /// pair no longer matched its baseline. It overwrote whatever had changed
    /// at the destination — someone's edit to a restored photo, or another
    /// writer's object in a bucket without versioning — though nothing on the
    /// source side had asked for a copy. Only a source change does that now.
    public func destinationDrift(
        direction: SyncDirection,
        local: FileFingerprint?,
        remote: RemoteObject?,
        baseline: ReconciliationBaseline?
    ) -> DestinationDrift {
        guard let baseline, let local, let remote else { return .unchanged }
        switch direction {
        case .upload:
            guard local.representsSameContent(as: baseline.localFingerprint),
                  !baseline.remoteMatches(remote) else { return .unchanged }
            guard remote.size == baseline.remoteSize else { return .conflict }
            var refreshed = baseline
            refreshed.localFingerprint = local
            refreshed.remoteETag = remote.eTag
            refreshed.remoteChecksum = remote.checksum
            refreshed.remoteSize = remote.size
            refreshed.remoteLastModified = remote.lastModified
            return .refreshed(refreshed)
        case .download:
            guard baseline.remoteMatches(remote),
                  !local.representsSameContent(as: baseline.localFingerprint) else { return .unchanged }
            guard local.size == baseline.localFingerprint.size else { return .conflict }
            var refreshed = baseline
            refreshed.localFingerprint = local
            return .refreshed(refreshed)
        }
    }

    /// POSIX treats byte 0x2f as a separator even when Unicode would combine
    /// the slash with the first character of the next filename.
    public static func pathComponents(_ path: String) -> [String] {
        path.utf8.split(separator: 0x2f, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components = pathComponents(path)
        return components.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !ReservedName.isReserved($0)
                && $0.utf8.count <= 255
        }
    }

    public static func isReservedInternalPath(_ path: String) -> Bool {
        pathComponents(path)
            .contains(where: ReservedName.isReserved)
    }

    public static func remoteKey(relativePath: String, prefix: String) -> String {
        let normalized = SyncJob.normalizedPrefix(prefix)
        return normalized.isEmpty ? relativePath : normalized + "/" + relativePath
    }

    public static func isValidRemoteKey(_ key: String) -> Bool {
        key.utf8.count <= 1_024 && !key.utf8.contains(0)
    }

    public static func relativePath(for key: String, prefix: String) -> String? {
        let normalized = SyncJob.normalizedPrefix(prefix)
        guard !normalized.isEmpty else { return key }
        let expected = normalized + "/"
        guard key.utf8.starts(with: expected.utf8) else { return nil }
        return String(decoding: key.utf8.dropFirst(expected.utf8.count), as: UTF8.self)
    }

    private static func belongsToPrefix(_ key: String, prefix: String) -> Bool {
        let normalized = SyncJob.normalizedPrefix(prefix)
        return normalized.isEmpty || key == normalized || key.hasPrefix(normalized + "/")
    }

    /// The key two paths share when the destination volume cannot tell them
    /// apart. It must model what APFS and HFS+ actually do and nothing more.
    ///
    /// Those filesystems normalize Unicode and ignore case; they do **not**
    /// ignore diacritics or character width. Folding those as well used to
    /// merge genuinely distinct files: `Gökçe.jpg` and `Gokce.jpg` coexist
    /// happily on macOS but collapsed to one canonical path, which both hid
    /// one of them behind a spurious collision report and let a local file
    /// pair with — and overwrite — an unrelated object under the other name.
    ///
    /// `en_US_POSIX` keeps the fold locale-independent, so a Turkish system
    /// locale cannot change how `I` and `i` compare.
    public static func canonicalLocalPath(_ path: String, caseSensitive: Bool = false) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return normalized }
        return normalized.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func shouldSkipUpload(
        local: FileFingerprint,
        remote: RemoteObject?,
        baseline: ReconciliationBaseline?
    ) -> Bool {
        guard let remote else { return false }
        // An unchanged source is never sent again over an existing object.
        // Whether that object itself changed is `destinationDrift`'s question.
        if let baseline, local.representsSameContent(as: baseline.localFingerprint) {
            return true
        }
        guard baseline == nil, remote.size == local.size else { return false }
        let recordedSize = remote.metadata["storagesync-source-size"].flatMap(Int64.init)
        let recordedTime = remote.metadata["storagesync-source-mtime-ns"].flatMap(Int64.init)
        return recordedSize == local.size && recordedTime == local.modificationTimeNanoseconds
    }

    private func shouldSkipDownload(
        local: FileFingerprint?,
        remote: RemoteObject,
        baseline: ReconciliationBaseline?
    ) -> Bool {
        guard let local else { return false }
        // An unchanged object is never fetched again over an existing file.
        if let baseline, baseline.remoteMatches(remote) {
            return true
        }
        if let remoteChecksum = remote.checksum, let localChecksum = local.checksum {
            return remote.size == local.size && remoteChecksum == localChecksum
        }
        return false
    }
}
