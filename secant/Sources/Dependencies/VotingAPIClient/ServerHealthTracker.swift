import Foundation
import os

private let healthLogger = Logger(subsystem: "co.zodl.voting", category: "ServerHealthTracker")

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

    private var servers: [String: ServerState] = [:]
    private var probeTask: Task<Void, Never>?

    /// URLSession with a short timeout for health probes and share POSTs.
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    /// Populate the server map and run an initial parallel probe of all servers.
    /// Called when the CDN service config is loaded.
    func initialize(serverURLs: [String]) async {
        // Replace server map (preserving nothing from prior config)
        servers = Dictionary(uniqueKeysWithValues: serverURLs.map { ($0, ServerState()) })

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
            healthLogger.info("All servers unhealthy; falling back to full list")
            return Array(servers.keys)
        }
        return healthy
    }

    // MARK: - State Updates

    func recordSuccess(for url: String) {
        guard servers[url] != nil else { return }
        let previous = servers[url]!.circuit
        servers[url]!.circuit = .closed
        servers[url]!.consecutiveFailures = 0
        if previous != .closed {
            healthLogger.info("\(url, privacy: .public) recovered; circuit closed")
        }
    }

    func recordFailure(for url: String) {
        guard servers[url] != nil else { return }
        servers[url]!.consecutiveFailures += 1
        let failures = servers[url]!.consecutiveFailures

        if failures >= failureThreshold && servers[url]!.circuit == .closed {
            servers[url]!.circuit = .open(since: Date())
            healthLogger.warning("\(url, privacy: .public) circuit opened after \(failures) failures")
        } else if servers[url]!.circuit == .halfOpen {
            // halfOpen probe failed — re-open
            servers[url]!.circuit = .open(since: Date())
            healthLogger.warning("\(url, privacy: .public) half-open probe failed; circuit reopened")
        }
    }

    // MARK: - Health Probing

    /// Probe all servers in parallel with GET /shielded-vote/v1/status.
    func probeAll() async {
        let urls = Array(servers.keys)
        guard !urls.isEmpty else { return }

        await withTaskGroup(of: (String, Bool).self) { group in
            for url in urls {
                group.addTask { [probeSession] in
                    let ok = await Self.probe(url: url, session: probeSession)
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
    private static func probe(url: String, session: URLSession) async -> Bool {
        guard let endpoint = URL(string: "\(url)/shielded-vote/v1/status") else { return false }
        do {
            let (_, response) = try await session.data(from: endpoint)
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
