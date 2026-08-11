import Foundation

public struct TransferPolicy: Sendable, Equatable {
    public var multipartThreshold: Int64
    public var preferredPartSize: Int64
    public var maximumPartCount: Int
    public var maximumPartSize: Int64
    public var maximumObjectSize: Int64
    public var maximumConcurrentFiles: Int
    public var maximumConcurrentPartsPerFile: Int

    public init(
        multipartThreshold: Int64 = 64 * 1_024 * 1_024,
        preferredPartSize: Int64 = 32 * 1_024 * 1_024,
        maximumPartCount: Int = 10_000,
        maximumPartSize: Int64 = 5 * 1_024 * 1_024 * 1_024,
        maximumObjectSize: Int64 = 5 * 1_024 * 1_024 * 1_024 * 1_024,
        maximumConcurrentFiles: Int = 2,
        maximumConcurrentPartsPerFile: Int = 2
    ) {
        self.multipartThreshold = multipartThreshold
        self.preferredPartSize = preferredPartSize
        self.maximumPartCount = maximumPartCount
        self.maximumPartSize = maximumPartSize
        self.maximumObjectSize = maximumObjectSize
        self.maximumConcurrentFiles = maximumConcurrentFiles
        self.maximumConcurrentPartsPerFile = maximumConcurrentPartsPerFile
    }

    public func partSize(forFileSize fileSize: Int64) throws -> Int64 {
        guard fileSize >= 0 else { throw TransferPolicyError.invalidFileSize }
        guard fileSize <= maximumObjectSize else { throw TransferPolicyError.objectTooLarge }
        let minimumForPartLimit = fileSize == 0
            ? 0
            : (fileSize + Int64(maximumPartCount) - 1) / Int64(maximumPartCount)
        let selected = max(preferredPartSize, minimumForPartLimit)
        guard selected <= maximumPartSize else { throw TransferPolicyError.objectTooLarge }
        return selected
    }

    public func parts(forFileSize fileSize: Int64, transferID: TransferID) throws -> [TransferPart] {
        guard fileSize > 0 else { return [] }
        let partSize = try partSize(forFileSize: fileSize)
        var parts: [TransferPart] = []
        var offset: Int64 = 0
        var number = 1
        while offset < fileSize {
            let length = min(partSize, fileSize - offset)
            parts.append(
                TransferPart(
                    transferID: transferID,
                    number: number,
                    offset: offset,
                    length: length,
                    checksum: ""
                )
            )
            offset += length
            number += 1
        }
        guard parts.count <= maximumPartCount else { throw TransferPolicyError.objectTooLarge }
        return parts
    }
}

public enum TransferPolicyError: Error, LocalizedError, Equatable {
    case invalidFileSize
    case objectTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidFileSize: "The file has an invalid size."
        case .objectTooLarge: "The file exceeds the S3-compatible provider's object-size or multipart limits."
        }
    }
}
