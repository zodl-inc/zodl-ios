import Foundation

/// The shared ordered-mirror walk behind voting-config fetching.
///
/// Both config legs — the hash-pinned static trust anchor and the dynamic
/// round registry — try an ordered mirror list and differ only in what counts
/// as "try the next mirror". The loop mechanics live here once: first-error
/// retention (the canonical origin's failure is the one reported), fall-through
/// logging, and a single place for cancellation handling.
enum VotingConfigMirrorWalk {
    /// HTTP statuses below 500 that middlebox infrastructure — not the config
    /// publisher — answers with: censorship blocks (403, 451), proxies
    /// demanding auth (407), and rate limiting (429).
    ///
    /// Deliberate deviation from the token-holder-voting-config README, which
    /// limits fall-through to transport failures and 5xx ("must not fall
    /// through because it dislikes the content"): on exactly the filtered
    /// networks this feature exists for, the block arrives as one of these
    /// statuses, so treating them as authoritative would abort the walk before
    /// the mirror that works. Everything else below 500 (400, 404, 410, …)
    /// stays authoritative — the publisher answered, and every mirror would
    /// say the same thing.
    static let retryableClientStatusCodes: Set<Int> = [403, 407, 429, 451]

    /// Walk `mirrors` in order and return the first successful attempt.
    ///
    /// An error the predicate accepts is remembered (first one wins) and the
    /// walk continues; any other error is authoritative and propagates
    /// immediately. When every mirror fails, the first mirror's error is
    /// thrown; an empty list throws `emptyError`.
    ///
    /// Cancellation — a thrown CancellationError or URLError(.cancelled), or task cancellation between attempts — propagates immediately and is never treated as a mirror failure.
    /// Six parameters: the walk is the one place both mirror policies plug into, and splitting it would scatter them again.
    // swiftlint:disable:next function_parameter_count
    static func run<Mirror, Success>(
        mirrors: [Mirror],
        walkLabel: String,
        mirrorLabel: (Mirror) -> String,
        emptyError: VotingConfigError,
        shouldTryNext: (VotingConfigError) -> Bool,
        attempt: (Mirror) async throws -> Success
    ) async throws -> Success {
        var firstError: VotingConfigError?
        for mirror in mirrors {
            try Task.checkCancellation()
            do {
                return try await attempt(mirror)
            } catch let error as VotingConfigError where shouldTryNext(error) {
                if firstError == nil {
                    firstError = error
                }
                LoggerProxy.warn("\(walkLabel) mirror \(mirrorLabel(mirror)) failed, trying next: \(error)")
            }
        }
        if let firstError {
            throw firstError
        }
        throw emptyError
    }

    /// True when a dynamic-config failure is an availability answer from the
    /// network path rather than an authoritative answer from the publisher:
    /// a transport failure (no status), any 5xx, or a middlebox status.
    static func shouldTryNextDynamicMirror(_ error: VotingConfigError) -> Bool {
        guard case .dynamicConfigFetchFailed(_, let statusCode) = error else {
            return false
        }
        guard let statusCode else {
            return true
        }
        return statusCode >= 500 || retryableClientStatusCodes.contains(statusCode)
    }

    /// Fetch the dynamic config by walking `urls` in order.
    ///
    /// Fall-through follows `shouldTryNextDynamicMirror`; a plain 4xx, or
    /// bytes that later fail to decode or validate, is an authoritative answer
    /// from the config publisher and surfaces immediately. Returns the fetched
    /// bytes together with the origin URL that served them.
    static func fetchDynamicConfig(
        urls: [URL],
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, origin: URL) {
        try await run(
            mirrors: urls,
            walkLabel: "Dynamic config",
            mirrorLabel: { url in url.host ?? "<unknown>" },
            emptyError: VotingConfigError.decodeFailed("static config named no dynamic config URLs"),
            shouldTryNext: shouldTryNextDynamicMirror,
            attempt: { url in
                // Always re-fetch the config from the network instead of
                // trusting a persisted URLCache entry. Mobile restarts during a
                // round rollover can otherwise keep an old round binding alive
                // long enough to brick voting on launch.
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.timeoutInterval = StaticVotingConfig.configRequestTimeout
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")

                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await fetch(request)
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == URLError.Code.cancelled {
                        throw error
                    }
                    throw VotingConfigError.dynamicConfigFetchFailed(
                        "CDN fetch failed: \(error.localizedDescription)",
                        statusCode: nil
                    )
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw VotingConfigError.dynamicConfigFetchFailed(
                        "CDN returned HTTP \(http.statusCode)",
                        statusCode: http.statusCode
                    )
                }
                return (data, url)
            }
        )
    }
}
