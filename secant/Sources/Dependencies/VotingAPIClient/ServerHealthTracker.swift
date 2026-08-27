#if VOTING_ENABLED
import Foundation

// MARK: - Server Health Tracker

/// Tracks per-server health using a circuit breaker pattern.
/// Health signals come from real share POSTs (`recordSuccess`/`recordFailure`)
/// and from one-shot probe sweeps started at poll entry and submission start —
/// never from the polls-list load path, and never from a periodic loop
/// (MOB-1810). The data is advisory ordering input for share submission;
/// nothing filters on it and nothing blocks on it.
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
    private let cooldownInterval: TimeInterval

    // MARK: - State

    typealias ProbeFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var servers: [String: ServerState] = [:]
    /// The in-flight one-shot probe sweep, nil when idle. `startProbeSweep`
    /// coalesces onto it; `configure` cancels it because its target set is stale.
    private var sweepTask: Task<Void, Never>?
    /// Monotonic sweep identity so a finished (or cancelled) sweep can only
    /// clear its own registration, never a successor started after a
    /// reconfigure.
    private var sweepGeneration: UInt64 = 0
    /// Caller-supplied fetcher used by probe sweeps. Set inside
    /// `configure(serverURLs:fetcher:)` and only then. Left `nil` to make any
    /// pre-configure call to `startProbeSweep()` a no-op rather than fall back
    /// to a non-Tor `URLSession.shared`; that fallback would leak the device's
    /// IP to every vote server if a future refactor ever probed before
    /// configuring.
    private var probeFetcher: ProbeFetcher?

    // MARK: - Initialization

    init(cooldownInterval: TimeInterval = 30) {
        self.cooldownInterval = cooldownInterval
    }

    // MARK: - Configuration

    /// Replace the server map and probe fetcher for a freshly loaded service
    /// config. Cancels any in-flight sweep (its target set is stale) and resets
    /// every circuit to closed. Never probes — the polls list must never wait
    /// on operator health checks (MOB-1810); sweeps start at poll entry and
    /// submission start via `startProbeSweep()`.
    func configure(serverURLs: [String], fetcher: @escaping ProbeFetcher) {
        sweepTask?.cancel()
        sweepTask = nil
        sweepGeneration &+= 1
        servers = Dictionary(uniqueKeysWithValues: serverURLs.map { ($0, ServerState()) })
        probeFetcher = fetcher
    }

    // MARK: - Probe Sweep

    /// One-shot background sweep of every configured server. Returns as soon as
    /// the sweep Task is registered — callers never wait on probe results.
    /// While a sweep is in flight further calls coalesce into it and return
    /// nil; a call after completion starts a fresh sweep. Unconfigured (no
    /// fetcher, empty map) is a no-op returning nil. The returned Task exists
    /// so tests can await sweep completion.
    @discardableResult
    func startProbeSweep() -> Task<Void, Never>? {
        guard sweepTask == nil, probeFetcher != nil, !servers.isEmpty else { return nil }
        sweepGeneration &+= 1
        let generation = sweepGeneration
        let task = Task { [weak self] in
            await self?.probeAll()
            await self?.clearSweepTask(generation: generation)
        }
        sweepTask = task
        return task
    }

    private func clearSweepTask(generation: UInt64) {
        guard generation == sweepGeneration else { return }
        sweepTask = nil
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
    /// No-op until `configure(serverURLs:fetcher:)` has set the fetcher; this
    /// is what keeps probes routed through Tor whenever the user has it
    /// enabled, never the system URLSession.
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
                guard !Task.isCancelled else { continue }
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
}
#endif
