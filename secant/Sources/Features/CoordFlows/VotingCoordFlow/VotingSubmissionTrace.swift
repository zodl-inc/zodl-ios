#if VOTING_ENABLED
//
//  VotingSubmissionTrace.swift
//  Zashi
//

import Foundation

/// Per-step timing for the coinholder submission pipelines. One line per step when it ends,
/// `Voting trace end <step> <context> ms=<n>`, or `Voting trace failed <step> <context> ms=<n>
/// error=<description>` when it throws, at info level so the lines reach the exported logs. The
/// format matches the Android app's trace so runs on the two platforms read alike. `Totals`
/// accumulates per-step milliseconds across the concurrent bundle pipelines for the summary line
/// at the end of a submission.
enum VotingSubmissionTrace {
    typealias Sink = @Sendable (String) -> Void

    /// Production sink: the app log, exported with the diagnostics.
    static let info: Sink = { LoggerProxy.info($0) }

    /// The context every line carries: the first eight hex characters of the round id (public
    /// data), then the bundle and the proposal when the step belongs to one.
    static func context(roundId: String, bundleIndex: UInt32? = nil, proposalId: UInt32? = nil) -> String {
        var parts = ["round=\(roundId.prefix(8))"]
        if let bundleIndex {
            parts.append("bundle=\(bundleIndex)")
        }
        if let proposalId {
            parts.append("proposal=\(proposalId)")
        }
        return parts.joined(separator: " ")
    }

    static func endLine(step: String, context: String, milliseconds: Int64, detail: String? = nil) -> String {
        let base = "Voting trace end \(step) \(context) ms=\(milliseconds)"
        guard let detail else { return base }
        return "\(base) \(detail)"
    }

    static func failedLine(step: String, context: String, milliseconds: Int64, error: Error) -> String {
        "Voting trace failed \(step) \(context) ms=\(milliseconds) error=\(error.localizedDescription)"
    }

    /// Elapsed whole milliseconds since `start` on the continuous clock.
    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        milliseconds(since: start, until: ContinuousClock().now)
    }

    /// Elapsed whole milliseconds between two instants on the continuous clock.
    static func milliseconds(since start: ContinuousClock.Instant, until end: ContinuousClock.Instant) -> Int64 {
        let elapsed = end - start
        return Int64(elapsed.components.seconds) * 1000 + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Runs `body`, logs one line when it ends (either way), adds the elapsed time to `totals`
    /// under `step`, and returns or rethrows what `body` did.
    static func measure<T>(
        _ step: String,
        _ context: String,
        totals: Totals? = nil,
        sink: Sink = info,
        now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        _ body: () async throws -> T
    ) async throws -> T {
        let started = now()
        do {
            let result = try await body()
            let elapsed = milliseconds(since: started, until: now())
            sink(endLine(step: step, context: context, milliseconds: elapsed))
            await totals?.add(step, elapsed)
            return result
        } catch {
            let elapsed = milliseconds(since: started, until: now())
            sink(failedLine(step: step, context: context, milliseconds: elapsed, error: error))
            await totals?.add(step, elapsed)
            throw error
        }
    }

    /// Format the production summary for one complete vote submission.
    static func submissionSummary(
        context: String,
        bundleCount: UInt32,
        questionCount: Int,
        totalMilliseconds: Int64,
        totals: Totals
    ) async -> String {
        let stepTotals = await totals.summary([
            "votes", "sharesJoin", "prove", "witness", "sync", "broadcast", "confirm", "record", "deliver"
        ])
        return "Voting submission summary \(context) bundles=\(bundleCount) questions=\(questionCount) totalMs=\(totalMilliseconds) \(stepTotals)"
    }

    /// Per-step totals across the pipelines of one submission.
    actor Totals {
        private var milliseconds: [String: Int64] = [:]

        func add(_ step: String, _ value: Int64) {
            milliseconds[step, default: 0] += value
        }

        func value(_ step: String) -> Int64 {
            milliseconds[step] ?? 0
        }

        /// `stepMs=<n>` pairs for `steps`, in that order, zero for steps that never ran.
        func summary(_ steps: [String]) -> String {
            steps.map { "\($0)Ms=\(milliseconds[$0] ?? 0)" }.joined(separator: " ")
        }
    }
}
#endif
