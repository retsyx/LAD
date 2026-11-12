import CryptoKit
import Foundation

extension SHA256 {
    /// Lowercase hexadecimal SHA-256, the form of LAD's content addresses,
    /// integrity checks and identities.
    static func hexDigest<D: DataProtocol>(_ data: D) -> String {
        hash(data: data).hexString
    }
}

extension SHA256.Digest {
    /// Lowercase hexadecimal digest, also for incrementally hashed streams.
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var text = [UInt8]()
        text.reserveCapacity(2 * Self.byteCount)
        for byte in self {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
