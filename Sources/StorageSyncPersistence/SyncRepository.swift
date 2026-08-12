import Foundation
import StorageSyncCore

public struct RemoteManifestRecord: Sendable {
    public var relativePath: String
    public var canonicalPath: String
    public var object: RemoteObject

    public init(relativePath: String, canonicalPath: String, object: RemoteObject) {
        self.relativePath = relativePath
        self.canonicalPath = canonicalPath
        self.object = object
    }
}

public struct ManifestReconciliationRow: Sendable {
    public var relativePath: String
    public var local: FileFingerprint?
    public var remote: RemoteObject?
    public var baseline: ReconciliationBaseline?
    public var hasRemotePathCollision: Bool
}

public struct TransferQueueSummary: Sendable, Equatable {
    public var count: Int
    public var totalBytes: Int64
    public var completedBytes: Int64

    public init(count: Int, totalBytes: Int64, completedBytes: Int64) {
        self.count = count
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
    }
}

public actor SyncRepository {
    private let database: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let needsTransferMetricsBackfill = try Self.migrate(database: database)
        if needsTransferMetricsBackfill {
            try Self.backfillTransferMetrics(database: database, decoder: decoder)
        }
        try database.execute("PRAGMA user_version=2")
        try Self.recoverInterruptedTransfers(database: database, encoder: encoder, decoder: decoder)
    }

    public func saveConnection(_ connection: S3Connection) throws {
        try upsert(
            table: "connections",
            id: connection.id.description,
            payload: encoder.encode(connection)
        )
    }

    public func connections() throws -> [S3Connection] {
        try loadAll(table: "connections", as: S3Connection.self)
    }

    public func connection(id: ConnectionID) throws -> S3Connection? {
        try load(table: "connections", id: id.description, as: S3Connection.self)
    }

    /// Saved provider keys, described without their secrets. The secret itself
    /// is in the Keychain under the credential's reference; nothing in this
    /// table grants access to anything.
    public func saveCredential(_ credential: StoredCredential) throws {
        try upsert(
            table: "credentials",
            id: credential.id.description,
            payload: encoder.encode(credential)
        )
    }

    public func credentials() throws -> [StoredCredential] {
        try loadAll(table: "credentials", as: StoredCredential.self)
    }

    public func credential(id: CredentialID) throws -> StoredCredential? {
        try load(table: "credentials", id: id.description, as: StoredCredential.self)
    }

    public func removeCredential(id: CredentialID) throws {
        try database.execute(
            "DELETE FROM credentials WHERE id = ?",
            bindings: [.text(id.description)]
        )
    }

    public func saveJob(_ job: SyncJob) throws {
        try upsert(table: "jobs", id: job.id.description, payload: encoder.encode(job))
    }

    public func jobs() throws -> [SyncJob] {
        try loadAll(table: "jobs", as: SyncJob.self)
    }

    public func job(id: SyncJobID) throws -> SyncJob? {
        try load(table: "jobs", id: id.description, as: SyncJob.self)
    }

    /// Removes only StorageSync's durable state for a job. Source files and S3
    /// objects are deliberately outside this transaction and are never deleted.
    public func removeJobState(id: SyncJobID) throws {
        let identifier = id.description
        try database.transaction {
            try database.execute(
                """
                DELETE FROM transfer_parts
                WHERE transfer_id IN (SELECT id FROM transfers WHERE job_id = ?)
                """,
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM transfers WHERE job_id = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM manifest WHERE job_id = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM manifest_conflicts WHERE job_id = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM baselines WHERE job_id = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM snapshots WHERE id = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM jobs WHERE id = ?",
                bindings: [.text(identifier)]
            )
        }
    }

    public func removeConnection(id: ConnectionID) throws {
        try database.execute(
            "DELETE FROM connections WHERE id = ?",
            bindings: [.text(id.description)]
        )
    }

    public func saveTransfer(_ transfer: TransferRecord) throws {
        let payload = try encoder.encode(transfer)
        try database.execute(
            """
            INSERT INTO transfers(
              id, job_id, relative_path, status, next_attempt_at, updated_at,
              total_bytes, completed_bytes, payload
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              job_id = excluded.job_id,
              relative_path = excluded.relative_path,
              status = excluded.status,
              next_attempt_at = excluded.next_attempt_at,
              updated_at = excluded.updated_at,
              total_bytes = excluded.total_bytes,
              completed_bytes = excluded.completed_bytes,
              payload = excluded.payload
            """,
            bindings: [
                .text(transfer.id.description),
                .text(transfer.jobID.description),
                .text(transfer.relativePath),
                .text(transfer.status.rawValue),
                transfer.nextAttemptAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(transfer.updatedAt.timeIntervalSince1970),
                .integer(transfer.totalBytes),
                .integer(transfer.completedBytes),
                .blob(payload)
            ]
        )
    }

    public func transfer(id: TransferID) throws -> TransferRecord? {
        try loadTransfer(where: "id = ?", bindings: [.text(id.description)]).first
    }

    public func runnableTransfers(
        jobID: SyncJobID,
        now: Date = Date(),
        limit: Int? = nil
    ) throws -> [TransferRecord] {
        try loadTransfer(
            where: "job_id = ? AND status IN ('queued', 'waiting') AND (next_attempt_at IS NULL OR next_attempt_at <= ?)",
            bindings: [.text(jobID.description), .real(now.timeIntervalSince1970)],
            order: "updated_at ASC",
            limit: limit
        )
    }

    public func runnableTransferSummary(jobID: SyncJobID, now: Date = Date()) throws -> TransferQueueSummary {
        var result = TransferQueueSummary(count: 0, totalBytes: 0, completedBytes: 0)
        try database.query(
            """
            SELECT COUNT(*), COALESCE(SUM(total_bytes), 0), COALESCE(SUM(completed_bytes), 0)
            FROM transfers
            WHERE job_id = ?
              AND status IN ('queued', 'waiting')
              AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
            """,
            bindings: [.text(jobID.description), .real(now.timeIntervalSince1970)]
        ) { statement in
            result = TransferQueueSummary(
                count: Int(database.integer(statement, column: 0)),
                totalBytes: database.integer(statement, column: 1),
                completedBytes: database.integer(statement, column: 2)
            )
        }
        return result
    }

    /// Includes delayed retry records as well as work that is runnable now.
    /// UI inventory must never call a backoff-delayed queue "caught up."
    public func activeTransferSummary(jobID: SyncJobID) throws -> TransferQueueSummary {
        var result = TransferQueueSummary(count: 0, totalBytes: 0, completedBytes: 0)
        try database.query(
            """
            SELECT COUNT(*), COALESCE(SUM(total_bytes), 0), COALESCE(SUM(completed_bytes), 0)
            FROM transfers
            WHERE job_id = ?
              AND status IN ('queued', 'waiting', 'running', 'verifying')
            """,
            bindings: [.text(jobID.description)]
        ) { statement in
            result = TransferQueueSummary(
                count: Int(database.integer(statement, column: 0)),
                totalBytes: database.integer(statement, column: 1),
                completedBytes: database.integer(statement, column: 2)
            )
        }
        return result
    }

    public func nextWaitingAttempt(jobID: SyncJobID) throws -> Date? {
        var interval: Double?
        try database.query(
            """
            SELECT MIN(next_attempt_at) FROM transfers
            WHERE job_id = ? AND status = 'waiting' AND next_attempt_at IS NOT NULL
            """,
            bindings: [.text(jobID.description)]
        ) { statement in
            guard !database.isNull(statement, column: 0) else { return }
            // SQLite's REAL accessor is kept local to this query to avoid
            // decoding every transfer payload just to schedule a retry.
            interval = database.real(statement, column: 0)
        }
        return interval.map(Date.init(timeIntervalSince1970:))
    }

    public func activeTransfers(jobID: SyncJobID) throws -> [TransferRecord] {
        try loadTransfer(
            where: "job_id = ? AND status IN ('queued', 'running', 'waiting', 'verifying')",
            bindings: [.text(jobID.description)],
            order: "updated_at ASC"
        )
    }

    public func removeTerminalTransfers(jobID: SyncJobID, relativePath: String) throws {
        var identifiers: [String] = []
        try database.query(
            "SELECT id FROM transfers WHERE job_id = ? AND relative_path = ? AND status IN ('completed', 'superseded', 'failed')",
            bindings: [.text(jobID.description), .text(relativePath)]
        ) { statement in
            if let identifier = database.text(statement, column: 0) { identifiers.append(identifier) }
        }
        try database.transaction {
            for identifier in identifiers {
                try database.execute(
                    "DELETE FROM transfer_parts WHERE transfer_id = ?",
                    bindings: [.text(identifier)]
                )
                try database.execute(
                    "DELETE FROM transfers WHERE id = ?",
                    bindings: [.text(identifier)]
                )
            }
        }
    }

    /// Atomically avoids duplicate work for a path, replaces stale terminal
    /// history, and enqueues the new plan without loading the whole active queue.
    @discardableResult
    public func enqueueTransferIfNeeded(_ plan: TransferPlan, jobID: SyncJobID) throws -> Bool {
        var didEnqueue = false
        try database.transaction {
            didEnqueue = try enqueueTransferInsideTransaction(plan, jobID: jobID)
        }
        return didEnqueue
    }

    /// Enqueues a reconciliation page under one durable transaction. With
    /// synchronous SQLite durability this avoids one filesystem sync per file.
    @discardableResult
    public func enqueueTransfersIfNeeded(_ plans: [TransferPlan], jobID: SyncJobID) throws -> Int {
        guard !plans.isEmpty else { return 0 }
        var count = 0
        try database.transaction {
            for plan in plans {
                if try enqueueTransferInsideTransaction(plan, jobID: jobID) {
                    count += 1
                }
            }
        }
        return count
    }

    public func makeWaitingTransfersRunnable(jobID: SyncJobID) throws {
        // A reconnect can wake millions of waiting paths. Decode and update a
        // bounded page at a time instead of materializing the whole queue.
        while true {
            let waiting = try loadTransfer(
                where: "job_id = ? AND status = 'waiting' AND next_attempt_at IS NOT NULL",
                bindings: [.text(jobID.description)],
                limit: 512
            )
            guard !waiting.isEmpty else { return }
            let now = Date()
            try database.transaction {
                for var transfer in waiting {
                    transfer.nextAttemptAt = nil
                    transfer.updatedAt = now
                    try saveTransfer(transfer)
                }
            }
        }
    }

    public func savePart(_ part: TransferPart) throws {
        try database.execute(
            """
            INSERT INTO transfer_parts(transfer_id, part_number, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(transfer_id, part_number) DO UPDATE SET payload = excluded.payload
            """,
            bindings: [
                .text(part.transferID.description),
                .integer(Int64(part.number)),
                .blob(try encoder.encode(part))
            ]
        )
    }

    public func parts(transferID: TransferID) throws -> [TransferPart] {
        var result: [TransferPart] = []
        try database.query(
            "SELECT payload FROM transfer_parts WHERE transfer_id = ? ORDER BY part_number ASC",
            bindings: [.text(transferID.description)]
        ) { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            result.append(try decoder.decode(TransferPart.self, from: payload))
        }
        return result
    }

    public func removeParts(transferID: TransferID, fromPartNumber: Int) throws {
        try database.execute(
            "DELETE FROM transfer_parts WHERE transfer_id = ? AND part_number >= ?",
            bindings: [.text(transferID.description), .integer(Int64(fromPartNumber))]
        )
    }

    public func removePart(transferID: TransferID, number: Int) throws {
        try database.execute(
            "DELETE FROM transfer_parts WHERE transfer_id = ? AND part_number = ?",
            bindings: [.text(transferID.description), .integer(Int64(number))]
        )
    }

    public func saveBaseline(_ baseline: ReconciliationBaseline, jobID: SyncJobID) throws {
        try saveBaselineInsideTransaction(baseline, jobID: jobID)
    }

    public func finalizeSuccessfulTransfer(
        transferID: TransferID,
        baseline: ReconciliationBaseline,
        jobID: SyncJobID
    ) throws {
        try database.transaction {
            try saveBaselineInsideTransaction(baseline, jobID: jobID)
            try database.execute(
                "DELETE FROM transfer_parts WHERE transfer_id = ?",
                bindings: [.text(transferID.description)]
            )
            try database.execute(
                "DELETE FROM transfers WHERE id = ?",
                bindings: [.text(transferID.description)]
            )
        }
    }

    /// Records pre-existing source/destination pairs and removes obsolete work
    /// that an older reconciliation may have queued for those paths.
    public func adoptExistingDestinations(
        _ baselines: [ReconciliationBaseline],
        jobID: SyncJobID
    ) throws {
        guard !baselines.isEmpty else { return }
        try database.transaction {
            try deleteTransfersInsideTransaction(
                jobID: jobID,
                relativePaths: baselines.map(\.relativePath)
            )
            for baseline in baselines {
                try saveBaselineInsideTransaction(baseline, jobID: jobID)
            }
        }
    }

    /// Chunked so the bound parameter count stays well inside SQLite's default
    /// limit however large a caller's reconciliation page grows.
    public func transfers(jobID: SyncJobID, relativePaths: [String]) throws -> [TransferRecord] {
        guard !relativePaths.isEmpty else { return [] }
        var results: [TransferRecord] = []
        for chunk in Self.chunks(of: relativePaths, size: 256) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            results += try loadTransfer(
                where: "job_id = ? AND relative_path IN (\(placeholders))",
                bindings: [.text(jobID.description)] + chunk.map(SQLiteValue.text)
            )
        }
        return results
    }

    public func discardTransfers(jobID: SyncJobID, relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try database.transaction {
            try deleteTransfersInsideTransaction(jobID: jobID, relativePaths: relativePaths)
        }
    }

    /// Removes the queue rows and part checkpoints for a set of paths.
    ///
    /// A statement pair per path is what this used to do, which meant a
    /// reconciliation page of already-present files issued two SQLite
    /// statements per file every cycle — mostly against paths with nothing
    /// queued at all. Deleting a whole chunk per statement keeps a
    /// multi-terabyte sync's steady state proportional to the work there is,
    /// not to the size of the library. The chunk bound keeps the bound
    /// parameter count well inside SQLite's default limit.
    private func deleteTransfersInsideTransaction(
        jobID: SyncJobID,
        relativePaths: [String]
    ) throws {
        for chunk in Self.chunks(of: relativePaths, size: 256) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let bindings: [SQLiteValue] = [.text(jobID.description)] + chunk.map(SQLiteValue.text)
            try database.execute(
                """
                DELETE FROM transfer_parts
                WHERE transfer_id IN (
                  SELECT id FROM transfers
                  WHERE job_id = ? AND relative_path IN (\(placeholders))
                )
                """,
                bindings: bindings
            )
            try database.execute(
                "DELETE FROM transfers WHERE job_id = ? AND relative_path IN (\(placeholders))",
                bindings: bindings
            )
        }
    }

    private static func chunks(of values: [String], size: Int) -> [ArraySlice<String>] {
        precondition(size > 0)
        return stride(from: 0, to: values.count, by: size).map {
            values[$0..<min($0 + size, values.count)]
        }
    }

    private func saveBaselineInsideTransaction(
        _ baseline: ReconciliationBaseline,
        jobID: SyncJobID
    ) throws {
        try database.execute(
            """
            INSERT INTO baselines(job_id, relative_path, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(job_id, relative_path) DO UPDATE SET payload = excluded.payload
            """,
            bindings: [
                .text(jobID.description),
                .text(baseline.relativePath),
                .blob(try encoder.encode(baseline))
            ]
        )
    }

    public func baselines(jobID: SyncJobID) throws -> [ReconciliationBaseline] {
        var values: [ReconciliationBaseline] = []
        try database.query(
            "SELECT payload FROM baselines WHERE job_id = ? ORDER BY relative_path ASC",
            bindings: [.text(jobID.description)]
        ) { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            values.append(try decoder.decode(ReconciliationBaseline.self, from: payload))
        }
        return values
    }

    public func nextManifestGeneration(jobID: SyncJobID, side: ManifestSide) throws -> Int64 {
        var maximum: Int64 = 0
        try database.query(
            "SELECT COALESCE(MAX(scan_generation), 0) FROM manifest WHERE job_id = ? AND side = ?",
            bindings: [.text(jobID.description), .text(side.rawValue)]
        ) { statement in
            maximum = database.integer(statement, column: 0)
        }
        guard maximum < Int64.max else { return 1 }
        return maximum + 1
    }

    public func upsertLocalManifestEntries(
        _ files: [FileFingerprint],
        jobID: SyncJobID,
        generation: Int64,
        caseSensitive: Bool
    ) throws {
        try database.transaction {
            for file in files {
                let canonical = caseSensitive
                    ? file.relativePath
                    : Reconciler.canonicalLocalPath(file.relativePath)
                try database.execute(
                    """
                    INSERT INTO manifest(job_id, side, relative_path, canonical_path, scan_generation, payload)
                    VALUES (?, 'local', ?, ?, ?, ?)
                    ON CONFLICT(job_id, side, relative_path) DO UPDATE SET
                      canonical_path = excluded.canonical_path,
                      scan_generation = excluded.scan_generation,
                      payload = excluded.payload
                    """,
                    bindings: [
                        .text(jobID.description),
                        .text(file.relativePath),
                        .text(canonical),
                        .integer(generation),
                        .blob(try encoder.encode(file))
                    ]
                )
            }
        }
    }

    public func upsertRemoteManifestEntries(
        _ records: [RemoteManifestRecord],
        jobID: SyncJobID,
        generation: Int64
    ) throws {
        try database.transaction {
            for record in records {
                try database.execute(
                    """
                    INSERT INTO manifest(job_id, side, relative_path, canonical_path, scan_generation, payload)
                    VALUES (?, 'remote', ?, ?, ?, ?)
                    ON CONFLICT(job_id, side, relative_path) DO UPDATE SET
                      canonical_path = excluded.canonical_path,
                      scan_generation = excluded.scan_generation,
                      payload = excluded.payload
                    """,
                    bindings: [
                        .text(jobID.description),
                        .text(record.relativePath),
                        .text(record.canonicalPath),
                        .integer(generation),
                        .blob(try encoder.encode(record.object))
                    ]
                )
            }
        }
    }

    public func finishManifestScan(jobID: SyncJobID, side: ManifestSide, generation: Int64) throws {
        try database.execute(
            "DELETE FROM manifest WHERE job_id = ? AND side = ? AND scan_generation != ?",
            bindings: [.text(jobID.description), .text(side.rawValue), .integer(generation)]
        )
        if side == .remote {
            try database.execute(
                "DELETE FROM manifest_conflicts WHERE job_id = ? AND scan_generation != ?",
                bindings: [.text(jobID.description), .integer(generation)]
            )
        }
    }

    public func pruneBaselinesAbsentFromManifest(
        jobID: SyncJobID,
        side: ManifestSide,
        generation: Int64
    ) throws {
        try database.execute(
            """
            DELETE FROM baselines
            WHERE job_id = ?
              AND NOT EXISTS (
                SELECT 1 FROM manifest
                WHERE manifest.job_id = baselines.job_id
                  AND manifest.side = ?
                  AND manifest.scan_generation = ?
                  AND manifest.relative_path = baselines.relative_path
              )
            """,
            bindings: [
                .text(jobID.description),
                .text(side.rawValue),
                .integer(generation)
            ]
        )
    }

    /// Removes every object in a case-folded collision group, returning the
    /// number skipped. Skipping the whole group avoids choosing an arbitrary
    /// winner on case-insensitive destination volumes.
    public func removeCaseCollidingRemoteManifestEntries(
        jobID: SyncJobID,
        generation: Int64
    ) throws -> Int {
        let bindings: [SQLiteValue] = [.text(jobID.description), .integer(generation)]
        var count = 0
        try database.transaction {
            try database.execute(
                "DELETE FROM manifest_conflicts WHERE job_id = ? AND scan_generation = ?",
                bindings: bindings
            )
            try database.query(
                """
                SELECT COALESCE(SUM(entry_count), 0)
                FROM (
                  SELECT COUNT(*) AS entry_count
                  FROM manifest
                  WHERE job_id = ? AND side = 'remote' AND scan_generation = ?
                  GROUP BY canonical_path
                  HAVING COUNT(*) > 1
                )
                """,
                bindings: bindings
            ) { statement in
                count = Int(database.integer(statement, column: 0))
            }
            guard count > 0 else { return }
            try database.execute(
                """
                INSERT INTO manifest_conflicts(job_id, scan_generation, canonical_path)
                SELECT ?, ?, canonical_path
                FROM manifest
                WHERE job_id = ? AND side = 'remote' AND scan_generation = ?
                GROUP BY canonical_path
                HAVING COUNT(*) > 1
                """,
                bindings: bindings + bindings
            )
            try database.execute(
                """
                DELETE FROM manifest
                WHERE job_id = ? AND side = 'remote' AND scan_generation = ?
                  AND canonical_path IN (
                    SELECT canonical_path FROM manifest_conflicts
                    WHERE job_id = ? AND scan_generation = ?
                  )
                """,
                bindings: bindings + bindings
            )
        }
        return count
    }

    public func reconciliationRows(
        jobID: SyncJobID,
        direction: SyncDirection,
        localGeneration: Int64,
        remoteGeneration: Int64,
        localCaseSensitive: Bool,
        after relativePath: String?,
        limit: Int
    ) throws -> [ManifestReconciliationRow] {
        precondition(limit > 0)
        let primarySide = direction == .upload ? "local" : "remote"
        let primaryGeneration = direction == .upload ? localGeneration : remoteGeneration
        let secondarySide = direction == .upload ? "remote" : "local"
        let secondaryGeneration = direction == .upload ? remoteGeneration : localGeneration
        let joinPath: String
        if !localCaseSensitive {
            joinPath = "secondary.canonical_path = source.canonical_path"
        } else {
            joinPath = "secondary.relative_path = source.relative_path"
        }
        let cursorClause = relativePath == nil ? "" : "AND source.relative_path > ?"
        var bindings: [SQLiteValue] = [
            .text(secondarySide),
            .integer(secondaryGeneration),
            .integer(remoteGeneration),
            .text(jobID.description),
            .text(primarySide),
            .integer(primaryGeneration)
        ]
        if let relativePath { bindings.append(.text(relativePath)) }
        bindings.append(.integer(Int64(limit)))

        var rows: [ManifestReconciliationRow] = []
        try database.query(
            """
            SELECT source.relative_path, source.payload, secondary.payload, baseline.payload,
                   conflict.canonical_path IS NOT NULL
            FROM manifest AS source
            LEFT JOIN manifest AS secondary
              ON secondary.job_id = source.job_id
             AND secondary.side = ?
             AND secondary.scan_generation = ?
             AND \(joinPath)
            LEFT JOIN manifest_conflicts AS conflict
              ON conflict.job_id = source.job_id
             AND conflict.scan_generation = ?
             AND conflict.canonical_path = source.canonical_path
            LEFT JOIN baselines AS baseline
              ON baseline.job_id = source.job_id
             AND baseline.relative_path = source.relative_path
            WHERE source.job_id = ?
              AND source.side = ?
              AND source.scan_generation = ?
              \(cursorClause)
            ORDER BY source.relative_path ASC
            LIMIT ?
            """,
            bindings: bindings
        ) { statement in
            guard let path = database.text(statement, column: 0),
                  let primaryPayload = database.blob(statement, column: 1) else { return }
            let secondaryPayload = database.isNull(statement, column: 2)
                ? nil
                : database.blob(statement, column: 2)
            let baselinePayload = database.isNull(statement, column: 3)
                ? nil
                : database.blob(statement, column: 3)
            let local: FileFingerprint?
            let remote: RemoteObject?
            if direction == .upload {
                local = try decoder.decode(FileFingerprint.self, from: primaryPayload)
                remote = try secondaryPayload.map { try decoder.decode(RemoteObject.self, from: $0) }
            } else {
                remote = try decoder.decode(RemoteObject.self, from: primaryPayload)
                local = try secondaryPayload.map { try decoder.decode(FileFingerprint.self, from: $0) }
            }
            rows.append(
                ManifestReconciliationRow(
                    relativePath: path,
                    local: local,
                    remote: remote,
                    baseline: try baselinePayload.map { try decoder.decode(ReconciliationBaseline.self, from: $0) },
                    hasRemotePathCollision: database.integer(statement, column: 4) != 0
                )
            )
        }
        return rows
    }

    public func setSnapshot(_ snapshot: SyncSnapshot) throws {
        try upsert(
            table: "snapshots",
            id: snapshot.jobID.description,
            payload: encoder.encode(snapshot)
        )
    }

    public func snapshots() throws -> [SyncSnapshot] {
        try loadAll(table: "snapshots", as: SyncSnapshot.self)
    }

    public func snapshot(jobID: SyncJobID) throws -> SyncSnapshot? {
        try load(table: "snapshots", id: jobID.description, as: SyncSnapshot.self)
    }

    public func updateSnapshotProgress(
        jobID: SyncJobID,
        bytesCompleted: Int64,
        currentRelativePath: String
    ) throws {
        guard var value = try snapshot(jobID: jobID) else { return }
        value.bytesCompleted = min(value.bytesTotal, max(0, bytesCompleted))
        value.currentRelativePath = currentRelativePath
        try setSnapshot(value)
    }

    private static func migrate(database: SQLiteDatabase) throws -> Bool {
        var previousVersion: Int64 = 0
        try database.query("PRAGMA user_version") { statement in
            previousVersion = database.integer(statement, column: 0)
        }
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS connections(
              id TEXT PRIMARY KEY,
              payload BLOB NOT NULL
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS credentials(
              id TEXT PRIMARY KEY,
              payload BLOB NOT NULL
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS jobs(
              id TEXT PRIMARY KEY,
              payload BLOB NOT NULL
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS transfers(
              id TEXT PRIMARY KEY,
              job_id TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              status TEXT NOT NULL,
              next_attempt_at REAL,
              updated_at REAL NOT NULL,
              total_bytes INTEGER NOT NULL DEFAULT 0,
              completed_bytes INTEGER NOT NULL DEFAULT 0,
              payload BLOB NOT NULL
            )
            """
        )
        // These are additive migrations for databases created by early builds.
        try? database.execute("ALTER TABLE transfers ADD COLUMN total_bytes INTEGER NOT NULL DEFAULT 0")
        try? database.execute("ALTER TABLE transfers ADD COLUMN completed_bytes INTEGER NOT NULL DEFAULT 0")
        try database.execute("CREATE INDEX IF NOT EXISTS transfer_run_queue ON transfers(job_id, status, next_attempt_at)")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS transfer_parts(
              transfer_id TEXT NOT NULL,
              part_number INTEGER NOT NULL,
              payload BLOB NOT NULL,
              PRIMARY KEY(transfer_id, part_number)
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS manifest(
              job_id TEXT NOT NULL,
              side TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              canonical_path TEXT NOT NULL DEFAULT '',
              scan_generation INTEGER NOT NULL,
              payload BLOB NOT NULL,
              PRIMARY KEY(job_id, side, relative_path)
            )
            """
        )
        try? database.execute("ALTER TABLE manifest ADD COLUMN canonical_path TEXT NOT NULL DEFAULT ''")
        try database.execute("CREATE INDEX IF NOT EXISTS manifest_scan_generation ON manifest(job_id, side, scan_generation)")
        try database.execute("CREATE INDEX IF NOT EXISTS manifest_reconcile_path ON manifest(job_id, side, scan_generation, relative_path)")
        try database.execute("CREATE INDEX IF NOT EXISTS manifest_reconcile_canonical ON manifest(job_id, side, scan_generation, canonical_path)")
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS manifest_conflicts(
              job_id TEXT NOT NULL,
              scan_generation INTEGER NOT NULL,
              canonical_path TEXT NOT NULL,
              PRIMARY KEY(job_id, scan_generation, canonical_path)
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS snapshots(
              id TEXT PRIMARY KEY,
              payload BLOB NOT NULL
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS baselines(
              job_id TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              payload BLOB NOT NULL,
              PRIMARY KEY(job_id, relative_path)
            )
            """
        )
        return previousVersion < 2
    }

    private static func backfillTransferMetrics(
        database: SQLiteDatabase,
        decoder: JSONDecoder
    ) throws {
        var records: [TransferRecord] = []
        try database.query(
            "SELECT payload FROM transfers WHERE total_bytes = 0 AND completed_bytes = 0"
        ) { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            records.append(try decoder.decode(TransferRecord.self, from: payload))
        }
        guard !records.isEmpty else { return }
        try database.transaction {
            for record in records {
                try database.execute(
                    "UPDATE transfers SET total_bytes = ?, completed_bytes = ? WHERE id = ?",
                    bindings: [
                        .integer(record.totalBytes),
                        .integer(record.completedBytes),
                        .text(record.id.description)
                    ]
                )
            }
        }
    }

    private static func recoverInterruptedTransfers(
        database: SQLiteDatabase,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) throws {
        var interrupted: [TransferRecord] = []
        try database.query(
            "SELECT payload FROM transfers WHERE status IN ('running', 'verifying') ORDER BY updated_at ASC"
        ) { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            interrupted.append(try decoder.decode(TransferRecord.self, from: payload))
        }
        for var transfer in interrupted {
            transfer.status = .waiting
            transfer.lastError = nil
            transfer.nextAttemptAt = nil
            transfer.updatedAt = Date()
            try database.execute(
                """
                UPDATE transfers
                SET status = ?, next_attempt_at = NULL, updated_at = ?,
                    total_bytes = ?, completed_bytes = ?, payload = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(transfer.status.rawValue),
                    .real(transfer.updatedAt.timeIntervalSince1970),
                    .integer(transfer.totalBytes),
                    .integer(transfer.completedBytes),
                    .blob(try encoder.encode(transfer)),
                    .text(transfer.id.description)
                ]
            )
        }
    }

    /// Tables that hold one JSON document per row and are addressed by name in
    /// interpolated SQL. Kept in one place so a caller cannot reach a table
    /// that is not shaped this way, and so adding one is a single edit.
    private static let documentTables: Set<String> = ["connections", "credentials", "jobs", "snapshots"]

    private func upsert(table: String, id: String, payload: Data) throws {
        precondition(Self.documentTables.contains(table))
        try database.execute(
            "INSERT INTO \(table)(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
            bindings: [.text(id), .blob(payload)]
        )
    }

    private func enqueueTransferInsideTransaction(_ plan: TransferPlan, jobID: SyncJobID) throws -> Bool {
        var hasActive = false
        try database.query(
            """
            SELECT 1 FROM transfers
            WHERE job_id = ? AND relative_path = ?
              AND status IN ('queued', 'running', 'waiting', 'verifying')
            LIMIT 1
            """,
            bindings: [.text(jobID.description), .text(plan.relativePath)]
        ) { _ in
            hasActive = true
        }
        guard !hasActive else { return false }

        var terminalIDs: [String] = []
        try database.query(
            """
            SELECT id FROM transfers
            WHERE job_id = ? AND relative_path = ?
              AND status IN ('completed', 'superseded', 'failed')
            """,
            bindings: [.text(jobID.description), .text(plan.relativePath)]
        ) { statement in
            if let identifier = database.text(statement, column: 0) {
                terminalIDs.append(identifier)
            }
        }
        for identifier in terminalIDs {
            try database.execute(
                "DELETE FROM transfer_parts WHERE transfer_id = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM transfers WHERE id = ?",
                bindings: [.text(identifier)]
            )
        }
        try saveTransfer(
            TransferRecord(
                jobID: jobID,
                relativePath: plan.relativePath,
                kind: plan.kind,
                totalBytes: plan.totalBytes,
                sourceFingerprint: plan.localFingerprint,
                remoteSource: plan.remoteObject,
                remoteKey: plan.remoteKey
            )
        )
        return true
    }

    private func load<T: Decodable & Sendable>(table: String, id: String, as type: T.Type) throws -> T? {
        precondition(Self.documentTables.contains(table))
        var value: T?
        try database.query(
            "SELECT payload FROM \(table) WHERE id = ?",
            bindings: [.text(id)]
        ) { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            value = try decoder.decode(T.self, from: payload)
        }
        return value
    }

    private func loadAll<T: Decodable & Sendable>(table: String, as type: T.Type) throws -> [T] {
        precondition(Self.documentTables.contains(table))
        var values: [T] = []
        try database.query("SELECT payload FROM \(table) ORDER BY id ASC") { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            values.append(try decoder.decode(T.self, from: payload))
        }
        return values
    }

    private func loadTransfer(
        where clause: String,
        bindings: [SQLiteValue],
        order: String = "updated_at ASC",
        limit: Int? = nil
    ) throws -> [TransferRecord] {
        if let limit { precondition(limit > 0) }
        var values: [TransferRecord] = []
        let limitClause = limit.map { " LIMIT \($0)" } ?? ""
        try database.query(
            "SELECT payload FROM transfers WHERE \(clause) ORDER BY \(order)\(limitClause)",
            bindings: bindings
        ) { statement in
            guard let payload = database.blob(statement, column: 0) else { return }
            values.append(try decoder.decode(TransferRecord.self, from: payload))
        }
        return values
    }
}
