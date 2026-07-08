import BridgeCore
import Foundation

// zodl-bridge-host — one-shot native-messaging helper (spec BR-5/BR-6).
// The browser launches this per message with the caller origin in argv;
// everything interesting lives in BridgeCore.HostPipeline (unit-tested).

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("zodl-bridge-host 0.1.0")
    exit(0)
}

// Config sits next to the installed binary (install-dev.sh writes it).
let binaryDir = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let config = BridgeConfig.load(from: binaryDir.appendingPathComponent("bridge-config.json"))
    ?? BridgeConfig(allowedExtensionIDs: [])
let socketPath = config.resolvedSocketPath()

// Chromium passes the caller as the first non-flag argument (chrome-extension://…/).
let callerOrigin = arguments.dropFirst().first(where: { $0.hasPrefix("chrome-extension://") }) ?? ""

let stdin = FileHandle.standardInput
func readExactly(_ count: Int) -> Data {
    var buffer = Data()
    while buffer.count < count {
        guard let chunk = try? stdin.read(upToCount: count - buffer.count), !chunk.isEmpty else { break }
        buffer.append(chunk)
    }
    return buffer
}

let client = UDSClient(path: socketPath)
let waker = Waker(
    probe: { client.canConnect() },
    launch: { Waker.systemLauncher($0) },
    sleepMs: { usleep(UInt32($0) * 1000) }
)

let environment = HostPipeline.Environment(
    allowlist: Allowlist(allowedExtensionIDs: config.allowedExtensionIDs),
    deliver: { try client.sendLine($0) },
    ensureListening: { waker.ensureListening(bundleID: config.zodlBundleID) }
)

let ack = HostPipeline.handle(framedInput: readExactly, callerOrigin: callerOrigin, env: environment)
FileHandle.standardOutput.write(ack)
exit(0)
