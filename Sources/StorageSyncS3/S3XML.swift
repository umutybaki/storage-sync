import Foundation
import StorageSyncCore

struct ListObjectsXMLResult {
    var objects: [RemoteObject]
    var isTruncated: Bool
    var nextContinuationToken: String?
}

struct S3ServiceError {
    var code: String?
    var message: String
}

struct MultipartUploadXMLResult {
    var uploadID: String
}

struct ListPartsXMLResult {
    var parts: [UploadedPart]
    var isTruncated: Bool
    var nextPartNumberMarker: Int?
}

/// `LastModified` in an S3 listing is ISO 8601, but whether it carries
/// fractional seconds varies: real `ListObjectsV2` responses from AWS always
/// send `2009-10-12T17:50:30.000Z`, while some S3-compatible services omit the
/// milliseconds.
///
/// This deliberately does not use `ISO8601DateFormatter`, which accepts exactly
/// one of those two shapes per configuration and returns nil for the other —
/// with its default options it rejects every timestamp AWS actually sends.
/// `Date.ISO8601FormatStyle` parses both, and unlike the formatter it is a
/// `Sendable` value, so one shared instance is safe for a listing page that
/// carries a thousand of these.
private enum S3Timestamp {
    private static let style = Date.ISO8601FormatStyle()

    static func parse(_ value: String) -> Date? {
        try? style.parse(value)
    }
}

private final class S3XMLParserDelegate: NSObject, XMLParserDelegate {
    var objects: [RemoteObject] = []
    var continuationToken: String?
    var uploadID: String?
    var parts: [UploadedPart] = []
    var isTruncated = false
    var nextPartNumberMarker: Int?
    var rootElement: String?
    var serviceErrorMessage: String?
    var serviceErrorCode: String?
    var parseError: Error?

    private var elementStack: [String] = []
    private var text = ""
    private var objectKey: String?
    private var objectSize: Int64?
    private var objectModified: Date?
    private var objectETag: String?
    private var partNumber: Int?
    private var partSize: Int64?
    private var partETag: String?
    private var partChecksum: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootElement == nil { rootElement = elementName }
        elementStack.append(elementName)
        text = ""
        if elementName == "Contents" {
            objectKey = nil
            objectSize = nil
            objectModified = nil
            objectETag = nil
        } else if elementName == "Part" {
            partNumber = nil
            partSize = nil
            partETag = nil
            partChecksum = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elementStack.dropLast().last
        switch (parent, elementName) {
        case ("Contents", "Key"):
            objectKey = value
        case ("Contents", "Size"):
            objectSize = Int64(value)
        case ("Contents", "LastModified"):
            objectModified = S3Timestamp.parse(value)
        case ("Contents", "ETag"):
            objectETag = value
        case (_, "NextContinuationToken"):
            continuationToken = value.isEmpty ? nil : value
        case (_, "UploadId"):
            uploadID = value
        case (_, "IsTruncated"):
            isTruncated = value.lowercased() == "true"
        case (_, "NextPartNumberMarker"):
            nextPartNumberMarker = Int(value)
        case ("Error", "Message"):
            serviceErrorMessage = value
        case ("Error", "Code"):
            serviceErrorCode = value
        case ("Part", "PartNumber"):
            partNumber = Int(value)
        case ("Part", "Size"):
            partSize = Int64(value)
        case ("Part", "ETag"):
            partETag = value
        case ("Part", "ChecksumSHA256"):
            partChecksum = value
        default:
            break
        }

        if elementName == "Contents", let key = objectKey, let size = objectSize {
            objects.append(RemoteObject(key: key, size: size, lastModified: objectModified, eTag: objectETag))
        } else if elementName == "Part", let number = partNumber, let eTag = partETag {
            parts.append(UploadedPart(number: number, eTag: eTag, size: partSize, checksum: partChecksum))
        }
        _ = elementStack.popLast()
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

enum S3XML {
    static func parseObjects(_ data: Data) throws -> ListObjectsXMLResult {
        let delegate = try parse(data)
        return ListObjectsXMLResult(
            objects: delegate.objects,
            isTruncated: delegate.isTruncated,
            nextContinuationToken: delegate.continuationToken
        )
    }

    static func parseUploadID(_ data: Data) throws -> MultipartUploadXMLResult {
        let delegate = try parse(data)
        guard let uploadID = delegate.uploadID, !uploadID.isEmpty else {
            throw ObjectStoreError.invalidResponse("The S3 service did not return a multipart upload ID.")
        }
        return MultipartUploadXMLResult(uploadID: uploadID)
    }

    static func parseParts(_ data: Data) throws -> ListPartsXMLResult {
        let delegate = try parse(data)
        return ListPartsXMLResult(
            parts: delegate.parts.sorted { $0.number < $1.number },
            isTruncated: delegate.isTruncated,
            nextPartNumberMarker: delegate.nextPartNumberMarker
        )
    }

    static func completedPartsDocument(_ parts: [UploadedPart]) -> Data {
        let entries = parts.sorted { $0.number < $1.number }.map { part in
            "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(escape(part.eTag))</ETag></Part>"
        }.joined()
        return Data("<CompleteMultipartUpload>\(entries)</CompleteMultipartUpload>".utf8)
    }

    static func embeddedError(_ data: Data) -> S3ServiceError? {
        guard !data.isEmpty,
              let delegate = try? parse(data),
              delegate.rootElement == "Error" else { return nil }
        return S3ServiceError(
            code: delegate.serviceErrorCode,
            message: delegate.serviceErrorMessage ?? "S3 returned an error while completing the multipart upload."
        )
    }

    private static func parse(_ data: Data) throws -> S3XMLParserDelegate {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = S3XMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ObjectStoreError.invalidResponse(delegate.parseError?.localizedDescription ?? "Malformed S3 XML response.")
        }
        return delegate
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
