import Foundation

public enum UDSError: Error, Equatable {
    case pathTooLong
    case socketFailed
    case connectFailed
    case writeFailed
    case timeout
    case closed
}

/// One-shot Unix-domain-socket client (spec BR-5): connect → write one JSON line →
/// read one ack line → close. Fire-and-forget with a local delivery ack only.
public struct UDSClient {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Cheap listening probe used by the wake loop.
    public func canConnect() -> Bool {
        guard let fd = try? connect() else { return false }
        close(fd)
        return true
    }

    /// Sends `line` (newline appended if missing) and returns the ack line (sans newline).
    public func sendLine(_ line: Data, timeout: TimeInterval = 1.0) throws -> Data {
        let fd = try connect()
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var payload = line
        if payload.last != UInt8(ascii: "\n") { payload.append(UInt8(ascii: "\n")) }
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard n > 0 else { throw UDSError.writeFailed }
                sent += n
            }
        }

        var ack = Data()
        var byte: UInt8 = 0
        while ack.count < 4096 {
            let n = read(fd, &byte, 1)
            if n == 0 { throw UDSError.closed }
            if n < 0 { throw UDSError.timeout }
            if byte == UInt8(ascii: "\n") { return ack }
            ack.append(byte)
        }
        return ack
    }

    private func connect() throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxLen else { throw UDSError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSError.socketFailed }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw UDSError.connectFailed
        }
        return fd
    }
}
