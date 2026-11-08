import CryptoKit
import Foundation
import StorageSyncCore

public struct SigV4Signer: Sendable {
    public init() {}

    public func sign(
        request: URLRequest,
        bodySHA256: String,
        credentials: S3Credentials,
        region: String,
        service: String = "s3",
        date: Date = Date()
    ) throws -> URLRequest {
        guard let url = request.url, url.host != nil else {
            throw ObjectStoreError.invalidResponse("Cannot sign a request without a host.")
        }
        var signed = request
        let timestamp = timestamp(date)
        let day = String(timestamp.prefix(8))
        signed.setValue(hostHeader(url: url), forHTTPHeaderField: "Host")
        signed.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        signed.setValue(bodySHA256, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken {
            signed.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        let headers = canonicalHeaders(signed.allHTTPHeaderFields ?? [:])
        let signedHeaderNames = headers.map(\.name).joined(separator: ";")
        let canonicalHeaderText = headers.map { "\($0.name):\($0.value)\n" }.joined()
        let canonicalRequest = [
            signed.httpMethod ?? "GET",
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaderText,
            signedHeaderNames,
            bodySHA256
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signingKey = signatureKey(
            secret: credentials.secretAccessKey,
            day: day,
            region: region,
            service: service
        )
        let signature = hmacHex(key: signingKey, value: stringToSign)
        signed.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaderNames), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return signed
    }

    public func sha256Hex(_ data: Data) -> String {
        data.sha256Hexadecimal
    }

    private func signatureKey(secret: String, day: String, region: String, service: String) -> SymmetricKey {
        let dateKey = hmac(key: SymmetricKey(data: Data(("AWS4" + secret).utf8)), value: day)
        let regionKey = hmac(key: SymmetricKey(data: dateKey), value: region)
        let serviceKey = hmac(key: SymmetricKey(data: regionKey), value: service)
        return SymmetricKey(data: hmac(key: SymmetricKey(data: serviceKey), value: "aws4_request"))
    }

    private func hmac(key: SymmetricKey, value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key))
    }

    private func hmacHex(key: SymmetricKey, value: String) -> String {
        hmac(key: key, value: value).hexadecimalString
    }

    private func canonicalHeaders(_ headers: [String: String]) -> [(name: String, value: String)] {
        headers.map { key, value in
            (
                key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            )
        }.sorted { $0.name < $1.name }
    }

    private func canonicalURI(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return Reconciler.pathComponents(path)
            .map { AWSURIEncoder.encode(String($0)) }
            .joined(separator: "/")
    }

    private func canonicalQuery(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let encoded: [(String, String)] = (components.queryItems ?? []).map { item in
            (AWSURIEncoder.encode(item.name), AWSURIEncoder.encode(item.value ?? ""))
        }
        let sorted = encoded.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        return sorted.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }

    private func hostHeader(url: URL) -> String {
        guard let port = url.port else { return url.host ?? "" }
        let isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return isDefault ? (url.host ?? "") : "\(url.host ?? ""):\(port)"
    }

    /// SigV4's basic-format UTC timestamp, `20130524T000000Z`. Built from
    /// calendar components rather than a `DateFormatter` because every request
    /// needs one and `Calendar` is a `Sendable` value that can simply be shared,
    /// whereas a formatter is a reference type that would need locking. The
    /// signer is checked against Amazon's published test vector, so a mistake
    /// in this format cannot pass unnoticed.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private func timestamp(_ date: Date) -> String {
        let parts = Self.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return pad(parts.year, 4) + pad(parts.month, 2) + pad(parts.day, 2)
            + "T" + pad(parts.hour, 2) + pad(parts.minute, 2) + pad(parts.second, 2) + "Z"
    }
}

/// AWS SigV4 URI encoding is deliberately narrower than Foundation's general
/// URL encoding. In particular, opaque S3 continuation tokens commonly contain
/// `+`, `/`, and `=`. The bytes sent on the wire and the bytes in the canonical
/// request must use this exact representation or page two of a listing fails
/// with `SignatureDoesNotMatch` even though page one succeeds.
enum AWSURIEncoder {
    private static let hexadecimal = Array("0123456789ABCDEF".utf8)

    static func encode(_ value: String) -> String {
        var result = String()
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                result.append("%")
                result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte >> 4)]))
                result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte & 0x0f)]))
            }
        }
        return result
    }

    static func query(_ items: [URLQueryItem]) -> String {
        var encoded: [(name: String, value: String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            encoded.append((name: encode(item.name), value: encode(item.value ?? "")))
        }
        encoded.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        return encoded.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }
}
