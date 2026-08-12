import CryptoKit
import Foundation
import StorageSyncCore
import StorageSyncEngine
import StorageSyncPersistence
import StorageSyncS3
import StorageSyncSystem

@main
struct StorageSyncTestRunner {
    static func main() async {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--write-running-transfer" {
            await writeRunningTransferAndExit(
                databasePath: CommandLine.arguments[2],
                transferID: CommandLine.arguments[3]
            )
        }
        let suite = ReliabilitySuite()
        do {
            try await suite.run()
            print("PASS: all StorageSync reliability checks completed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func writeRunningTransferAndExit(databasePath: String, transferID: String) async -> Never {
        do {
            guard let uuid = UUID(uuidString: transferID) else { exit(19) }
            let repository = try SyncRepository(databaseURL: URL(fileURLWithPath: databasePath))
            try await repository.saveTransfer(
                TransferRecord(
                    id: TransferID(rawValue: uuid),
                    jobID: SyncJobID(),
                    relativePath: "interrupted.raw",
                    kind: .upload,
                    status: .running,
                    totalBytes: 123,
                    remoteKey: "interrupted.raw"
                )
            )
            exit(17)
        } catch {
            exit(18)
        }
    }
}

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

/// Keychain items outlive the process and the temporary directory, so the
/// credential checks record what they wrote and take it back out — including
/// on the way out of a failed check.
private final class KeychainReferenceBox: @unchecked Sendable {
    private var references: [String] = []

    func add(_ reference: String) {
        references.append(reference)
    }

    func purge(from keychain: KeychainStore) async {
        for reference in references {
            try? await keychain.remove(reference: reference)
        }
        references = []
    }
}

private final class S3URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func install(_ value: @escaping Handler) {
        lock.lock()
        handler = value
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let currentHandler = Self.handler
        Self.requests.append(request)
        Self.lock.unlock()
        do {
            guard let currentHandler else {
                throw CheckFailure.failed("The S3 URL protocol stub had no response handler")
            }
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ReliabilitySuite {
    func run() async throws {
        try transferPolicyCheck()
        try signatureVersion4Check()
        try await s3HTTPTransportCheck()
        try await s3ListingPaginationCheck()
        try await s3HTTPErrorClassificationCheck()
        try reconciliationSafetyCheck()
        try initialDestinationAdoptionCheck()
        try storageBalanceCheck()
        try await diskBackedManifestCheck()
        try await localScannerBackpressureCheck()
        try await packageContentsScanCheck()
        try await partialDirectorySymlinkCheck()
        try await persistenceRecoveryCheck()
        try await transferActivityCheck()
        try await persistenceJobRemovalCheck()
        try await credentialStoreCheck()
        try await gracefulUnmountPreparationCheck()
        try await processCrashRecoveryCheck()
        try await multipartLostResponseCheck()
        try await multipartCompletionLostResponseCheck()
        try await expiredMultipartUploadCheck()
        try await parallelMultipartCheck()
        try await cancellationResumeCheck()
        try await sourceMutationCheck()
        try await sourceDeletionCheck()
        try await uploadVolumeDisappearanceCheck()
        try await downloadRemountFingerprintCheck()
        try await rangedDownloadResumeCheck()
        try await outOfOrderRangedDownloadResumeCheck()
        try await downloadRequiresStableRemoteIdentityCheck()
        try await localDestinationMutationCheck()
        try await downloadVolumeDisappearanceCheck()
    }

    private func transferPolicyCheck() throws {
        let policy = TransferPolicy(preferredPartSize: 8 * 1_024 * 1_024, maximumPartCount: 10)
        let parts = try policy.parts(forFileSize: 81 * 1_024 * 1_024, transferID: TransferID())
        try check(parts.count <= 10, "Multipart planning exceeded the provider part limit")
        try check(parts.first?.offset == 0, "Multipart planning did not start at the first byte of the file")
        try check(parts.last.map { $0.offset + $0.length } == 81 * 1_024 * 1_024, "Multipart planning did not cover the complete file")

        let fiveTiB: Int64 = 5 * 1_024 * 1_024 * 1_024 * 1_024
        let maximumObjectParts = try TransferPolicy().parts(
            forFileSize: fiveTiB,
            transferID: TransferID()
        )
        try check(
            maximumObjectParts.count <= 10_000,
            "A 5 TiB object exceeded S3's 10,000-part limit"
        )
        try check(
            maximumObjectParts.allSatisfy { $0.length <= 5 * 1_024 * 1_024 * 1_024 },
            "A 5 TiB object produced a part larger than S3's 5 GiB limit"
        )
        try check(
            maximumObjectParts.last.map { $0.offset + $0.length } == fiveTiB,
            "Multipart planning did not cover every byte of a 5 TiB object"
        )
        do {
            _ = try TransferPolicy().parts(forFileSize: fiveTiB + 1, transferID: TransferID())
            throw CheckFailure.failed("Multipart planning accepted an object larger than S3's 5 TiB limit")
        } catch TransferPolicyError.objectTooLarge {
            // Expected.
        }

        let indefinite = RetryPolicy(baseDelay: .seconds(1), maximumDelay: .seconds(300))
        let lateDelay = indefinite.delay(forAttempt: 10_000, randomUnit: 1)
        try check(lateDelay == .seconds(300), "Transient retry policy stopped or overflowed during a multi-day outage")

        // Full jitter: the delay is the exponential ceiling scaled by the random
        // unit, so a fleet of retries spreads out instead of hammering the
        // provider in lockstep. A bounded policy must also eventually give up.
        let bounded = RetryPolicy(baseDelay: .seconds(1), maximumDelay: .seconds(60), maximumAttempts: 4)
        try check(
            bounded.delay(forAttempt: 2, randomUnit: 0.5) == .seconds(2),
            "The retry policy stopped applying full jitter to its exponential backoff"
        )
        try check(
            bounded.delay(forAttempt: 4, randomUnit: 0.5) == nil,
            "A bounded retry policy kept retrying past its attempt limit"
        )

        let beforeRemount = FileFingerprint(
            relativePath: "DCIM/photo.raw",
            size: 12_345,
            modificationTimeNanoseconds: 987_654_321,
            fileIdentifier: "exfat-mount-a"
        )
        var afterRemount = beforeRemount
        afterRemount.fileIdentifier = "exfat-mount-b"
        try check(
            beforeRemount.representsSameContent(as: afterRemount),
            "A remounted ExFAT file was mistaken for changed content when only its transient file ID changed"
        )
        try check(
            !beforeRemount.representsSameFileState(as: afterRemount),
            "Same-mount mutation checks stopped detecting a changed file identity"
        )
        let beforeRewrite = FileFingerprint(
            relativePath: "DCIM/photo.raw",
            size: 12_345,
            modificationTimeNanoseconds: 987_654_321,
            fileIdentifier: "stable-file",
            generationIdentifier: "generation-1"
        )
        var afterRewrite = beforeRewrite
        afterRewrite.generationIdentifier = "generation-2"
        try check(
            !beforeRewrite.representsSameContent(as: afterRewrite),
            "A same-file generation change was hidden by preserved size and modification time"
        )
        let expectedMarker = UUID()
        let expectedVolume = VolumeIdentity(
            persistentUUID: "cloned-uuid",
            creationDate: nil,
            filesystemType: "ExFAT",
            totalCapacity: 1_000,
            isRemovable: true,
            rootMarker: expectedMarker
        )
        let clonedVolume = VolumeIdentity(
            persistentUUID: "cloned-uuid",
            creationDate: nil,
            filesystemType: "ExFAT",
            totalCapacity: 1_000,
            isRemovable: true,
            rootMarker: UUID()
        )
        try check(
            !expectedVolume.confidentlyMatches(clonedVolume),
            "A different external volume with a cloned filesystem UUID passed the marker check"
        )
    }

    /// The interface draws what is on this Mac, what is moving, and what is in
    /// the bucket as three lines on one shared scale, and every one of those
    /// lengths comes out of `StorageBalance`. Two properties make that drawing
    /// honest rather than decorative: the destination line plus the pending
    /// line must always be the entire width, and the width must not change
    /// while a run fills it in. A bar that quietly rescales as it advances
    /// would let a sync appear to make progress it has not made.
    ///
    /// This covers the arithmetic, which is where the subtlety is. What the
    /// coordinator feeds it is not reachable from here: `runCycle` needs a
    /// bookmark store, a keychain and a live object store.
    private func storageBalanceCheck() throws {
        func balance(
            _ direction: SyncDirection = .upload,
            source: Int64,
            destination: Int64,
            queued: Int64,
            moved: Int64 = 0,
            sourceFiles: Int = 0,
            destinationFiles: Int = 0,
            alreadyPresent: Int = 0,
            queuedFiles: Int = 0
        ) throws -> StorageBalance {
            let snapshot = SyncSnapshot(
                jobID: SyncJobID(),
                phase: .transferring,
                filesTotal: queuedFiles,
                bytesCompleted: moved,
                bytesTotal: queued,
                sourceFilesFound: sourceFiles,
                destinationFilesFound: destinationFiles,
                filesAlreadyPresent: alreadyPresent,
                sourceBytesFound: source,
                destinationBytesInPlace: destination
            )
            guard let value = StorageBalance(snapshot: snapshot, direction: direction) else {
                throw CheckFailure.failed("A snapshot carrying byte totals produced no storage balance")
            }
            return value
        }
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.0001 }

        // A library entirely on this Mac, most of it already uploaded: the top
        // line covers everything, the middle covers what is left, and the two
        // lower lines divide the width between them.
        let wholeLibraryHere = try balance(source: 1_000, destination: 800, queued: 200)
        try check(wholeLibraryHere.totalBytes == 1_000, "A fully local library did not size the balance to itself")
        try check(near(wholeLibraryHere.localFraction, 1), "A fully local library did not fill the local line")
        try check(near(wholeLibraryHere.pendingFraction, 0.2), "The pending line did not cover the un-uploaded fifth")
        try check(near(wholeLibraryHere.cloudFraction, 0.8), "The cloud line did not cover the uploaded four fifths")

        // A bucket holding more than this Mac does: 1,500 uploaded earlier, 800
        // here of which 300 are already up there, 500 still to go.
        let bucketHoldsMore = try balance(
            source: 800,
            destination: 1_500,
            queued: 500,
            sourceFiles: 800,
            destinationFiles: 1_500,
            alreadyPresent: 300,
            queuedFiles: 500
        )
        try check(bucketHoldsMore.totalBytes == 2_000, "The balance did not span everything on both sides")
        try check(near(bucketHoldsMore.localFraction, 0.4), "The local line did not cover two fifths")
        try check(near(bucketHoldsMore.pendingFraction, 0.25), "The pending line did not cover a quarter")
        try check(near(bucketHoldsMore.cloudFraction, 0.75), "The cloud line did not cover three quarters")
        try check(bucketHoldsMore.sharedBytes == 300, "The overlap between the two sides was miscounted")
        try check(bucketHoldsMore.cloudOnlyBytes == 1_200, "Bucket content absent from this Mac was miscounted")
        try check(bucketHoldsMore.localFiles == 800, "The local file count did not follow the sync's direction")
        try check(bucketHoldsMore.cloudFiles == 1_500, "The cloud file count did not follow the sync's direction")
        try check(bucketHoldsMore.sharedFiles == 300, "The already-present file count was not carried through")
        try check(bucketHoldsMore.pendingFiles == 500, "The remaining file count was not carried through")

        // The whole run, byte by byte. The width has to stay put and the two
        // lower lines have to keep dividing it exactly.
        for moved in stride(from: Int64(0), through: 500, by: 125) {
            let during = try balance(source: 800, destination: 1_500, queued: 500, moved: moved)
            try check(
                during.cloudBytes + during.pendingBytes == during.totalBytes,
                "The cloud and pending lines stopped covering the whole width at \(moved) bytes moved"
            )
            try check(
                during.totalBytes == 2_000,
                "The balance rescaled mid-run at \(moved) bytes moved"
            )
            try check(
                near(during.localFraction, 0.4),
                "The local line moved while only the destination was gaining, at \(moved) bytes moved"
            )
        }

        // What the coordinator writes once the transfer loop ends: the moved
        // bytes are folded into the destination and the queue is reset. The
        // balance has to read the same on both sides of that hand-off.
        let duringLastByte = try balance(source: 800, destination: 1_500, queued: 500, moved: 500)
        let afterCycle = try balance(source: 800, destination: 2_000, queued: 0, moved: 0)
        try check(
            afterCycle.totalBytes == duringLastByte.totalBytes
                && afterCycle.cloudBytes == duringLastByte.cloudBytes,
            "The balance jumped when the finished run was folded into the destination"
        )
        try check(!afterCycle.hasPendingWork, "A finished run still reported work in flight")
        try check(near(afterCycle.cloudFraction, 1), "A finished upload did not fill the cloud line")

        // The batch seen from the inside, which is the number a long copy is
        // actually watched by. It is independent of how large the library is.
        let midBatch = try balance(source: 800, destination: 1_500, queued: 500, moved: 125)
        try check(near(midBatch.runFraction, 0.25), "This run's own progress was misreported")
        try check(near(duringLastByte.runFraction, 1), "A fully copied run did not report itself finished")
        try check(near(afterCycle.runFraction, 0), "An empty queue reported progress through nothing")

        // A changed file exists at both ends, but only one of the two versions
        // is current. The coordinator subtracts the copy being replaced before
        // reporting the destination; without that the same photo would be
        // counted twice and the total would claim twice the storage.
        let replacingOneFile = try balance(source: 10, destination: 0, queued: 10)
        try check(replacingOneFile.totalBytes == 10, "A file being replaced was counted at both ends")
        try check(near(replacingOneFile.localFraction, 1), "The local line lost a file that is on this Mac")
        try check(near(replacingOneFile.pendingFraction, 1), "A file due to be replaced was not shown as pending")

        // Restores read the same picture from the other side: the local line is
        // the one that grows, and the pending line is still the gap it grows
        // into. 1,500 in the bucket, 800 here, 300 of those in both places.
        let restore = try balance(.download, source: 1_500, destination: 800, queued: 1_200)
        try check(restore.totalBytes == 2_000, "A download did not span everything on both sides")
        try check(near(restore.localFraction, 0.4), "A download's local line was misdrawn")
        try check(near(restore.cloudFraction, 0.75), "A download's cloud line was misdrawn")
        try check(
            restore.localBytes + restore.pendingBytes == restore.totalBytes,
            "A download's growing line and its pending gap did not cover the whole width"
        )
        try check(restore.sharedBytes == 300, "A download's overlap between the two sides was miscounted")

        // Nothing is drawn from a snapshot written before these totals existed,
        // or from the bare one the engine writes when a drive disappears.
        try check(
            StorageBalance(
                snapshot: SyncSnapshot(jobID: SyncJobID(), phase: .watching, blockers: [.localVolumeUnavailable]),
                direction: .upload
            ) == nil,
            "A snapshot with no byte totals produced a balance to draw anyway"
        )
    }

    private func signatureVersion4Check() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        let signer = SigV4Signer()
        let signed = try signer.sign(
            request: request,
            bodySHA256: signer.sha256Hex(Data()),
            credentials: S3Credentials(
                accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
            ),
            region: "us-east-1",
            date: date
        )
        let authorization = signed.value(forHTTPHeaderField: "Authorization") ?? ""
        try check(
            authorization.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"),
            "The SigV4 signer did not match Amazon S3's published GET-object test vector"
        )
    }

    private func s3HTTPTransportCheck() async throws {
        S3URLProtocolStub.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: request.value(forHTTPHeaderField: "Range") == nil ? 200 : 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": request.httpMethod == "PUT" ? "0" : "4",
                        "ETag": "\"etag\""
                    ]
                  ) else {
                throw CheckFailure.failed("Could not construct the stub S3 response")
            }
            let query = Dictionary(
                uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") }
            )
            if query["uploadId"] != nil {
                if request.httpMethod == "POST" {
                    return (
                        response,
                        Data("<Error><Code>InternalError</Code><Message>Completion failed after HTTP 200</Message></Error>".utf8)
                    )
                }
                if query["part-number-marker"] == nil {
                    return (
                        response,
                        Data(
                            """
                            <ListPartsResult>
                              <IsTruncated>true</IsTruncated>
                              <NextPartNumberMarker>1</NextPartNumberMarker>
                              <Part><PartNumber>1</PartNumber><ETag>\"one\"</ETag><Size>8</Size></Part>
                            </ListPartsResult>
                            """.utf8
                        )
                    )
                }
                return (
                    response,
                    Data(
                        """
                        <ListPartsResult>
                          <IsTruncated>false</IsTruncated>
                          <Part><PartNumber>2</PartNumber><ETag>\"two\"</ETag><Size>3</Size></Part>
                        </ListPartsResult>
                        """.utf8
                    )
                )
            }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return (response, Data("data".utf8))
            }
            return (
                response,
                Data(
                    """
                    <ListBucketResult>
                      <IsTruncated>true</IsTruncated>
                      <NextContinuationToken>next-token</NextContinuationToken>
                      <Contents><Key>photos &amp; raw/a.jpg</Key><LastModified>2024-01-01T00:00:00Z</LastModified><ETag>\"object\"</ETag><Size>4</Size></Contents>
                    </ListBucketResult>
                    """.utf8
                )
            )
        }
        defer { S3URLProtocolStub.reset() }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [S3URLProtocolStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let store = S3ObjectStore(
            configuration: S3ClientConfiguration(
                endpoint: URL(string: "https://objects.example.test")!,
                region: "us-test-1",
                bucket: "test-bucket",
                addressingStyle: .path,
                credentials: S3Credentials(accessKeyID: "ACCESS", secretAccessKey: "SECRET")
            ),
            session: session
        )

        let page = try await store.list(prefix: "photos & raw", continuationToken: "token+/=")
        try check(page.objects.map(\.key) == ["photos & raw/a.jpg"], "S3 ListObjects XML was not decoded")
        try check(page.nextContinuationToken == "next-token", "S3 continuation token was not decoded")

        let parts = try await store.listParts(key: "large file.bin", uploadID: "upload+/=")
        try check(parts.map(\.number) == [1, 2], "A truncated S3 ListParts response was not paged")

        let bytes = try await store.getRange(key: "folder/a b#%.jpg", range: 5..<9)
        try check(bytes == Data("data".utf8), "The ranged S3 response body was not returned")

        let uploaded = try await store.put(
            key: "folder/new.jpg",
            data: Data("payload".utf8),
            metadata: ["storagesync-source-size": "7"]
        )
        try check(uploaded.size == 7, "A zero-length S3 PUT response was mistaken for the uploaded object size")

        do {
            _ = try await store.completeMultipartUpload(
                key: "large file.bin",
                uploadID: "upload+/=",
                parts: [UploadedPart(number: 1, eTag: "\"one\"")]
            )
            throw CheckFailure.failed("An embedded S3 multipart completion error was accepted as success")
        } catch ObjectStoreError.transient(let message) {
            try check(message == "Completion failed after HTTP 200", "The embedded S3 error message was lost")
        }

        let requests = S3URLProtocolStub.recordedRequests()
        try check(requests.count == 6, "The S3 transport made an unexpected number of paged requests")
        guard let listURL = requests.first?.url,
              let listQuery = URLComponents(url: listURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw CheckFailure.failed("The signed S3 list request had no URL")
        }
        try check(listQuery.first(where: { $0.name == "prefix" })?.value == "photos & raw", "The S3 prefix was not safely query encoded")
        try check(listQuery.first(where: { $0.name == "continuation-token" })?.value == "token+/=", "The S3 continuation token was not safely query encoded")
        try check(
            listURL.absoluteString.contains("continuation-token=token%2B%2F%3D"),
            "The transmitted S3 continuation token did not use AWS byte-wise URI encoding"
        )
        try check(
            listURL.absoluteString.contains("prefix=photos%20%26%20raw"),
            "The transmitted S3 prefix did not use AWS byte-wise URI encoding"
        )
        try check(requests[1].url?.query?.contains("max-parts=1000") == true, "ListParts did not request an explicit provider page size")
        try check(requests[2].url?.query?.contains("part-number-marker=1") == true, "ListParts did not use the provider continuation marker")
        let encodedObjectPath = requests[3].url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
        try check(encodedObjectPath == "/test-bucket/folder/a%20b%23%25.jpg", "An S3 object key was not safely path encoded")
        try check(requests[3].value(forHTTPHeaderField: "Range") == "bytes=5-8", "The S3 byte range was malformed")
        try check(requests[4].value(forHTTPHeaderField: "x-amz-meta-storagesync-source-size") == "7", "S3 object metadata was not sent with PUT")
        try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true }, "An S3 request was sent without SigV4 authorization")
    }

    /// Two things the coordinator's remote scan depends on and that the rest of
    /// the suite cannot see, because it drives `list` once and never follows a
    /// token: the paging termination rule, and the timestamp format real AWS
    /// actually sends.
    private func s3ListingPaginationCheck() async throws {
        // Every timestamp here is the form AWS genuinely returns from
        // ListObjectsV2 — seconds plus three fractional digits. A fixture
        // without the fractional part passes against a parser that rejects
        // every real response, which is exactly what used to happen.
        let firstPageModified = "2024-05-06T07:08:09.000Z"
        let secondPageModified = "2024-05-06T07:08:10Z"
        S3URLProtocolStub.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                  ) else {
                throw CheckFailure.failed("Could not construct the stub listing response")
            }
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "continuation-token" })?.value
            switch token {
            case nil:
                return (
                    response,
                    Data(
                        """
                        <ListBucketResult>
                          <IsTruncated>true</IsTruncated>
                          <NextContinuationToken>page-2</NextContinuationToken>
                          <Contents><Key>album/first.jpg</Key><LastModified>\(firstPageModified)</LastModified><ETag>\"one\"</ETag><Size>1</Size></Contents>
                        </ListBucketResult>
                        """.utf8
                    )
                )
            case "page-2":
                // A final page that still carries a token. Following it would
                // replay this same page forever, so the token must be dropped.
                return (
                    response,
                    Data(
                        """
                        <ListBucketResult>
                          <IsTruncated>false</IsTruncated>
                          <NextContinuationToken>page-2</NextContinuationToken>
                          <Contents><Key>album/second.jpg</Key><LastModified>\(secondPageModified)</LastModified><ETag>\"two\"</ETag><Size>2</Size></Contents>
                        </ListBucketResult>
                        """.utf8
                    )
                )
            default:
                // Truncated, but with no usable token to continue from. Trusting
                // this page would hand reconciliation a partial bucket listing
                // and call it the whole bucket.
                return (
                    response,
                    Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8)
                )
            }
        }
        defer { S3URLProtocolStub.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = S3ObjectStore(
            configuration: S3ClientConfiguration(
                endpoint: URL(string: "https://objects.example.test")!,
                region: "us-test-1",
                bucket: "test-bucket",
                addressingStyle: .path,
                credentials: S3Credentials(accessKeyID: "ACCESS", secretAccessKey: "SECRET")
            ),
            session: session
        )

        let first = try await store.list(prefix: "album", continuationToken: nil)
        try check(first.nextContinuationToken == "page-2", "A truncated listing did not report its continuation token")
        try check(
            first.objects.first?.lastModified == Date(timeIntervalSince1970: 1_714_979_289),
            "A real S3 timestamp with fractional seconds was not decoded"
        )

        let second = try await store.list(prefix: "album", continuationToken: "page-2")
        try check(
            second.nextContinuationToken == nil,
            "An untruncated listing handed back a continuation token, which pages the remote scan forever"
        )
        try check(
            second.objects.first?.lastModified == Date(timeIntervalSince1970: 1_714_979_290),
            "An S3 timestamp without fractional seconds was not decoded"
        )

        do {
            _ = try await store.list(prefix: "album", continuationToken: "page-3")
            throw CheckFailure.failed("A truncated listing with no continuation token was accepted as complete")
        } catch ObjectStoreError.invalidResponse {
            // Expected.
        }
    }

    private func s3HTTPErrorClassificationCheck() async throws {
        S3URLProtocolStub.install { request in
            guard let url = request.url else {
                throw CheckFailure.failed("The S3 error-classification request had no URL")
            }
            let prefix = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "prefix" })?.value
            let status: Int
            let code: String
            switch prefix {
            case "retry":
                status = 400
                code = "RequestTimeout"
            case "expired":
                status = 403
                code = "ExpiredToken"
            default:
                status = 404
                code = "NoSuchBucket"
            }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/xml"]
            ) else {
                throw CheckFailure.failed("Could not construct the S3 error response")
            }
            return (
                response,
                Data("<Error><Code>\(code)</Code><Message>\(code) message</Message></Error>".utf8)
            )
        }
        defer { S3URLProtocolStub.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = S3ObjectStore(
            configuration: S3ClientConfiguration(
                endpoint: URL(string: "https://objects.example.test")!,
                region: "us-test-1",
                bucket: "test-bucket",
                addressingStyle: .path,
                credentials: S3Credentials(accessKeyID: "ACCESS", secretAccessKey: "SECRET")
            ),
            session: session
        )

        do {
            _ = try await store.list(prefix: "retry", continuationToken: nil)
            throw CheckFailure.failed("An S3 RequestTimeout response was accepted")
        } catch ObjectStoreError.transient(let message) {
            try check(message == "RequestTimeout message", "The retryable S3 error message was lost")
        }
        do {
            _ = try await store.list(prefix: "expired", continuationToken: nil)
            throw CheckFailure.failed("An expired S3 session token was accepted")
        } catch ObjectStoreError.authentication(let message) {
            try check(message == "ExpiredToken message", "The S3 authentication error message was lost")
        }
        do {
            _ = try await store.list(prefix: "missing", continuationToken: nil)
            throw CheckFailure.failed("A missing S3 bucket was accepted")
        } catch ObjectStoreError.incompatible(let message) {
            try check(message == "NoSuchBucket message", "The missing-bucket error message was lost")
        }
    }

    private func reconciliationSafetyCheck() throws {
        let local = FileFingerprint(relativePath: "new.jpg", size: 10, modificationTimeNanoseconds: 2)
        let result = Reconciler().reconcile(
            direction: .upload,
            prefix: "photos",
            localFiles: [local],
            remoteObjects: [RemoteObject(key: "photos/old.jpg", size: 8, eTag: "old")],
            baselines: []
        )
        try check(result.transfers.map(\.relativePath) == ["new.jpg"], "Reconciliation did not preserve the destination-only object")
        try check(result.transfers.first?.kind == .upload, "An upload job planned something other than an upload")

        // An unchanged file whose baseline still matches both sides is not
        // re-sent. Without this a caught-up sync would recopy itself on every
        // poll for as long as it existed.
        let unchanged = FileFingerprint(relativePath: "clip.mov", size: 50, modificationTimeNanoseconds: 7)
        let settled = Reconciler().reconcile(
            direction: .upload,
            prefix: "archive",
            localFiles: [unchanged],
            remoteObjects: [RemoteObject(key: "archive/clip.mov", size: 50, eTag: "v1")],
            baselines: [
                ReconciliationBaseline(
                    relativePath: "clip.mov",
                    localFingerprint: unchanged,
                    remoteETag: "v1",
                    remoteChecksum: nil,
                    remoteSize: 50
                )
            ]
        )
        try check(settled.transfers.isEmpty, "An unchanged file with a matching baseline was queued again")

        let unsafe = Reconciler().reconcile(
            direction: .download,
            prefix: "restore",
            localFiles: [],
            remoteObjects: [RemoteObject(key: "restore/../../escape", size: 1)],
            baselines: []
        )
        try check(unsafe.transfers.isEmpty, "An unsafe remote path was scheduled for download")
        try check(
            unsafe.invalidRemoteKeys == ["restore/../../escape"],
            "An unsafe remote path was skipped without being reported to the user"
        )

        let nestedInternalState = Reconciler().reconcile(
            direction: .download,
            prefix: "restore",
            localFiles: [],
            remoteObjects: [
                RemoteObject(key: "restore/album/.storagesync-volume-id", size: 36),
                RemoteObject(key: "restore/album/.storagesync-partials/pending", size: 1)
            ],
            baselines: []
        )
        try check(
            nestedInternalState.transfers.isEmpty
                && nestedInternalState.invalidRemoteKeys.isEmpty,
            "Nested StorageSync state was treated as user content or a permanent warning"
        )

        let collision = Reconciler().reconcile(
            direction: .download,
            prefix: "restore",
            localFiles: [],
            remoteObjects: [
                RemoteObject(key: "restore/Photo.JPG", size: 1),
                RemoteObject(key: "restore/photo.jpg", size: 1)
            ],
            baselines: [],
            localCaseSensitive: false
        )
        try check(collision.transfers.isEmpty, "Case-colliding remote keys were scheduled onto a case-insensitive volume")
        try check(collision.invalidRemoteKeys.count == 2, "Both colliding remote keys were not reported")

        // macOS case-insensitive volumes ignore case. They do not ignore
        // diacritics or character width, and treating them as if they did
        // merged genuinely distinct files: one was hidden behind a spurious
        // collision, and a local file could pair with an unrelated object under
        // the other spelling and overwrite it.
        try check(
            Reconciler.canonicalLocalPath("Photo.JPG") == Reconciler.canonicalLocalPath("photo.jpg"),
            "Case variants stopped mapping to one canonical path"
        )
        try check(
            Reconciler.canonicalLocalPath("Gökçe.jpg") != Reconciler.canonicalLocalPath("Gokce.jpg"),
            "Accented and unaccented names still collapse to one canonical path"
        )
        try check(
            Reconciler.canonicalLocalPath("ＷＩＤＥ.jpg") != Reconciler.canonicalLocalPath("WIDE.jpg"),
            "Full-width and half-width names still collapse to one canonical path"
        )
        let accented = Reconciler().reconcile(
            direction: .download,
            prefix: "restore",
            localFiles: [],
            remoteObjects: [
                RemoteObject(key: "restore/Gökçe.jpg", size: 1),
                RemoteObject(key: "restore/Gokce.jpg", size: 1)
            ],
            baselines: [],
            localCaseSensitive: false
        )
        try check(
            accented.transfers.map(\.relativePath).sorted() == ["Gokce.jpg", "Gökçe.jpg"].sorted(),
            "Two files that macOS keeps apart were treated as one colliding path"
        )
        try check(
            accented.invalidRemoteKeys.isEmpty,
            "Distinct accented filenames were reported to the user as unsafe object paths"
        )

        let overlongPrefix = String(repeating: "p", count: 1_020)
        let tooLong = Reconciler().reconcile(
            direction: .upload,
            prefix: overlongPrefix,
            localFiles: [FileFingerprint(relativePath: "photo.jpg", size: 1, modificationTimeNanoseconds: 1)],
            remoteObjects: [],
            baselines: []
        )
        try check(tooLong.transfers.isEmpty && tooLong.invalidRemoteKeys.count == 1, "An object key beyond S3's 1,024-byte limit was scheduled")

        let safeRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: safeRoot) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: safeRoot.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        do {
            _ = try SafePath.resolve("linked/escape.jpg", beneath: safeRoot)
            throw CheckFailure.failed("A symlink beneath the selected folder could escape the sync root")
        } catch is SafePathError {
            // Expected.
        }

        let expectedVolume = VolumeIdentity(
            persistentUUID: "drive-a",
            creationDate: nil,
            filesystemType: "APFS",
            totalCapacity: 1_000,
            isRemovable: true
        )
        let wrongVolume = VolumeIdentity(
            persistentUUID: "drive-b",
            creationDate: nil,
            filesystemType: "APFS",
            totalCapacity: 1_000,
            isRemovable: true
        )
        try check(!expectedVolume.confidentlyMatches(wrongVolume), "A different removable drive was accepted as the original")
    }

    private func initialDestinationAdoptionCheck() throws {
        let reconciler = Reconciler()
        let local = FileFingerprint(
            relativePath: "existing/photo.jpg",
            size: 10,
            modificationTimeNanoseconds: 100
        )
        let remote = RemoteObject(
            key: "backup/existing/photo.jpg",
            size: 99,
            eTag: "destination-version"
        )
        guard let baseline = reconciler.initialAdoptionBaseline(
            relativePath: local.relativePath,
            local: local,
            remote: remote,
            existingBaseline: nil
        ) else {
            throw CheckFailure.failed("A pre-existing destination object was not adopted")
        }
        try check(
            reconciler.transferPlan(
                direction: .upload,
                prefix: "backup",
                relativePath: local.relativePath,
                local: local,
                remote: remote,
                baseline: baseline
            ) == nil,
            "An adopted destination object was immediately re-uploaded"
        )
        var changed = local
        changed.modificationTimeNanoseconds += 1
        try check(
            reconciler.transferPlan(
                direction: .upload,
                prefix: "backup",
                relativePath: local.relativePath,
                local: changed,
                remote: remote,
                baseline: baseline
            ) != nil,
            "A later source change was hidden by initial destination adoption"
        )
    }

    private func packageContentsScanCheck() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root
            .appendingPathComponent("Archive.photoslibrary", isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent("image.heic", isDirectory: false)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: original)
        let partial = root
            .appendingPathComponent(".storagesync-partials", isDirectory: true)
            .appendingPathComponent("in-progress.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("temporary".utf8).write(to: partial)
        let nestedReserved = root
            .appendingPathComponent("album", isDirectory: true)
            .appendingPathComponent(".storagesync-partials", isDirectory: true)
            .appendingPathComponent("in-progress.partial")
        try FileManager.default.createDirectory(
            at: nestedReserved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("nested temporary file".utf8).write(to: nestedReserved)
        let nestedMarker = root
            .appendingPathComponent("album", isDirectory: true)
            .appendingPathComponent(VolumeInspector.markerFilename)
        try Data(UUID().uuidString.utf8).write(to: nestedMarker)
        let nestedPhoto = root
            .appendingPathComponent("album", isDirectory: true)
            .appendingPathComponent("real-photo.jpg")
        try Data("real nested file".utf8).write(to: nestedPhoto)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.jpg"),
            withDestinationURL: outside
        )
        var paths: [String] = []
        for try await file in LocalScanner().files(at: root) {
            paths.append(file.relativePath)
        }
        try check(
            paths == [
                "Archive.photoslibrary/originals/image.heic",
                "album/real-photo.jpg"
            ],
            "The scan omitted package contents or exposed nested StorageSync state: \(paths)"
        )
    }

    private func partialDirectorySymlinkCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let outside = fixture.directory.appendingPathComponent("outside-partials", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".storagesync-partials", isDirectory: true),
            withDestinationURL: outside
        )
        let payload = Data("must remain inside the selected root".utf8)
        let remote = await fixture.store.seed(key: "restore/safe.jpg", data: payload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "safe.jpg",
            kind: .download,
            totalBytes: Int64(payload.count),
            remoteSource: remote,
            remoteKey: remote.key
        )
        try await fixture.repository.saveTransfer(transfer)
        let result = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .attention = result else {
            throw CheckFailure.failed("A symlinked partial directory was accepted: \(result)")
        }
        let outsideItems = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        try check(outsideItems.isEmpty, "A download partial escaped through a symlinked internal directory")
    }

    private func diskBackedManifestCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SyncRepository(databaseURL: directory.appendingPathComponent("manifest.sqlite"))
        let jobID = SyncJobID()
        let localGeneration = try await repository.nextManifestGeneration(jobID: jobID, side: .local)
        let remoteGeneration = try await repository.nextManifestGeneration(jobID: jobID, side: .remote)

        let count = 2_047
        var localBatch: [FileFingerprint] = []
        var remoteBatch: [RemoteManifestRecord] = []
        for index in 0..<count {
            let path = String(format: "album/%05d.jpg", index)
            localBatch.append(
                FileFingerprint(
                    relativePath: path,
                    size: Int64(index + 1),
                    modificationTimeNanoseconds: Int64(index)
                )
            )
            remoteBatch.append(
                RemoteManifestRecord(
                    relativePath: path,
                    canonicalPath: Reconciler.canonicalLocalPath(path),
                    object: RemoteObject(key: "photos/" + path, size: Int64(index + 1), eTag: "etag-\(index)")
                )
            )
            if localBatch.count == 113 {
                try await repository.upsertLocalManifestEntries(
                    localBatch,
                    jobID: jobID,
                    generation: localGeneration,
                    caseSensitive: false
                )
                try await repository.upsertRemoteManifestEntries(
                    remoteBatch,
                    jobID: jobID,
                    generation: remoteGeneration
                )
                localBatch.removeAll(keepingCapacity: true)
                remoteBatch.removeAll(keepingCapacity: true)
            }
        }
        if !localBatch.isEmpty {
            try await repository.upsertLocalManifestEntries(
                localBatch,
                jobID: jobID,
                generation: localGeneration,
                caseSensitive: false
            )
            try await repository.upsertRemoteManifestEntries(
                remoteBatch,
                jobID: jobID,
                generation: remoteGeneration
            )
        }
        try await repository.finishManifestScan(jobID: jobID, side: .local, generation: localGeneration)
        try await repository.finishManifestScan(jobID: jobID, side: .remote, generation: remoteGeneration)

        var cursor: String?
        var observed = 0
        repeat {
            let rows = try await repository.reconciliationRows(
                jobID: jobID,
                direction: .download,
                localGeneration: localGeneration,
                remoteGeneration: remoteGeneration,
                localCaseSensitive: false,
                after: cursor,
                limit: 127
            )
            try check(rows.count <= 127, "Disk-backed reconciliation exceeded its requested page bound")
            observed += rows.count
            cursor = rows.last?.relativePath
            if rows.count < 127 { break }
        } while true
        try check(observed == count, "Paged manifest reconciliation lost or duplicated rows")

        let collisionRecords = ["Photo.JPG", "photo.jpg"].map { path in
            RemoteManifestRecord(
                relativePath: path,
                canonicalPath: Reconciler.canonicalLocalPath(path),
                object: RemoteObject(key: "photos/" + path, size: 1)
            )
        }
        try await repository.upsertRemoteManifestEntries(
            collisionRecords,
            jobID: jobID,
            generation: remoteGeneration
        )
        let removed = try await repository.removeCaseCollidingRemoteManifestEntries(
            jobID: jobID,
            generation: remoteGeneration
        )
        try check(removed == 2, "A case collision split across manifest batches was not removed as a complete group")
        try await repository.upsertLocalManifestEntries(
            [FileFingerprint(relativePath: "Photo.JPG", size: 1, modificationTimeNanoseconds: 1)],
            jobID: jobID,
            generation: localGeneration,
            caseSensitive: false
        )
        let collisionRows = try await repository.reconciliationRows(
            jobID: jobID,
            direction: .upload,
            localGeneration: localGeneration,
            remoteGeneration: remoteGeneration,
            localCaseSensitive: false,
            after: nil,
            limit: count + 10
        )
        try check(
            collisionRows.first(where: { $0.relativePath == "Photo.JPG" })?.hasRemotePathCollision == true,
            "A remote case-collision did not block an upload from recreating one arbitrary variant"
        )

        let existingCasing = RemoteObject(key: "photos/photo.jpg", size: 1)
        let casingPlan = Reconciler().transferPlan(
            direction: .upload,
            prefix: "photos",
            relativePath: "Photo.JPG",
            local: FileFingerprint(relativePath: "Photo.JPG", size: 1, modificationTimeNanoseconds: 2),
            remote: existingCasing,
            baseline: nil,
            remoteKeyOverride: existingCasing.key
        )
        try check(casingPlan?.remoteKey == "photos/photo.jpg", "An existing S3 key's casing was not preserved")

        for index in 0..<41 {
            let path = "queued/\(index).bin"
            try await repository.enqueueTransferIfNeeded(
                TransferPlan(
                    relativePath: path,
                    remoteKey: "photos/" + path,
                    kind: .upload,
                    totalBytes: Int64(index + 1),
                    localFingerprint: FileFingerprint(
                        relativePath: path,
                        size: Int64(index + 1),
                        modificationTimeNanoseconds: 1
                    ),
                    remoteObject: nil
                ),
                jobID: jobID
            )
        }
        let summary = try await repository.runnableTransferSummary(jobID: jobID)
        let bounded = try await repository.runnableTransfers(jobID: jobID, limit: 7)
        try check(summary.count == 41 && summary.totalBytes == 861, "The disk-backed queue aggregate was incorrect")
        try check(bounded.count == 7, "The runnable transfer query did not respect its memory bound")

        try await repository.saveTransfer(
            TransferRecord(
                jobID: jobID,
                relativePath: "delayed/retry.bin",
                kind: .upload,
                status: .waiting,
                totalBytes: 1_000,
                completedBytes: 250,
                remoteKey: "photos/delayed/retry.bin",
                retryCount: 3,
                nextAttemptAt: Date().addingTimeInterval(3_600),
                lastError: "temporary outage"
            )
        )
        let stillRunnable = try await repository.runnableTransferSummary(jobID: jobID)
        let active = try await repository.activeTransferSummary(jobID: jobID)
        try check(stillRunnable.count == 41, "A backoff-delayed transfer became runnable too early")
        try check(
            active.count == 42 && active.totalBytes == 1_861 && active.completedBytes == 250,
            "The active queue hid a backoff-delayed transfer from progress inventory"
        )
    }

    private func localScannerBackpressureCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCount = 1_025
        for index in 0..<expectedCount {
            let url = directory.appendingPathComponent(
                String(format: "backpressure-%05d.bin", index),
                isDirectory: false
            )
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data([UInt8(truncatingIfNeeded: index)])
            ) else {
                throw CheckFailure.failed("Could not create a scanner backpressure fixture")
            }
        }

        var observedPaths: Set<String> = []
        for try await file in LocalScanner().files(at: directory) {
            // The scanner's bounded buffer holds 512 records. A deliberately
            // slow consumer forces the producer through its retry/backpressure
            // path instead of merely exercising the normal fast path.
            try await Task.sleep(for: .milliseconds(1))
            let inserted = observedPaths.insert(file.relativePath).inserted
            try check(inserted, "The bounded local scanner emitted a duplicate path")
        }
        try check(
            observedPaths.count == expectedCount,
            "The bounded local scanner dropped entries under backpressure"
        )
    }

    private func persistenceRecoveryCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let jobID = SyncJobID()
        let transferID = TransferID()
        var repository: SyncRepository? = try SyncRepository(databaseURL: databaseURL)
        try await repository?.saveTransfer(
            TransferRecord(
                id: transferID,
                jobID: jobID,
                relativePath: "photo.raw",
                kind: .upload,
                status: .running,
                totalBytes: 100,
                remoteKey: "photo.raw"
            )
        )
        repository = nil
        let recoveredRepository = try SyncRepository(databaseURL: databaseURL)
        let recovered = try await recoveredRepository.transfer(id: transferID)
        try check(recovered?.status == .waiting, "A process-interrupted transfer did not recover into waiting state")
        try check(
            recovered?.nextAttemptAt == nil,
            "A process-interrupted transfer recovered behind a stale retry delay instead of being runnable"
        )

        try await recoveredRepository.savePart(
            TransferPart(
                transferID: transferID,
                number: 1,
                offset: 0,
                length: 100,
                checksum: "checkpoint",
                eTag: "etag",
                isComplete: true
            )
        )
        try await recoveredRepository.discardTransfers(jobID: jobID, relativePaths: ["photo.raw"])
        let discarded = try await recoveredRepository.transfer(id: transferID)
        let discardedParts = try await recoveredRepository.parts(transferID: transferID)
        try check(discarded == nil, "Obsolete work survived reconciliation queue cleanup")
        try check(discardedParts.isEmpty, "Obsolete multipart checkpoints survived reconciliation queue cleanup")

        let visiblePlans = ["new/photo.raw", "changed/video.mov"].map { path in
            TransferPlan(
                relativePath: path,
                remoteKey: path,
                kind: .upload,
                totalBytes: 10,
                localFingerprint: FileFingerprint(
                    relativePath: path,
                    size: 10,
                    modificationTimeNanoseconds: 1
                ),
                remoteObject: nil
            )
        }
        let reportedPaths = try await recoveredRepository.enqueueTransfersIfNeeded(
            visiblePlans,
            jobID: jobID
        )
        let duplicatePaths = try await recoveredRepository.enqueueTransfersIfNeeded(
            visiblePlans,
            jobID: jobID
        )
        try check(
            reportedPaths == visiblePlans.map(\.relativePath) && duplicatePaths.isEmpty,
            "The durable queue did not report exactly the newly visible paths"
        )
    }

    private func transferActivityCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("activity.sqlite")
        let jobID = SyncJobID()
        var repository: SyncRepository? = try SyncRepository(databaseURL: databaseURL)

        let started = try await repository?.beginTransferActivityBatchIfIdle(jobID: jobID)
        try check(started == true, "An idle scan did not start a transfer-activity batch")
        let emptyPage = try await repository?.transferActivityPage(
            TransferActivityPageRequest(jobID: jobID, limit: 150)
        )
        guard let firstBatchID = emptyPage?.batchID else {
            throw CheckFailure.failed("An empty activity batch had no durable identity")
        }

        let plans = (0..<320).map { index in
            let path = String(format: "roll/%04d.raw", index)
            return TransferPlan(
                relativePath: path,
                remoteKey: path,
                kind: .upload,
                totalBytes: Int64(index + 1),
                localFingerprint: FileFingerprint(
                    relativePath: path,
                    size: Int64(index + 1),
                    modificationTimeNanoseconds: Int64(index)
                ),
                remoteObject: nil
            )
        }
        let enqueued = try await repository?.enqueueTransfersIfNeeded(plans, jobID: jobID) ?? []
        try check(enqueued.count == plans.count, "The activity fixture did not enqueue every planned file")
        let didReplaceBusyBatch = try await repository?.beginTransferActivityBatchIfIdle(jobID: jobID)
        try check(
            didReplaceBusyBatch == false,
            "Starting another scan replaced activity while resumable work was still queued"
        )

        let firstPage = try await repository?.transferActivityPage(
            TransferActivityPageRequest(jobID: jobID, limit: 1)
        )
        guard let firstID = firstPage?.items.first?.id,
              var first = try await repository?.transfer(id: firstID) else {
            throw CheckFailure.failed("The activity fixture could not reload its first transfer")
        }
        // Exercise every status family the filters expose.
        first.status = .running
        first.completedBytes = max(1, first.totalBytes / 2)
        first.updatedAt = Date().addingTimeInterval(1)
        try await repository?.saveTransfer(first)

        let activeTransfers = try await repository?.activeTransfers(jobID: jobID) ?? []
        guard activeTransfers.count >= 3 else {
            throw CheckFailure.failed("The activity fixture lost active queue rows")
        }
        var waiting = activeTransfers[1]
        waiting.status = .waiting
        waiting.retryCount = 2
        waiting.lastError = "The network is unavailable"
        waiting.updatedAt = Date().addingTimeInterval(2)
        try await repository?.saveTransfer(waiting)
        var failed = activeTransfers[2]
        failed.status = .failed
        failed.lastError = "Injected attention state"
        failed.updatedAt = Date().addingTimeInterval(3)
        try await repository?.saveTransfer(failed)

        try await repository?.finalizeSuccessfulTransfer(
            transferID: first.id,
            baseline: ReconciliationBaseline(
                relativePath: first.relativePath,
                localFingerprint: first.sourceFingerprint ?? FileFingerprint(
                    relativePath: first.relativePath,
                    size: first.totalBytes,
                    modificationTimeNanoseconds: 0
                ),
                remoteETag: "complete",
                remoteChecksum: nil,
                remoteSize: first.totalBytes
            ),
            jobID: jobID
        )
        let completedQueueRow = try await repository?.transfer(id: first.id)
        try check(
            completedQueueRow == nil,
            "A completed transfer remained in the resumable queue"
        )

        var cursor: TransferActivityCursor?
        var observed: [TransferActivityItem] = []
        var revision: Int64 = 0
        repeat {
            let page = try await repository?.transferActivityPage(
                TransferActivityPageRequest(jobID: jobID, cursor: cursor, limit: 150)
            )
            guard let page else { break }
            try check(page.items.count <= 150, "An activity page exceeded its requested memory bound")
            if revision != 0 {
                try check(page.revision == revision, "A stable activity batch changed revision during pagination")
            }
            revision = page.revision
            observed += page.items
            cursor = page.nextCursor
        } while cursor != nil
        try check(observed.count == 320, "Paged transfer activity lost or duplicated rows")
        try check(Set(observed.map(\.id)).count == 320, "Paged transfer activity returned a duplicate row")

        let summary = try await repository?.transferActivityPage(
            TransferActivityPageRequest(jobID: jobID, limit: 1)
        )
        try check(summary?.counts.completed == 1, "Completed activity vanished with its queue row")
        try check(summary?.counts.issues == 1, "The Issues activity count omitted a failed transfer")
        try check(summary?.counts.waiting == 318, "Queued and retrying activity counts disagreed")
        let completedPage = try await repository?.transferActivityPage(
            TransferActivityPageRequest(jobID: jobID, filter: .completed, limit: 150)
        )
        try check(
            completedPage?.items.map(\.id) == [first.id],
            "The Completed filter did not preserve the successful file"
        )

        repository = nil
        repository = try SyncRepository(databaseURL: databaseURL)
        let restored = try await repository?.transferActivityPage(
            TransferActivityPageRequest(jobID: jobID, limit: 1)
        )
        try check(restored?.batchID == firstBatchID, "Process restart replaced the current activity batch")
        try check(restored?.revision == revision, "Process restart changed the durable activity revision")

        try await repository?.discardTransfers(jobID: jobID, relativePaths: plans.map(\.relativePath))
        let nextBatchStarted = try await repository?.beginTransferActivityBatchIfIdle(jobID: jobID)
        let nextBatch = try await repository?.transferActivityPage(
            TransferActivityPageRequest(jobID: jobID, limit: 150)
        )
        try check(nextBatchStarted == true, "A completed workload could not begin a fresh activity batch")
        try check(nextBatch?.batchID != firstBatchID, "A fresh scan reused the prior batch identity")
        try check(nextBatch?.items.isEmpty == true, "A fresh scan retained completed activity from the prior batch")
    }

    private func persistenceJobRemovalCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SyncRepository(databaseURL: directory.appendingPathComponent("removal.sqlite"))
        let connection = S3Connection(
            name: "Test S3",
            endpoint: URL(string: "https://objects.example.test")!,
            region: "test-1",
            bucket: "photos",
            credentialReference: "credential"
        )
        let removedJob = SyncJob(
            name: "Remove Me",
            direction: .upload,
            localRoot: LocalRoot(displayName: "one", fallbackPath: "/one", bookmarkReference: "one"),
            connectionID: connection.id,
            remotePrefix: "one"
        )
        let survivingJob = SyncJob(
            name: "Keep Me",
            direction: .upload,
            localRoot: LocalRoot(displayName: "two", fallbackPath: "/two", bookmarkReference: "two"),
            connectionID: connection.id,
            remotePrefix: "two"
        )
        try await repository.saveConnection(connection)
        try await repository.saveJob(removedJob)
        try await repository.saveJob(survivingJob)

        let fingerprint = FileFingerprint(
            relativePath: "photo.raw",
            size: 100,
            modificationTimeNanoseconds: 1
        )
        let transfer = TransferRecord(
            jobID: removedJob.id,
            relativePath: fingerprint.relativePath,
            kind: .upload,
            totalBytes: fingerprint.size,
            sourceFingerprint: fingerprint,
            remoteKey: "one/photo.raw",
            multipartUploadID: "unfinished-upload"
        )
        try await repository.saveTransfer(transfer)
        try await repository.savePart(
            TransferPart(
                transferID: transfer.id,
                number: 1,
                offset: 0,
                length: 50,
                checksum: "checkpoint",
                eTag: "etag",
                isComplete: true
            )
        )
        try await repository.saveBaseline(
            ReconciliationBaseline(
                relativePath: fingerprint.relativePath,
                localFingerprint: fingerprint,
                remoteETag: "etag",
                remoteChecksum: nil,
                remoteSize: fingerprint.size
            ),
            jobID: removedJob.id
        )
        try await repository.upsertLocalManifestEntries(
            [fingerprint],
            jobID: removedJob.id,
            generation: 1,
            caseSensitive: true
        )
        try await repository.setSnapshot(
            SyncSnapshot(jobID: removedJob.id, phase: .transferring, message: "Uploading")
        )

        try await repository.removeJobState(id: removedJob.id)

        let removedJobAfterward = try await repository.job(id: removedJob.id)
        let survivingJobAfterward = try await repository.job(id: survivingJob.id)
        let sharedConnectionAfterward = try await repository.connection(id: connection.id)
        let transferAfterward = try await repository.transfer(id: transfer.id)
        let partsAfterward = try await repository.parts(transferID: transfer.id)
        let baselinesAfterward = try await repository.baselines(jobID: removedJob.id)
        let snapshotAfterward = try await repository.snapshot(jobID: removedJob.id)
        let activityAfterward = try await repository.transferActivityPage(
            TransferActivityPageRequest(jobID: removedJob.id)
        )
        try check(removedJobAfterward == nil, "A removed sync job remained in SQLite")
        try check(survivingJobAfterward != nil, "Removing one sync deleted a different job")
        try check(sharedConnectionAfterward != nil, "Removing a job deleted its shared S3 connection")
        try check(transferAfterward == nil, "A removed sync left its transfer row")
        try check(partsAfterward.isEmpty, "A removed sync left multipart checkpoints")
        try check(baselinesAfterward.isEmpty, "A removed sync left baselines")
        try check(snapshotAfterward == nil, "A removed sync left its snapshot")
        try check(
            activityAfterward.batchID == nil && activityAfterward.items.isEmpty,
            "A removed sync left its transfer activity"
        )
        let manifestRows = try await repository.reconciliationRows(
            jobID: removedJob.id,
            direction: .upload,
            localGeneration: 1,
            remoteGeneration: 1,
            localCaseSensitive: true,
            after: nil,
            limit: 10
        )
        try check(manifestRows.isEmpty, "A removed sync left manifest rows")
    }

    /// The credential store: adopting what earlier builds saved, sharing one
    /// set of keys between syncs, and the two directions in which that sharing
    /// can go wrong — deleting keys a sync still needs, or leaving a sync
    /// pointed at keys that are not there.
    ///
    /// Keychain writes go to a service name unique to this run and are removed
    /// afterwards, including when a check fails part-way through.
    private func credentialStoreCheck() async throws {
        try check(
            StoredCredential.summary(forAccessKeyID: "AKIAIOSFODNN7EXAMPLE") == "AKIA…MPLE",
            "A saved access key was not shortened the way it is displayed"
        )
        try check(
            StoredCredential.summary(forAccessKeyID: "short") == nil,
            "A key too short to shorten was shown anyway"
        )
        try check(
            StoredCredential.uniqueName("Amazon S3", avoiding: ["Amazon S3", "Amazon S3 2"]) == "Amazon S3 3",
            "Adopted credentials took a name that was already in use"
        )
        try check(
            StoredCredential.uniqueName("Amazon S3", avoiding: ["Other"]) == "Amazon S3",
            "An unused name was needlessly numbered"
        )

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = KeychainStore(service: "app.photosync.tests." + UUID().uuidString)
        let written = KeychainReferenceBox()
        do {
            try await credentialStoreDurabilityCheck(
                directory: directory,
                keychain: keychain,
                written: written
            )
        } catch {
            await written.purge(from: keychain)
            throw error
        }
        await written.purge(from: keychain)
    }

    private func credentialStoreDurabilityCheck(
        directory: URL,
        keychain: KeychainStore,
        written: KeychainReferenceBox
    ) async throws {
        let repository = try SyncRepository(databaseURL: directory.appendingPathComponent("credentials.sqlite"))
        let bookmarks = try BookmarkStore(directory: directory.appendingPathComponent("bookmarks"))
        let coordinator = SyncCoordinator(repository: repository, bookmarks: bookmarks, keychain: keychain)

        // What a build from before the credential store leaves behind: keys in
        // the Keychain under the connection's own identifier, and no record of
        // them anywhere else. The jobs are paused so this check exercises
        // configuration rather than scheduling.
        let legacyConnectionID = ConnectionID()
        let legacyReference = legacyConnectionID.description
        written.add(legacyReference)
        try await keychain.save(
            S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "original-secret"),
            reference: legacyReference
        )
        let legacyConnection = S3Connection(
            id: legacyConnectionID,
            name: "Amazon S3",
            endpoint: URL(string: "https://s3.eu-north-1.amazonaws.com")!,
            region: "eu-north-1",
            bucket: "legacy-bucket",
            credentialReference: legacyReference
        )
        try await repository.saveConnection(legacyConnection)
        let legacyJob = SyncJob(
            name: "Photos",
            direction: .upload,
            localRoot: LocalRoot(displayName: "Photos", fallbackPath: "/photos", bookmarkReference: "photos"),
            connectionID: legacyConnectionID,
            remotePrefix: "photos",
            isPaused: true
        )
        try await repository.saveJob(legacyJob)

        try await coordinator.start()
        let adopted = try await coordinator.credentials()
        try check(adopted.count == 1, "Upgrading did not adopt the credentials an existing sync was using")
        guard let credential = adopted.first else {
            throw CheckFailure.failed("Upgrading adopted no credentials at all")
        }
        try check(
            credential.keychainReference == legacyReference,
            "Adoption moved the Keychain reference a running sync resolves"
        )
        try check(
            credential.name == "Amazon S3 (legacy-bucket)",
            "An adopted credential was not named after the connection it came from"
        )
        try check(
            credential.accessKeySummary == "AKIA…MPLE",
            "An adopted credential did not record its shortened access key"
        )
        let secretAfterAdoption = try await keychain.load(reference: legacyReference)
        try check(
            secretAfterAdoption?.secretAccessKey == "original-secret",
            "Adoption rewrote the secret it was only supposed to describe"
        )

        try await coordinator.start()
        let afterSecondLaunch = try await coordinator.credentials()
        try check(afterSecondLaunch.count == 1, "A second launch adopted the same credentials again")

        // A second sync reusing them, which is the whole point of the store.
        let secondConnectionID = ConnectionID()
        let secondConnection = S3Connection(
            id: secondConnectionID,
            name: "Amazon S3",
            endpoint: URL(string: "https://s3.eu-north-1.amazonaws.com")!,
            region: "eu-north-1",
            bucket: "second-bucket",
            credentialReference: credential.keychainReference
        )
        try await coordinator.save(connection: secondConnection)
        let secondJob = SyncJob(
            name: "Archive",
            direction: .upload,
            localRoot: LocalRoot(displayName: "Archive", fallbackPath: "/archive", bookmarkReference: "archive"),
            connectionID: secondConnectionID,
            remotePrefix: "archive",
            isPaused: true
        )
        try await repository.saveJob(secondJob)

        var acceptedDanglingReference = true
        do {
            try await coordinator.save(
                connection: S3Connection(
                    name: "Nowhere",
                    endpoint: URL(string: "https://s3.eu-north-1.amazonaws.com")!,
                    region: "eu-north-1",
                    bucket: "nowhere",
                    credentialReference: "credential." + UUID().uuidString
                )
            )
        } catch {
            acceptedDanglingReference = false
        }
        try check(!acceptedDanglingReference, "A sync was pointed at credentials that are not in the Keychain")

        var deletedWhileInUse = true
        do {
            try await coordinator.removeCredential(id: credential.id)
        } catch {
            deletedWhileInUse = false
        }
        try check(!deletedWhileInUse, "Credentials two syncs depend on were deleted anyway")
        let keysAfterRefusedDeletion = try await keychain.contains(reference: credential.keychainReference)
        try check(keysAfterRefusedDeletion, "A refused deletion removed the keys regardless")

        // The regression this store introduces the risk of: removing a sync
        // used to delete the Keychain item its connection pointed at, which
        // would now take another sync's keys with it.
        try await coordinator.remove(jobID: legacyJob.id)
        let keysAfterJobRemoval = try await keychain.contains(reference: credential.keychainReference)
        let credentialsAfterJobRemoval = try await coordinator.credentials()
        try check(
            keysAfterJobRemoval,
            "Removing one sync deleted saved credentials another sync is still using"
        )
        try check(
            credentialsAfterJobRemoval.count == 1,
            "Removing a sync removed the saved credentials themselves"
        )

        // And they outlive the last sync too: they are the user's, listed and
        // deleted in one place, not owned by whichever sync happened to use
        // them.
        try await coordinator.remove(jobID: secondJob.id)
        let keysAfterLastJobRemoval = try await keychain.contains(reference: credential.keychainReference)
        try check(
            keysAfterLastJobRemoval,
            "Removing the last sync deleted credentials that are still listed"
        )

        try await coordinator.removeCredential(id: credential.id)
        let remainingCredentials = try await coordinator.credentials()
        let keysAfterDeletion = try await keychain.contains(reference: credential.keychainReference)
        try check(remainingCredentials.isEmpty, "Deleting credentials left them in the list")
        try check(!keysAfterDeletion, "Deleting credentials left their keys in the Keychain")

        // Naming, renaming, and replacing keys.
        let personal = try await coordinator.saveCredential(
            id: nil,
            name: "Personal AWS",
            credentials: S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "first-secret")
        )
        written.add(personal.keychainReference)
        var acceptedDuplicateName = true
        do {
            _ = try await coordinator.saveCredential(
                id: nil,
                name: "  personal aws  ",
                credentials: S3Credentials(accessKeyID: "AKIAIOSFODNN7OTHER00", secretAccessKey: "other")
            )
        } catch {
            acceptedDuplicateName = false
        }
        try check(!acceptedDuplicateName, "Two sets of credentials were saved under the same name")

        let renamed = try await coordinator.saveCredential(id: personal.id, name: "Work", credentials: nil)
        try check(
            renamed.keychainReference == personal.keychainReference,
            "Renaming credentials moved the Keychain item every sync resolves"
        )
        let secretAfterRename = try await keychain.load(reference: personal.keychainReference)
        try check(
            secretAfterRename?.secretAccessKey == "first-secret",
            "Renaming credentials changed the keys inside them"
        )
        // Dates round-trip through SQLite at millisecond resolution, so this
        // asks whether the timestamp was left alone rather than for an exact
        // match against an in-memory Date.
        try check(
            abs(renamed.keysUpdatedAt.timeIntervalSince(personal.keysUpdatedAt)) < 0.01,
            "Renaming credentials claimed their keys had been replaced"
        )

        let replaced = try await coordinator.saveCredential(
            id: personal.id,
            name: "Work",
            credentials: S3Credentials(
                accessKeyID: "ASIAIOSFODNN7EXAMPLE",
                secretAccessKey: "second-secret",
                sessionToken: "temporary"
            )
        )
        try check(replaced.accessKeySummary == "ASIA…MPLE", "Replaced keys kept the old shortened access key")
        try check(replaced.hasSessionToken, "Temporary credentials were not recorded as temporary")
        let secretAfterReplacement = try await keychain.load(reference: personal.keychainReference)
        try check(
            secretAfterReplacement?.secretAccessKey == "second-secret",
            "Replacing keys did not reach the Keychain"
        )

        await coordinator.stop()
    }

    private func gracefulUnmountPreparationCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SyncRepository(databaseURL: directory.appendingPathComponent("unmount.sqlite"))
        let bookmarkStore = try BookmarkStore(directory: directory.appendingPathComponent("bookmarks"))
        let coordinator = SyncCoordinator(
            repository: repository,
            bookmarks: bookmarkStore,
            keychain: KeychainStore(service: "app.photosync.tests." + UUID().uuidString)
        )
        let connectionID = ConnectionID()
        let externalJob = SyncJob(
            name: "External",
            direction: .download,
            localRoot: LocalRoot(
                displayName: "External",
                fallbackPath: "/Volumes/Test Disk/Restore",
                bookmarkReference: "external"
            ),
            connectionID: connectionID,
            remotePrefix: "restore"
        )
        let internalJob = SyncJob(
            name: "Internal",
            direction: .upload,
            localRoot: LocalRoot(
                displayName: "Internal",
                fallbackPath: "/Users/test/Pictures",
                bookmarkReference: "internal"
            ),
            connectionID: connectionID,
            remotePrefix: "pictures"
        )
        try await repository.saveJob(externalJob)
        try await repository.saveJob(internalJob)
        try await repository.setSnapshot(
            SyncSnapshot(jobID: internalJob.id, phase: .watching, message: "All caught up")
        )

        let prepared = await coordinator.prepareForVolumeUnmount(
            at: URL(fileURLWithPath: "/Volumes/Test Disk", isDirectory: true)
        )
        let externalSnapshot = try await repository.snapshot(jobID: externalJob.id)
        let internalSnapshot = try await repository.snapshot(jobID: internalJob.id)
        try check(prepared, "StorageSync declined a normal external-volume unmount without a state error")
        try check(
            externalSnapshot?.blockers == [.localVolumeUnavailable],
            "Graceful unmount preparation did not suspend the affected sync"
        )
        try check(
            internalSnapshot?.message == "All caught up",
            "Graceful unmount preparation disturbed a job on another volume"
        )
        await coordinator.stop()
    }

    private func processCrashRecoveryCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("crash-state.sqlite")
        let transferID = UUID()
        let process = Process()
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--write-running-transfer", databaseURL.path, transferID.uuidString]
        try process.run()
        process.waitUntilExit()
        try check(process.terminationStatus == 17, "The crash fixture did not terminate at the intended checkpoint")

        let repository = try SyncRepository(databaseURL: databaseURL)
        let recovered = try await repository.transfer(id: TransferID(rawValue: transferID))
        try check(recovered?.status == .waiting, "An abruptly terminated process did not recover its running transfer")
    }

    private func multipartLostResponseCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        let source = fixture.root.appendingPathComponent("large.bin")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "large.bin")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "large.bin",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/large.bin"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.failOnceAfterAcceptingPart(2)
        let executor = fixture.executor()
        let first = await executor.execute(transfer, job: fixture.job, root: fixture.root)
        guard case .waiting(.networkUnavailable, _) = first else {
            throw CheckFailure.failed("A lost multipart response did not enter network waiting state")
        }
        guard let checkpoint = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The multipart checkpoint was not saved")
        }
        try check(
            checkpoint.multipartUploadID != nil,
            "The provider's multipart upload ID was not durably recorded, so a resume would restart the object"
        )
        await fixture.store.disableFailures()
        let second = await executor.execute(checkpoint, job: fixture.job, root: fixture.root)
        guard case .completed = second else {
            throw CheckFailure.failed("Multipart upload did not resume to completion: \(second)")
        }
        let uploaded = await fixture.store.data(for: "backup/large.bin")
        let partTwoUploads = await fixture.store.uploadCount(partNumber: 2)
        try check(uploaded == payload, "Resumed multipart data did not match its source")
        try check(partTwoUploads == 1, "An accepted multipart part was uploaded twice")
    }

    private func rangedDownloadResumeCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let payload = Data("a resumable remote video payload".utf8)
        let remote = await fixture.store.seed(key: "restore/video.mov", data: payload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "video.mov",
            kind: .download,
            totalBytes: Int64(payload.count),
            remoteSource: remote,
            remoteKey: remote.key
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.failOnceOnRangeCall(2)
        let executor = fixture.executor()
        let first = await executor.execute(transfer, job: fixture.job, root: fixture.root)
        guard case .waiting(.networkUnavailable, _) = first else {
            throw CheckFailure.failed("A ranged download interruption did not enter network waiting state: \(first)")
        }
        let parts = try await fixture.repository.parts(transferID: transfer.id)
        try check(parts.filter(\.isComplete).count == 1, "The completed download range was not checkpointed")
        if let partialPath = try await fixture.repository.transfer(id: transfer.id)?.temporaryPath {
            let partialURL = URL(fileURLWithPath: partialPath)
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data([0xff]))
            try handle.close()
        } else {
            throw CheckFailure.failed("The partial download path was not checkpointed")
        }
        guard let checkpoint = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The ranged download checkpoint was not saved")
        }
        await fixture.store.disableFailures()
        let second = await executor.execute(checkpoint, job: fixture.job, root: fixture.root)
        guard case .completed = second else {
            throw CheckFailure.failed("The ranged download did not resume to completion: \(second)")
        }
        try check(try Data(contentsOf: fixture.root.appendingPathComponent("video.mov")) == payload, "The resumed download data was corrupted")
    }

    private func outOfOrderRangedDownloadResumeCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let payload = Data("01234567abcdefghABCDEFGH".utf8)
        let remote = await fixture.store.seed(key: "restore/out-of-order.mov", data: payload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "out-of-order.mov",
            kind: .download,
            status: .waiting,
            totalBytes: Int64(payload.count),
            completedBytes: 8,
            remoteSource: remote,
            remoteKey: remote.key
        )
        let partialDirectory = fixture.root.appendingPathComponent(".storagesync-partials", isDirectory: true)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let partialURL = partialDirectory.appendingPathComponent(transfer.id.description + ".partial")
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw CheckFailure.failed("Could not create the out-of-order range fixture")
        }
        let partTwoData = payload.subdata(in: 8..<16)
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.seek(toOffset: 8)
        try handle.write(contentsOf: partTwoData)
        try handle.synchronize()
        try handle.close()

        var checkpointedTransfer = transfer
        checkpointedTransfer.temporaryPath = partialURL.path
        try await fixture.repository.saveTransfer(checkpointedTransfer)
        try await fixture.repository.savePart(
            TransferPart(
                transferID: transfer.id,
                number: 2,
                offset: 8,
                length: 8,
                checksum: SHA256.hash(data: partTwoData).map { String(format: "%02x", $0) }.joined(),
                isComplete: true
            )
        )

        let result = await fixture.executor(maxConcurrentParts: 2).execute(
            checkpointedTransfer,
            job: fixture.job,
            root: fixture.root
        )
        guard case .completed = result else {
            throw CheckFailure.failed("An out-of-order ranged checkpoint did not resume: \(result)")
        }
        let requestedPartOne = await fixture.store.rangeRequestCount(0..<8)
        let requestedPartTwo = await fixture.store.rangeRequestCount(8..<16)
        let requestedPartThree = await fixture.store.rangeRequestCount(16..<24)
        try check(requestedPartOne == 1, "The missing first range was not downloaded exactly once")
        try check(requestedPartTwo == 0, "A valid out-of-order range was downloaded again")
        try check(requestedPartThree == 1, "The missing final range was not downloaded exactly once")
        try check(
            try Data(contentsOf: fixture.root.appendingPathComponent("out-of-order.mov")) == payload,
            "Reusing an out-of-order range corrupted the final download"
        )
    }

    private func downloadRequiresStableRemoteIdentityCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let payload = Data("provider-must-identify-object-versions".utf8)
        let remote = await fixture.store.seed(key: "restore/unverifiable.mov", data: payload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "unverifiable.mov",
            kind: .download,
            totalBytes: Int64(payload.count),
            remoteSource: remote,
            remoteKey: remote.key
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.omitRemoteIdentity(true)
        let result = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .attention = result else {
            throw CheckFailure.failed("A provider with no stable remote object identity was trusted: \(result)")
        }
        try check(
            !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unverifiable.mov").path),
            "An unverifiable remote object was committed locally"
        )
    }

    private func multipartCompletionLostResponseCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data("complete-response-can-disappear".utf8)
        let source = fixture.root.appendingPathComponent("completion.bin")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "completion.bin")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "completion.bin",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/completion.bin"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.failOnceAfterCompletingUpload()
        let executor = fixture.executor()
        let first = await executor.execute(transfer, job: fixture.job, root: fixture.root)
        guard case .waiting(.networkUnavailable, _) = first else {
            throw CheckFailure.failed("A lost completion response did not enter network waiting state")
        }
        guard let checkpoint = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The completion checkpoint was not saved")
        }
        await fixture.store.disableFailures()
        let second = await executor.execute(checkpoint, job: fixture.job, root: fixture.root)
        guard case .completed = second else {
            throw CheckFailure.failed("A remotely completed upload was not reconciled: \(second)")
        }
        let completions = await fixture.store.completionCount()
        try check(completions == 1, "The multipart completion request was repeated")
    }

    private func expiredMultipartUploadCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data("provider-expired-the-multipart-upload".utf8)
        let source = fixture.root.appendingPathComponent("expired.bin")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "expired.bin")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "expired.bin",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/expired.bin"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.failOnceAfterAcceptingPart(2)
        let first = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .waiting = first else {
            throw CheckFailure.failed("The multipart expiration fixture did not checkpoint first")
        }
        await fixture.store.expireMultipartUploads()
        await fixture.store.disableFailures()
        guard let checkpoint = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The expired multipart checkpoint was not saved")
        }
        let second = await fixture.executor().execute(checkpoint, job: fixture.job, root: fixture.root)
        guard case .completed = second else {
            throw CheckFailure.failed("An expired provider multipart upload was not restarted: \(second)")
        }
        let uploaded = await fixture.store.data(for: transfer.remoteKey)
        try check(uploaded == payload, "Restarting an expired multipart upload corrupted the object")
    }

    private func parallelMultipartCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data(repeating: 0x2a, count: 80)
        let source = fixture.root.appendingPathComponent("parallel.bin")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "parallel.bin")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "parallel.bin",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/parallel.bin"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.delayUploadParts(by: .milliseconds(20))
        let result = await fixture.executor(maxConcurrentParts: 3).execute(transfer, job: fixture.job, root: fixture.root)
        guard case .completed = result else {
            throw CheckFailure.failed("Parallel multipart upload failed: \(result)")
        }
        let maximumInFlight = await fixture.store.maximumObservedPartUploads()
        try check(maximumInFlight >= 2 && maximumInFlight <= 3, "Multipart part concurrency was not bounded and parallel")
    }

    private func cancellationResumeCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data(repeating: 0x31, count: 40)
        let source = fixture.root.appendingPathComponent("pausable.bin")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "pausable.bin")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "pausable.bin",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/pausable.bin"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.delayUploadParts(by: .seconds(30))
        let executor = fixture.executor()
        let task = Task { await executor.execute(transfer, job: fixture.job, root: fixture.root) }
        var beganPartUpload = false
        for _ in 0..<1_000 {
            if await fixture.store.currentPartUploads() > 0 {
                beganPartUpload = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try check(beganPartUpload, "The cancellation fixture never entered an in-flight part upload")
        task.cancel()
        let cancelled = await task.value
        guard case .cancelled = cancelled else {
            throw CheckFailure.failed("Cancelling an in-flight upload was misclassified: \(cancelled)")
        }
        guard let deferred = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The cancelled transfer checkpoint was not saved")
        }
        try check(deferred.status == .waiting && deferred.lastError == nil, "Cancellation was recorded as a network or file failure")

        await fixture.store.delayUploadParts(by: nil)
        let resumed = await executor.execute(deferred, job: fixture.job, root: fixture.root)
        guard case .completed = resumed else {
            throw CheckFailure.failed("A cancelled upload did not resume: \(resumed)")
        }
    }

    private func sourceMutationCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data("source-mutation-must-never-complete".utf8)
        let replacement = Data(repeating: 0x5a, count: payload.count + 1)
        let source = fixture.root.appendingPathComponent("changing.bin")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "changing.bin")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "changing.bin",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/changing.bin"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.mutateSourceAfterAcceptingPart(1, url: source, replacement: replacement)

        let result = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .superseded(let notice) = result, notice != nil else {
            throw CheckFailure.failed("A source mutation was not detected: \(result)")
        }
        let committedData = await fixture.store.data(for: transfer.remoteKey)
        let activeUploads = await fixture.store.activeUploadCount()
        try check(committedData == nil, "A mixed-version multipart object was committed")
        try check(activeUploads == 0, "A superseded multipart upload was not aborted")
    }

    private func uploadVolumeDisappearanceCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data("external-drive-upload-resumes-by-parts".utf8)
        let source = fixture.root.appendingPathComponent("camera.raw")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "camera.raw")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "camera.raw",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/camera.raw"
        )
        try await fixture.repository.saveTransfer(transfer)
        let detached = fixture.directory.appendingPathComponent("detached-volume")
        await fixture.store.detachRootAfterAcceptingPart(1, root: fixture.root, detached: detached)

        let first = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .waiting(.localVolumeUnavailable, _) = first else {
            throw CheckFailure.failed("A disappearing upload volume did not enter local-volume waiting state: \(first)")
        }
        try FileManager.default.moveItem(at: detached, to: fixture.root)
        guard var checkpoint = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The disconnected upload checkpoint was not saved")
        }
        checkpoint.sourceFingerprint?.fileIdentifier = "identifier-from-the-previous-mount"
        let second = await fixture.executor().execute(checkpoint, job: fixture.job, root: fixture.root)
        guard case .completed = second else {
            throw CheckFailure.failed("Upload did not resume after the external volume returned: \(second)")
        }
        let uploaded = await fixture.store.data(for: transfer.remoteKey)
        let firstPartUploadCount = await fixture.store.uploadCount(partNumber: 1)
        try check(uploaded == payload, "The resumed external-volume upload was corrupted")
        try check(firstPartUploadCount == 1, "A checkpointed upload part was sent twice after reconnection")
    }

    private func downloadRemountFingerprintCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("existing.jpg")
        try Data("old-local-version".utf8).write(to: destination)
        var plannedLocal = try LocalScanner().fingerprint(
            url: destination,
            relativePath: "existing.jpg"
        )
        plannedLocal.fileIdentifier = "identifier-from-the-previous-mount"
        let remotePayload = Data("new-remote-version".utf8)
        let remote = await fixture.store.seed(key: "restore/existing.jpg", data: remotePayload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "existing.jpg",
            kind: .download,
            totalBytes: Int64(remotePayload.count),
            sourceFingerprint: plannedLocal,
            remoteSource: remote,
            remoteKey: remote.key
        )
        try await fixture.repository.saveTransfer(transfer)
        let result = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .completed = result else {
            throw CheckFailure.failed("An unchanged download destination was rejected after a simulated remount: \(result)")
        }
        try check(
            try Data(contentsOf: destination) == remotePayload,
            "The remount-safe download did not commit the planned remote version"
        )
    }

    private func sourceDeletionCheck() async throws {
        let fixture = try Fixture.make(direction: .upload)
        defer { fixture.cleanup() }
        let payload = Data("source-can-be-deleted-during-upload".utf8)
        let source = fixture.root.appendingPathComponent("deleted.raw")
        try payload.write(to: source)
        let fingerprint = try LocalScanner().fingerprint(url: source, relativePath: "deleted.raw")
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "deleted.raw",
            kind: .upload,
            totalBytes: Int64(payload.count),
            sourceFingerprint: fingerprint,
            remoteKey: "backup/deleted.raw"
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.removeSourceAfterAcceptingPart(1, url: source)
        let result = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .superseded(let notice) = result, notice != nil else {
            throw CheckFailure.failed("Deleting a source file was mistaken for a disconnected volume: \(result)")
        }
        let committed = await fixture.store.data(for: transfer.remoteKey)
        try check(committed == nil, "A multipart object was committed after its source disappeared")
    }

    private func downloadVolumeDisappearanceCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let payload = Data("external-drive-download-recovers-a-missing-partial".utf8)
        let remote = await fixture.store.seed(key: "restore/archive.mov", data: payload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "archive.mov",
            kind: .download,
            totalBytes: Int64(payload.count),
            remoteSource: remote,
            remoteKey: remote.key
        )
        try await fixture.repository.saveTransfer(transfer)
        let detached = fixture.directory.appendingPathComponent("detached-download-volume")
        await fixture.store.detachRootOnRangeCall(2, root: fixture.root, detached: detached)

        let first = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .waiting(.localVolumeUnavailable, _) = first else {
            throw CheckFailure.failed("A disappearing download volume did not enter local-volume waiting state: \(first)")
        }
        try FileManager.default.removeItem(at: detached)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        guard let checkpoint = try await fixture.repository.transfer(id: transfer.id) else {
            throw CheckFailure.failed("The disconnected download checkpoint was not saved")
        }
        let second = await fixture.executor().execute(checkpoint, job: fixture.job, root: fixture.root)
        guard case .completed = second else {
            throw CheckFailure.failed("Download did not recover after its partial file disappeared: \(second)")
        }
        try check(try Data(contentsOf: fixture.root.appendingPathComponent("archive.mov")) == payload, "The recovered external-volume download was corrupted")
    }

    private func localDestinationMutationCheck() async throws {
        let fixture = try Fixture.make(direction: .download)
        defer { fixture.cleanup() }
        let remotePayload = Data("remote-photo".utf8)
        let localPayload = Data("new-local-photo".utf8)
        let destination = fixture.root.appendingPathComponent("edited.jpg")
        let remote = await fixture.store.seed(key: "restore/edited.jpg", data: remotePayload)
        let transfer = TransferRecord(
            jobID: fixture.job.id,
            relativePath: "edited.jpg",
            kind: .download,
            totalBytes: Int64(remotePayload.count),
            sourceFingerprint: nil,
            remoteSource: remote,
            remoteKey: remote.key
        )
        try await fixture.repository.saveTransfer(transfer)
        await fixture.store.writeLocalFileOnHeadCall(2, url: destination, data: localPayload)
        let result = await fixture.executor().execute(transfer, job: fixture.job, root: fixture.root)
        guard case .superseded = result else {
            throw CheckFailure.failed("A local file created during download was overwritten: \(result)")
        }
        try check(try Data(contentsOf: destination) == localPayload, "The locally created file was not preserved")
    }

    private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CheckFailure.failed(message) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("storagesync-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct Fixture: @unchecked Sendable {
    let directory: URL
    let root: URL
    let repository: SyncRepository
    let store: FaultInjectingObjectStore
    let job: SyncJob

    static func make(direction: SyncDirection) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("storagesync-tests-" + UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try SyncRepository(databaseURL: directory.appendingPathComponent("state.sqlite"))
        let job = SyncJob(
            name: "Test",
            direction: direction,
            localRoot: LocalRoot(displayName: "volume", fallbackPath: root.path, bookmarkReference: "test"),
            connectionID: ConnectionID(),
            remotePrefix: direction == .upload ? "backup" : "restore"
        )
        return Fixture(directory: directory, root: root, repository: repository, store: FaultInjectingObjectStore(), job: job)
    }

    func executor(maxConcurrentParts: Int = 1) -> TransferExecutor {
        TransferExecutor(
            repository: repository,
            objectStore: store,
            transferPolicy: TransferPolicy(
                multipartThreshold: 1,
                preferredPartSize: 8,
                maximumPartCount: 10_000,
                maximumPartSize: 1_024,
                maximumConcurrentFiles: 1,
                maximumConcurrentPartsPerFile: maxConcurrentParts
            ),
            retryPolicy: RetryPolicy(baseDelay: .zero, maximumDelay: .zero, maximumAttempts: 5)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private actor FaultInjectingObjectStore: ObjectStore {
    private struct StoredObject { var data: Data; var metadata: [String: String]; var eTag: String }
    private struct Upload {
        var key: String
        var metadata: [String: String]
        var parts: [Int: Data] = [:]
        var counts: [Int: Int] = [:]
    }

    private var objects: [String: StoredObject] = [:]
    private var uploads: [String: Upload] = [:]
    private var partFailure: Int?
    private var rangeFailureCall: Int?
    private var didFail = false
    private var rangeCalls = 0
    private var requestedRanges: [Range<Int64>?] = []
    private var shouldOmitRemoteIdentity = false
    private var failCompletion = false
    private var completions = 0
    private var totalPartUploads: [Int: Int] = [:]
    private var sourceMutation: (part: Int, url: URL, replacement: Data)?
    private var sourceRemoval: (part: Int, url: URL)?
    private var uploadDetachment: (part: Int, root: URL, detached: URL)?
    private var rangeDetachment: (call: Int, root: URL, detached: URL)?
    private var didMutateSource = false
    private var didDetachUpload = false
    private var didDetachRange = false
    private var uploadPartDelay: Duration?
    private var inFlightPartUploads = 0
    private var maximumInFlightPartUploads = 0
    private var headCalls = 0
    private var localWriteOnHead: (call: Int, url: URL, data: Data)?

    func failOnceAfterAcceptingPart(_ number: Int) { partFailure = number; didFail = false }
    func failOnceOnRangeCall(_ number: Int) { rangeFailureCall = number; didFail = false }
    func failOnceAfterCompletingUpload() { failCompletion = true; didFail = false }
    func expireMultipartUploads() { uploads.removeAll() }
    func delayUploadParts(by delay: Duration?) { uploadPartDelay = delay }
    func omitRemoteIdentity(_ value: Bool) { shouldOmitRemoteIdentity = value }
    func currentPartUploads() -> Int { inFlightPartUploads }
    func maximumObservedPartUploads() -> Int { maximumInFlightPartUploads }
    func writeLocalFileOnHeadCall(_ call: Int, url: URL, data: Data) {
        localWriteOnHead = (call, url, data)
    }
    func mutateSourceAfterAcceptingPart(_ part: Int, url: URL, replacement: Data) {
        sourceMutation = (part, url, replacement)
        didMutateSource = false
    }
    func removeSourceAfterAcceptingPart(_ part: Int, url: URL) {
        sourceRemoval = (part, url)
        didMutateSource = false
    }
    func detachRootAfterAcceptingPart(_ part: Int, root: URL, detached: URL) {
        uploadDetachment = (part, root, detached)
        didDetachUpload = false
    }
    func detachRootOnRangeCall(_ call: Int, root: URL, detached: URL) {
        rangeDetachment = (call, root, detached)
        didDetachRange = false
    }
    func disableFailures() {
        partFailure = nil
        rangeFailureCall = nil
        failCompletion = false
        sourceMutation = nil
        sourceRemoval = nil
        uploadDetachment = nil
        rangeDetachment = nil
        didFail = false
    }

    func seed(key: String, data: Data) -> RemoteObject {
        let eTag = hash(data)
        objects[key] = StoredObject(data: data, metadata: [:], eTag: eTag)
        return RemoteObject(key: key, size: Int64(data.count), eTag: eTag)
    }

    func data(for key: String) -> Data? { objects[key]?.data }
    func uploadCount(partNumber: Int) -> Int { totalPartUploads[partNumber, default: 0] }
    func completionCount() -> Int { completions }
    func activeUploadCount() -> Int { uploads.count }
    func rangeRequestCount(_ range: Range<Int64>) -> Int {
        requestedRanges.compactMap { $0 }.filter { $0 == range }.count
    }

    func list(prefix: String, continuationToken: String?) async throws -> ObjectPage {
        ObjectPage(objects: objects.keys.sorted().filter { $0.hasPrefix(prefix) }.compactMap(remoteObject), nextContinuationToken: nil)
    }

    func head(key: String) async throws -> RemoteObject? {
        headCalls += 1
        if let localWriteOnHead, localWriteOnHead.call == headCalls {
            try localWriteOnHead.data.write(to: localWriteOnHead.url)
            self.localWriteOnHead = nil
        }
        return remoteObject(key)
    }

    func put(key: String, data: Data, metadata: [String: String]) async throws -> RemoteObject {
        objects[key] = StoredObject(data: data, metadata: metadata, eTag: hash(data))
        return remoteObject(key)!
    }

    func createMultipartUpload(key: String, metadata: [String: String]) async throws -> String {
        let id = UUID().uuidString
        uploads[id] = Upload(key: key, metadata: metadata)
        return id
    }

    func uploadPart(key: String, uploadID: String, partNumber: Int, data: Data) async throws -> UploadedPart {
        if let uploadPartDelay {
            inFlightPartUploads += 1
            maximumInFlightPartUploads = max(maximumInFlightPartUploads, inFlightPartUploads)
            do {
                try await Task.sleep(for: uploadPartDelay)
                inFlightPartUploads -= 1
            } catch {
                inFlightPartUploads -= 1
                throw error
            }
        }
        guard var upload = uploads[uploadID], upload.key == key else { throw ObjectStoreError.notFound }
        upload.parts[partNumber] = data
        upload.counts[partNumber, default: 0] += 1
        totalPartUploads[partNumber, default: 0] += 1
        uploads[uploadID] = upload
        if let sourceMutation, sourceMutation.part == partNumber, !didMutateSource {
            didMutateSource = true
            try sourceMutation.replacement.write(to: sourceMutation.url)
        }
        if let sourceRemoval, sourceRemoval.part == partNumber, !didMutateSource {
            didMutateSource = true
            try FileManager.default.removeItem(at: sourceRemoval.url)
        }
        if let uploadDetachment, uploadDetachment.part == partNumber, !didDetachUpload {
            didDetachUpload = true
            try FileManager.default.moveItem(at: uploadDetachment.root, to: uploadDetachment.detached)
        }
        if partFailure == partNumber, !didFail {
            didFail = true
            throw ObjectStoreError.transient("Injected lost response")
        }
        return UploadedPart(number: partNumber, eTag: hash(data), size: Int64(data.count))
    }

    func listParts(key: String, uploadID: String) async throws -> [UploadedPart] {
        guard let upload = uploads[uploadID], upload.key == key else { throw ObjectStoreError.notFound }
        return upload.parts.map { number, data in UploadedPart(number: number, eTag: hash(data), size: Int64(data.count)) }
            .sorted { $0.number < $1.number }
    }

    func completeMultipartUpload(key: String, uploadID: String, parts: [UploadedPart]) async throws -> RemoteObject {
        guard let upload = uploads[uploadID], upload.key == key else { throw ObjectStoreError.notFound }
        let data = parts.sorted { $0.number < $1.number }.reduce(into: Data()) { result, part in
            result.append(upload.parts[part.number] ?? Data())
        }
        objects[key] = StoredObject(data: data, metadata: upload.metadata, eTag: hash(data))
        completions += 1
        if failCompletion, !didFail {
            didFail = true
            throw ObjectStoreError.transient("Injected lost completion response")
        }
        return remoteObject(key)!
    }

    func abortMultipartUpload(key: String, uploadID: String) async throws { uploads.removeValue(forKey: uploadID) }

    func getRange(key: String, range: Range<Int64>?) async throws -> Data {
        guard let object = objects[key] else { throw ObjectStoreError.notFound }
        rangeCalls += 1
        requestedRanges.append(range)
        if let rangeDetachment, rangeDetachment.call == rangeCalls, !didDetachRange {
            didDetachRange = true
            try FileManager.default.moveItem(at: rangeDetachment.root, to: rangeDetachment.detached)
        }
        if rangeFailureCall == rangeCalls, !didFail {
            didFail = true
            throw ObjectStoreError.transient("Injected range failure")
        }
        guard let range else { return object.data }
        return object.data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    private func remoteObject(_ key: String) -> RemoteObject? {
        guard let object = objects[key] else { return nil }
        return RemoteObject(
            key: key,
            size: Int64(object.data.count),
            eTag: shouldOmitRemoteIdentity ? nil : object.eTag,
            metadata: object.metadata
        )
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
