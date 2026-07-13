import Foundation

/// Minimal blocking UDS line server. Used by `mock-zodl` (Phase A) and by tests;
/// Zodl's in-app listener (Phase B) mirrors this shape with DispatchSource + TCA.
public final class UDSListener {
    public typealias Handler = (Data) -> Data?

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private var thread: Thread?
    private let started = DispatchSemaphore(value: 0)

    /// `handler` receives one request line and returns the ack line (nil = no reply).
    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxLen else { throw UDSError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSError.socketFailed }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw UDSError.socketFailed
        }

        // Same-uid peer gate (spec BR-5): refuse other users' processes outright.
        let listenFD = fd
        let acceptLoop = Thread { [handler] in
            self.started.signal()
            while true {
                let conn = accept(listenFD, nil, nil)
                if conn < 0 { break }
                var euid = uid_t(0)
                var egid = gid_t(0)
                if getpeereid(conn, &euid, &egid) != 0 || euid != geteuid() {
                    close(conn)
                    continue
                }
                var line = Data()
                var byte: UInt8 = 0
                while line.count < NativeMessaging.maxMessageBytes {
                    let n = read(conn, &byte, 1)
                    if n <= 0 { break }
                    if byte == UInt8(ascii: "\n") { break }
                    line.append(byte)
                }
                if !line.isEmpty, var reply = handler(line) {
                    if reply.last != UInt8(ascii: "\n") { reply.append(UInt8(ascii: "\n")) }
                    _ = reply.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
                }
                close(conn)
            }
        }
        acceptLoop.start()
        thread = acceptLoop
        started.wait()
    }

    public func stop() {
        if fd >= 0 { close(fd) }
        unlink(path)
        fd = -1
    }
}
