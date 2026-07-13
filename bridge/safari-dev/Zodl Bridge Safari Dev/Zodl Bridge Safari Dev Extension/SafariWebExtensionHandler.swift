//
//  SafariWebExtensionHandler.swift
//  Zodl Bridge Safari Dev — DEV SCAFFOLD ONLY (bridge/README.md §Safari).
//
//  Safari edition of the pinned chain's middle hop: Safari delivers the
//  extension's message HERE (the wrapper app's own handler — Apple's packaging
//  replaces the Chromium host-manifest pinning), and this forwards the line to
//  the same App-Group UDS socket the real Zodl listens on. Production Safari
//  support ships INSIDE Zodl (planned Safari-family target, post-WIP); this
//  wrapper exists so Safari UX is testable today without touching the Zodl
//  Xcode project.
//

import SafariServices
import os.log

private let bridgeLog = OSLog(subsystem: "co.zodl.bridge", category: "safari-dev")

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]

        var ack: [String: Any] = ["status": "rejected", "reason": "bad-shape"]
        if let dict = message as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: dict),
            data.count <= 8 * 1024 {
            // Forward verbatim — semantic validation is Zodl's listener's job,
            // the same division of labor as the Chromium helper.
            ack = UDSLine.send(data)
        }
        os_log(.default, log: bridgeLog, "[bridge-debug] safari-dev ack: %{public}@", String(describing: ack))

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ack]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

/// Minimal one-shot UDS line client — a deliberate inline copy of
/// BridgeCore.UDSClient (this generated project carries no SPM deps; dev-only).
private enum UDSLine {
    static func send(_ payload: Data) -> [String: Any] {
        // Real home even if this process runs sandboxed (pw_dir, not
        // NSHomeDirectory) — must match the path sandboxed Zodl resolves via
        // its App Group container.
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return ["status": "rejected", "reason": "no-home"]
        }
        let path = "\(String(cString: dir))/Library/Group Containers/RLPRR8CPQG.zodl.bridge/bridge.sock"

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= maxLen else { return ["status": "rejected", "reason": "path-too-long"] }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return ["status": "rejected", "reason": "socket-failed"] }
        defer { close(fd) }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return ["status": "rejected", "reason": "zodl-unreachable"] }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var line = payload
        line.append(UInt8(ascii: "\n"))
        let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == line.count else { return ["status": "rejected", "reason": "write-failed"] }

        var reply = Data()
        var byte: UInt8 = 0
        while reply.count < 4096 {
            let n = read(fd, &byte, 1)
            if n <= 0 { return ["status": "rejected", "reason": "no-ack"] }
            if byte == UInt8(ascii: "\n") { break }
            reply.append(byte)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            return ["status": "rejected", "reason": "bad-ack"]
        }
        return parsed
    }
}
