import CryptoKit
import Foundation

public extension Sequence<UInt8> {
    /// Lowercase hexadecimal, the form every checksum StorageSync persists or
    /// sends to S3 uses. Written out by hand rather than with `String(format:)`
    /// because that reaches into NSString formatting once per byte.
    var hexadecimalString: String {
        var result = ""
        result.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            result.append(Self.hexadecimalDigits[Int(byte >> 4)])
            result.append(Self.hexadecimalDigits[Int(byte & 0x0f)])
        }
        return result
    }

    private static var hexadecimalDigits: [Character] {
        ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    }
}

public extension Data {
    /// The full-object digest StorageSync stores in its baselines and in S3
    /// metadata. S3's own checksum headers may describe a multipart composite,
    /// so a linear digest of the bytes is computed locally instead.
    var sha256Hexadecimal: String {
        SHA256.hash(data: self).hexadecimalString
    }
}
