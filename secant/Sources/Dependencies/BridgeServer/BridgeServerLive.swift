//
//  BridgeServerLive.swift
//  Zashi
//
//  UDS line server for the Zodl Bridge (spec BR-5). Mirrors the shape proven in
//  bridge/host (BridgeCore.UDSListener + 20 tests + headless e2e): unlink-bind-
//  listen, per-connection same-uid peer gate, one JSON line in (8 KB cap), one
//  local ack line out. macOS only; iOS builds get an inert client.
//

import ComposableArchitecture
import Foundation
import os

// [bridge-debug] Temporary diagnostics for the cold-launch investigation (task #172):
// answers "did startListener fire, what home did the sandbox resolve, which syscall
// failed" via `log show --predicate 'subsystem == "co.zodl.bridge"'`. Trim once the
// live-fire E2E is green.
private let bridgeLog = os.Logger(subsystem: "co.zodl.bridge", category: "server")

extension BridgeServerClient: DependencyKey {
    #if os(macOS)
    static let liveValue = BridgeServerClient.live()

    static func live() -> Self {
        let server = BridgeUDSServer()
        return Self(
            start: { server.start() },
            stop: { server.stop() }
        )
    }
    #else
    static let liveValue = Self(
        start: { .finished },
        stop: { }
    )
    #endif
}

#if os(macOS)
/// Blocking accept-loop server on a background thread. Deliberately boring BSD
/// sockets — Network.framework's UDS support is not worth the abstraction here,
/// and this mirrors the helper-side client byte-for-byte.
final class BridgeUDSServer: @unchecked Sendable {
    /// Team-prefixed App Group (macOS requirement) — must match
    /// `BridgeConfig.appGroupID` in bridge/host.
    static let appGroupID = "RLPRR8CPQG.zodl.bridge"

    /// Sandbox-safe rendezvous (the task-#172 root cause, live-fire 2026-07-09):
    /// the app IS sandboxed, so `NSHomeDirectory()` is the per-app container —
    /// which (a) overflows `sun_path` (123 > 103 bytes) and (b) diverges from the
    /// unsandboxed helper's view of "home". The App Group container is short and
    /// IDENTICAL from both sides. Fallback = the legacy App Support path, for a
    /// build signed without the group entitlement (logged either way).
    static var socketPath: String {
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("bridge.sock").path
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Zodl/bridge.sock")
    }

    private static let maxLineBytes = 8 * 1024

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var continuation: AsyncStream<BridgePaymentRequest>.Continuation?

    func start() -> AsyncStream<BridgePaymentRequest> {
        lock.lock()
        defer { lock.unlock() }

        // Idempotent: a second start replaces the consumer stream but keeps the
        // socket (routing owns the single subscription; RootStore calls once).
        if listenFD >= 0 {
            bridgeLog.log("[bridge-debug] start(): already listening, re-issuing stream")
            let (stream, continuation) = AsyncStream<BridgePaymentRequest>.makeStream()
            self.continuation?.finish()
            self.continuation = continuation
            return stream
        }

        let path = Self.socketPath
        bridgeLog.log("[bridge-debug] start(): home=\(NSHomeDirectory(), privacy: .public) socket=\(path, privacy: .public)")
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            bridgeLog.log("[bridge-debug] start(): createDirectory FAILED: \(error.localizedDescription, privacy: .public)")
        }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxLen else {
            bridgeLog.log("[bridge-debug] start(): path too long (\(pathBytes.count) > \(maxLen))")
            return .finished
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            bridgeLog.log("[bridge-debug] start(): socket() FAILED errno=\(errno)")
            return .finished
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            bridgeLog.log("[bridge-debug] start(): bind/listen FAILED bound=\(bound) errno=\(errno)")
            close(fd)
            return .finished
        }
        bridgeLog.log("[bridge-debug] start(): LISTENING on \(path, privacy: .public)")

        listenFD = fd
        let (stream, continuation) = AsyncStream<BridgePaymentRequest>.makeStream()
        self.continuation = continuation

        let thread = Thread { [weak self] in
            while let self, let conn = self.acceptConnection() {
                self.handle(connection: conn)
            }
        }
        thread.name = "zodl.bridge.uds"
        thread.start()
        return stream
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(Self.socketPath)
        continuation?.finish()
        continuation = nil
    }

    private func acceptConnection() -> Int32? {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        guard fd >= 0 else { return nil }
        let conn = accept(fd, nil, nil)
        return conn >= 0 ? conn : nil
    }

    private func handle(connection: Int32) {
        defer { close(connection) }

        // Same-uid peer gate (spec BR-5): other users' processes are refused.
        var euid = uid_t(0)
        var egid = gid_t(0)
        guard getpeereid(connection, &euid, &egid) == 0, euid == geteuid() else { return }

        var line = Data()
        var byte: UInt8 = 0
        while line.count < Self.maxLineBytes {
            let n = read(connection, &byte, 1)
            if n <= 0 { return }
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
        }
        guard line.count < Self.maxLineBytes else { return }

        guard
            let wire = try? JSONDecoder().decode(WireMessage.self, from: line),
            wire.v == 1,
            wire.type == "payRequest",
            !wire.id.isEmpty, wire.id.count <= 64,
            wire.uri.hasPrefix("zcash:"), wire.uri.count <= 2048,
            !wire.origin.isEmpty, wire.origin.count <= 256
        else { return }

        // Local delivery ack only (spec Invariant 3) — never wallet data.
        var ack = Data(#"{"status":"received"}"#.utf8)
        ack.append(UInt8(ascii: "\n"))
        _ = ack.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }

        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(
            BridgePaymentRequest(id: wire.id, uri: wire.uri, origin: wire.origin, requestSrc: wire.requestSrc)
        )
    }

    private struct WireMessage: Codable {
        let v: Int
        let id: String
        let type: String
        let uri: String
        let origin: String
        let requestSrc: String?
    }
}
#endif
