import Foundation

/// Socket absent ⇒ launch Zodl and wait for its listener (spec BR-5).
/// Fully injected so tests never launch anything or sleep for real.
public struct Waker {
    public var probe: () -> Bool
    public var launch: (String) -> Bool
    public var sleepMs: (Int) -> Void

    public init(probe: @escaping () -> Bool, launch: @escaping (String) -> Bool, sleepMs: @escaping (Int) -> Void) {
        self.probe = probe
        self.launch = launch
        self.sleepMs = sleepMs
    }

    /// True once the listener is reachable. Launches at most once.
    /// Default wait 30 s (60 × 500 ms): a cold SwiftUI launch binds its listener
    /// early (at didFinishLaunching, before auth/Home), but "early" can still be
    /// several seconds; the in-app buffer then replays the request when Home is
    /// reached, so the helper only needs to survive until the socket BINDS.
    public func ensureListening(bundleID: String?, attempts: Int = 60, delayMs: Int = 500) -> Bool {
        if probe() { return true }
        guard let bundleID, !bundleID.isEmpty, launch(bundleID) else { return false }
        for _ in 0..<attempts {
            sleepMs(delayMs)
            if probe() { return true }
        }
        return false
    }

    /// Production launcher: `/usr/bin/open -b <bundleID>` (LaunchServices, no shell).
    public static func systemLauncher(_ bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
