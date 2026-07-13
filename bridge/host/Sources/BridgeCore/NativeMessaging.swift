import Foundation

/// Chrome/Chromium native-messaging stdio framing: a 4-byte little-endian length
/// prefix followed by exactly that many bytes of UTF-8 JSON.
public enum NativeMessaging {
    /// Spec cap (ZODL_BRIDGE_SPEC.md shared constants): native message ≤ 8 KB.
    /// Anything larger is rejected before its body is read.
    public static let maxMessageBytes = 8 * 1024

    public enum ReadError: Error, Equatable {
        case eof
        case oversize(Int)
        case truncated(expected: Int, got: Int)
    }

    /// Reads one framed message. `read(n)` must return up to `n` bytes; fewer means EOF.
    public static func readMessage(read: (Int) -> Data) throws -> Data {
        let header = read(4)
        if header.isEmpty { throw ReadError.eof }
        guard header.count == 4 else { throw ReadError.truncated(expected: 4, got: header.count) }
        let length = Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= maxMessageBytes else { throw ReadError.oversize(length) }
        let body = read(length)
        guard body.count == length else { throw ReadError.truncated(expected: length, got: body.count) }
        return body
    }

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }
}
