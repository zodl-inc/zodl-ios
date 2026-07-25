#if VOTING_ENABLED
import Foundation

// MARK: - Server Health Tracker

/// Tracks per-server health using a circuit breaker pattern.
/// Servers that fail repeatedly are temporarily excluded from share distribution,
/// with periodic probes to detect recovery.
actor ServerHealthTracker {
    static let shared = ServerHealthTracker()

    // MARK: - Circuit Breaker

    enum Circuit: Equatable {
        case closed
        case open(since: Date)
        case halfOpen

        static func == (lhs: Circuit, rhs: Circuit) -> Bool {
            switch (lhs, rhs) {
            case (.closed, .closed), (.halfOpen, .halfOpen):
                return true
            case (.open(let a), .open(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    struct ServerState {
        var circuit: Circuit = .closed
        var consecutiveFailures = 0
    }

    // MARK: - Constants

    private let failureThreshold = 3
    private let cooldownInterval: TimeInterval = 30

    // MARK: - State

    typealias ProbeFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var servers: [String: ServerState] = [:]
    private var probeTask: Task<Void, Never>?
    /// Caller-supplied fetcher used by `probe`. Set inside
    /// `initialize(serverURLs:fetcher:)` and only then. Left `nil` to make
    /// any pre-initialize call to `probeAll()` a no-op rather than fall back
    /// to a non-Tor `URLSession.shared`; that fallback would leak the
    /// device's IP to every vote server every 60s if a future refactor ever
    /// called probeAll before initialize.
    private var probeFetcher: ProbeFetcher?

    // MARK: - Initialization

    /// Populate the server map and run an initial parallel probe of all servers.
    /// Called when the CDN service config is loaded. The `fetcher` is captured
    /// so the periodic background probe respects the current Tor preference.
    func initialize(serverURLs: [String], fetcher: @escaping ProbeFetcher) async {
        // Replace server map (preserving nothing from prior config)
        servers = Dictionary(uniqueKeysWithValues: serverURLs.map { ($0, ServerState()) })
        probeFetcher = fetcher

        // Fire parallel probes so we know who's healthy before the first vote
        await probeAll()

        // Start background probing (replaces any existing loop)
        startBackgroundProbing()
    }

    // MARK: - Server Selection

    /// Returns servers whose circuit is closed or halfOpen.
    /// If all servers are open (or map is empty), returns ALL servers as a fallback
    /// so that voting is never blocked by the health tracker.
    func healthyServers() -> [String] {
        let now = Date()
        var healthy: [String] = []

        for (url, state) in servers {
            switch state.circuit {
            case .closed:
                healthy.append(url)
            case .open(let since) where now.timeIntervalSince(since) >= cooldownInterval:
                // Cooldown expired — transition to halfOpen and allow traffic
                servers[url]?.circuit = .halfOpen
                healthy.append(url)
            case .halfOpen:
                healthy.append(url)
            default:
                break
            }
        }

        // Graceful degradation: never return empty
        if healthy.isEmpty {
            LoggerProxy.info("All servers unhealthy; falling back to full list")
            return Array(servers.keys)
        }
        return healthy
    }

    // MARK: - State Updates

    func recordSuccess(for url: String) {
        guard var state = servers[url] else { return }
        let previous = state.circuit
        state.circuit = .closed
        state.consecutiveFailures = 0
        servers[url] = state
        if previous != .closed {
            LoggerProxy.info("\(url) recovered; circuit closed")
        }
    }

    func recordFailure(for url: String) {
        guard var state = servers[url] else { return }
        state.consecutiveFailures += 1
        let failures = state.consecutiveFailures

        if failures >= failureThreshold && state.circuit == .closed {
            state.circuit = .open(since: Date())
            servers[url] = state
            LoggerProxy.warn("\(url) circuit opened after \(failures) failures")
        } else if state.circuit == .halfOpen {
            // halfOpen probe failed — re-open
            state.circuit = .open(since: Date())
            servers[url] = state
            LoggerProxy.warn("\(url) half-open probe failed; circuit reopened")
        } else {
            servers[url] = state
        }
    }

    // MARK: - Health Probing

    /// Probe all servers in parallel with GET /shielded-vote/v1/status.
    /// No-op until `initialize(serverURLs:fetcher:)` has set the fetcher;
    /// this is what keeps probes routed through Tor whenever the user has
    /// it enabled, never the system URLSession.
    func probeAll() async {
        let urls = Array(servers.keys)
        guard !urls.isEmpty, let fetcher = probeFetcher else { return }

        await withTaskGroup(of: (String, Bool).self) { group in
            for url in urls {
                group.addTask {
                    let ok = await Self.probe(url: url, fetcher: fetcher)
                    return (url, ok)
                }
            }
            for await (url, ok) in group {
                if ok {
                    recordSuccess(for: url)
                } else {
                    recordFailure(for: url)
                }
            }
        }
    }

    /// Single server probe. Returns true if the server responds 200 within the timeout.
    private static func probe(url: String, fetcher: ProbeFetcher) async -> Bool {
        guard let endpoint = URL(string: "\(url)/shielded-vote/v1/status") else { return false }
        do {
            let (_, response) = try await fetcher(URLRequest(url: endpoint))
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Background Probing

    private func startBackgroundProbing() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.probeAll()
            }
        }
    }

    func stopBackgroundProbing() {
        probeTask?.cancel()
        probeTask = nil
    }
}
#endif
