import Foundation
import StorageSyncCore

public final class S3ObjectStore: ObjectStore, @unchecked Sendable {
    private let configuration: S3ClientConfiguration
    private let session: URLSession
    private let signer: SigV4Signer

    public init(configuration: S3ClientConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        signer = SigV4Signer()
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
            // A single dynamically sized part can take hours on a slow uplink.
            // The request timeout still detects an idle connection, while the
            // resource timeout permits forward progress on multi-day jobs.
            sessionConfiguration.timeoutIntervalForResource = max(configuration.timeout, 24 * 60 * 60)
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.httpMaximumConnectionsPerHost = 8
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    public func list(prefix: String, continuationToken: String?) async throws -> ObjectPage {
        var query = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: "1000")
        ]
        if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let continuationToken {
            query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
        }
        let response = try await send(method: "GET", key: nil, query: query)
        let parsed = try S3XML.parseObjects(response.data)
        // Callers page by following the token until it is nil, so the token is
        // reported only for a page that actually says there is more. A provider
        // that echoes a token on its final page would otherwise be listed
        // forever, and one that truncates without a usable token would silently
        // hand back a partial manifest — which reconciliation would read as the
        // whole bucket.
        guard parsed.isTruncated else {
            return ObjectPage(objects: parsed.objects, nextContinuationToken: nil)
        }
        guard let next = parsed.nextContinuationToken,
              !next.isEmpty,
              next != continuationToken else {
            throw ObjectStoreError.invalidResponse(
                "The S3 service returned a truncated object listing without a usable continuation token."
            )
        }
        return ObjectPage(objects: parsed.objects, nextContinuationToken: next)
    }

    public func head(key: String) async throws -> RemoteObject? {
        do {
            let response = try await send(method: "HEAD", key: key)
            return remoteObject(key: key, response: response.response)
        } catch ObjectStoreError.notFound {
            return nil
        }
    }

    public func put(key: String, data: Data, metadata: [String: String]) async throws -> RemoteObject {
        try await put(key: key, data: data, metadata: metadata, progress: { _ in })
    }

    public func put(
        key: String,
        data: Data,
        metadata: [String: String],
        progress: @escaping UploadProgressHandler
    ) async throws -> RemoteObject {
        let response = try await send(
            method: "PUT",
            key: key,
            headers: metadataHeaders(metadata),
            body: data,
            uploadProgress: progress
        )
        return remoteObject(key: key, response: response.response, authoritativeSize: Int64(data.count))
    }

    public func createMultipartUpload(key: String, metadata: [String: String]) async throws -> String {
        let response = try await send(
            method: "POST",
            key: key,
            query: [URLQueryItem(name: "uploads", value: nil)],
            headers: metadataHeaders(metadata)
        )
        return try S3XML.parseUploadID(response.data).uploadID
    }

    public func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        data: Data
    ) async throws -> UploadedPart {
        try await uploadPart(
            key: key,
            uploadID: uploadID,
            partNumber: partNumber,
            data: data,
            progress: { _ in }
        )
    }

    public func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        data: Data,
        progress: @escaping UploadProgressHandler
    ) async throws -> UploadedPart {
        let response = try await send(
            method: "PUT",
            key: key,
            query: [
                URLQueryItem(name: "partNumber", value: String(partNumber)),
                URLQueryItem(name: "uploadId", value: uploadID)
            ],
            body: data,
            uploadProgress: progress
        )
        guard let eTag = response.response.value(forHTTPHeaderField: "ETag"), !eTag.isEmpty else {
            throw ObjectStoreError.invalidResponse("The S3 service accepted part \(partNumber) without returning an ETag.")
        }
        return UploadedPart(
            number: partNumber,
            eTag: eTag,
            size: Int64(data.count),
            checksum: response.response.value(forHTTPHeaderField: "x-amz-checksum-sha256")
        )
    }

    public func listParts(key: String, uploadID: String) async throws -> [UploadedPart] {
        var marker: String?
        var allParts: [UploadedPart] = []
        while true {
            var query = [
                URLQueryItem(name: "uploadId", value: uploadID),
                URLQueryItem(name: "max-parts", value: "1000")
            ]
            if let marker { query.append(URLQueryItem(name: "part-number-marker", value: marker)) }
            let response = try await send(method: "GET", key: key, query: query)
            let page = try S3XML.parseParts(response.data)
            allParts.append(contentsOf: page.parts)
            guard page.isTruncated else { break }
            guard let next = page.nextPartNumberMarker ?? page.parts.last?.number,
                  String(next) != marker else {
                throw ObjectStoreError.invalidResponse(
                    "The S3 service returned a truncated multipart listing without a usable continuation marker."
                )
            }
            marker = String(next)
        }
        return allParts.sorted { $0.number < $1.number }
    }

    public func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [UploadedPart]
    ) async throws -> RemoteObject {
        let body = S3XML.completedPartsDocument(parts)
        let completion = try await send(
            method: "POST",
            key: key,
            query: [URLQueryItem(name: "uploadId", value: uploadID)],
            headers: ["Content-Type": "application/xml"],
            body: body
        )
        if let serviceError = S3XML.embeddedError(completion.data) {
            throw classify(serviceError: serviceError, statusCode: completion.response.statusCode)
        }
        guard let object = try await head(key: key) else {
            throw ObjectStoreError.invalidResponse("The completed S3 object could not be read back.")
        }
        return object
    }

    public func abortMultipartUpload(key: String, uploadID: String) async throws {
        _ = try await send(
            method: "DELETE",
            key: key,
            query: [URLQueryItem(name: "uploadId", value: uploadID)]
        )
    }

    public func getRange(key: String, range: Range<Int64>?) async throws -> Data {
        var headers: [String: String] = [:]
        if let range {
            guard !range.isEmpty else { return Data() }
            headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
        }
        return try await send(method: "GET", key: key, headers: headers).data
    }

    private func send(
        method: String,
        key: String?,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        uploadProgress: UploadProgressHandler? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let url = try requestURL(key: key, query: query)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !body.isEmpty { request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        request = try signer.sign(
            request: request,
            bodySHA256: signer.sha256Hex(body),
            credentials: configuration.credentials,
            region: configuration.region
        )

        do {
            let progressDelegate = uploadProgress.map(UploadRequestProgressDelegate.init(handler:))
            let (data, urlResponse) = try await session.data(for: request, delegate: progressDelegate)
            guard let response = urlResponse as? HTTPURLResponse else {
                throw ObjectStoreError.invalidResponse("The S3 endpoint returned a non-HTTP response.")
            }
            try validate(response: response, data: data)
            if let uploadProgress, !body.isEmpty {
                // Delegate callbacks describe bytes sent, but the successful
                // HTTP response is the point at which the full request is no
                // longer merely in flight. Force the exact terminal value.
                await uploadProgress(Int64(body.count))
            }
            return (data, response)
        } catch let error as ObjectStoreError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ObjectStoreError.transient(error.localizedDescription)
        } catch {
            throw ObjectStoreError.transient(error.localizedDescription)
        }
    }

    private func requestURL(key: String?, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false),
              let endpointHost = components.host else {
            throw ObjectStoreError.invalidResponse("The S3 endpoint URL is invalid.")
        }
        var pathParts = components.path.split(separator: "/").map(String.init)
        switch configuration.addressingStyle {
        case .path:
            pathParts.append(configuration.bucket)
        case .virtualHost:
            components.host = configuration.bucket + "." + endpointHost
        }
        if let key, !key.isEmpty {
            pathParts.append(contentsOf: key.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        components.path = "/" + pathParts.joined(separator: "/")
        // Build the transmitted query with the same strict byte-wise encoding
        // used by SigV4. URLComponents.queryItems leaves some legal URL
        // characters unescaped, but AWS requires them escaped in canonical
        // query values (notably the characters in continuation tokens).
        components.percentEncodedQuery = query.isEmpty ? nil : AWSURIEncoder.query(query)
        guard let url = components.url else {
            throw ObjectStoreError.invalidResponse("The S3 request URL could not be constructed.")
        }
        return url
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        default:
            if let serviceError = S3XML.embeddedError(data) {
                throw classify(serviceError: serviceError, statusCode: response.statusCode)
            }
            let message = errorMessage(data, fallback: "S3 returned HTTP \(response.statusCode).")
            switch response.statusCode {
            case 404:
                throw ObjectStoreError.notFound
            case 401:
                throw ObjectStoreError.authentication(message)
            case 403:
                throw ObjectStoreError.accessDenied(message)
            case 408, 425, 429, 500...599:
                throw ObjectStoreError.transient(message)
            default:
                throw ObjectStoreError.invalidResponse(message)
            }
        }
    }

    private func classify(serviceError: S3ServiceError, statusCode: Int) -> ObjectStoreError {
        switch serviceError.code {
        case "InternalError", "OperationAborted", "RequestTimeout", "ServiceUnavailable",
             "SlowDown", "Throttling", "ThrottlingException":
            return .transient(serviceError.message)
        case "AccessDenied", "AllAccessDisabled":
            return .accessDenied(serviceError.message)
        case "ExpiredToken", "InvalidAccessKeyId", "InvalidToken", "SignatureDoesNotMatch",
             "TokenRefreshRequired", "AuthorizationHeaderMalformed", "RequestTimeTooSkewed":
            return .authentication(serviceError.message)
        case "NoSuchKey", "NoSuchUpload":
            return .notFound
        case "NoSuchBucket":
            return .incompatible(serviceError.message)
        default:
            switch statusCode {
            case 408, 425, 429, 500...599:
                return .transient(serviceError.message)
            case 401:
                return .authentication(serviceError.message)
            case 403:
                return .accessDenied(serviceError.message)
            case 404:
                return .notFound
            default:
                return .invalidResponse(serviceError.message)
            }
        }
    }

    private func remoteObject(
        key: String,
        response: HTTPURLResponse,
        authoritativeSize: Int64? = nil
    ) -> RemoteObject {
        var metadata: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName).lowercased()
            if name.hasPrefix("x-amz-meta-") {
                metadata[String(name.dropFirst("x-amz-meta-".count))] = String(describing: rawValue)
            }
        }
        // PUT's Content-Length describes its usually empty response body, not
        // the object just uploaded. HEAD has no authoritative caller value and
        // does use the response header as the object size.
        let size = authoritativeSize
            ?? response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            ?? 0
        return RemoteObject(
            key: key,
            size: size,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(parseHTTPDate),
            eTag: response.value(forHTTPHeaderField: "ETag"),
            // StorageSync stores a full-object SHA-256 in metadata when it can compute one
            // before upload. S3 checksum headers may describe a multipart composite and
            // must not be mistaken for a linear full-file digest.
            checksum: metadata["storagesync-sha256"],
            metadata: metadata
        )
    }

    private func metadataHeaders(_ metadata: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: metadata.map { key, value in
            ("x-amz-meta-" + key.lowercased(), value)
        })
    }

    private func errorMessage(_ data: Data, fallback: String) -> String {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return fallback }
        if let start = text.range(of: "<Message>"), let end = text.range(of: "</Message>"), start.upperBound <= end.lowerBound {
            return String(text[start.upperBound..<end.lowerBound])
        }
        return fallback
    }

    /// RFC 9110 IMF-fixdate, the only form `Last-Modified` is allowed to take.
    /// Built per call rather than shared: a formatter is a reference type that
    /// sharing would have to lock, and this runs a couple of times per transfer
    /// on HEAD responses, never once per listed object.
    private func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

private final class UploadRequestProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: UploadProgressHandler

    init(handler: @escaping UploadProgressHandler) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { await handler(totalBytesSent) }
    }
}
