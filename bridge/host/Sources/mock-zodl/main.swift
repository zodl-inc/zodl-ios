import BridgeCore
import Foundation

// mock-zodl — Phase A stand-in for Zodl's in-app UDS listener. Prints every
// delivered payment request and acks it, so the browser→extension→helper→socket
// chain is provable end-to-end before any Zodl integration exists (plan A5).

// Unbuffered stdout: e2e.sh greps the log while we run (print block-buffers to files).
setvbuf(stdout, nil, _IONBF, 0)

let path = CommandLine.arguments.dropFirst().first ?? BridgeConfig.defaultSocketPath()
try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: path).deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let listener = UDSListener(path: path) { line in
    let stamp = ISO8601DateFormatter().string(from: Date())
    let text = String(data: line, encoding: .utf8) ?? "<non-utf8 \(line.count) bytes>"
    print("[\(stamp)] REQUEST: \(text)")
    return Data(#"{"status":"received"}"#.utf8)
}

do {
    try listener.start()
    print("mock-zodl listening on \(path) — Ctrl-C to stop")
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("mock-zodl failed to listen on \(path): \(error)\n".utf8))
    exit(1)
}
