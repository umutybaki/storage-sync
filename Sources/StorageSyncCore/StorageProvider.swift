import Foundation

public enum StorageProvider: String, CaseIterable, Identifiable, Sendable {
    case amazon
    case cloudflareR2
    case compatible

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .amazon: "Amazon S3"
        case .cloudflareR2: "Cloudflare R2"
        case .compatible: "Other S3-compatible"
        }
    }

    public static func identify(endpoint: URL) -> StorageProvider {
        let host = endpoint.host?.lowercased() ?? ""
        if host.hasSuffix(".r2.cloudflarestorage.com") { return .cloudflareR2 }
        if host == "s3.amazonaws.com" || host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn") { return .amazon }
        return .compatible
    }

    /// Presets contain transport configuration only, never credential material.
    public func preset(region: String, accountID: String, endpoint: String, bucket: String) throws -> S3ConnectionPreset {
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endpointText: String
        switch self {
        case .amazon:
            guard !region.isEmpty,
                  region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw StoragePresetError.invalidRegion
            }
            endpointText = "https://s3.\(region).\(region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com")"
        case .cloudflareR2:
            let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard account.utf8.count == 32,
                  account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw StoragePresetError.invalidAccountID
            }
            endpointText = "https://\(account).r2.cloudflarestorage.com"
        case .compatible:
            endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let url = URL(string: endpointText), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())) else {
            throw StoragePresetError.invalidEndpoint
        }
        guard self == .cloudflareR2 || !region.isEmpty else { throw StoragePresetError.invalidRegion }
        return S3ConnectionPreset(
            endpoint: url,
            region: self == .cloudflareR2 ? "auto" : region,
            addressingStyle: self == .amazon && !bucket.contains(".") ? .virtualHost : .path
        )
    }
}

public struct S3ConnectionPreset: Sendable, Equatable {
    public let endpoint: URL
    public let region: String
    public let addressingStyle: AddressingStyle
}

public enum StoragePresetError: Error, LocalizedError {
    case invalidAccountID
    case invalidEndpoint
    case invalidRegion

    public var errorDescription: String? {
        switch self {
        case .invalidAccountID: "Enter your 32-character Cloudflare account ID."
        case .invalidEndpoint: "Use a valid HTTPS S3 endpoint. Plain HTTP is allowed only for a local test server."
        case .invalidRegion: "Enter a valid bucket region."
        }
    }
}
