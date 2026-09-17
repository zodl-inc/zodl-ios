#if VOTING_ENABLED
//
//  VotingTxConfirmationPoller.swift
//  Zashi
//

import Foundation

struct VotingTxConfirmationPollResult: Equatable, Sendable {
    let confirmation: TxConfirmation?
    let attempts: Int

    init(confirmation: TxConfirmation?, attempts: Int) {
        self.confirmation = confirmation
        self.attempts = attempts
    }
}

enum VotingTxConfirmationPoller {
    static func wait<C: Clock>(
        preferredServerURL: String?,
        timeout: Duration,
        retryDelay: Duration = .milliseconds(750),
        clock: C,
        fetch: @escaping @Sendable (String?, Duration) async throws -> TxConfirmation?
    ) async throws -> VotingTxConfirmationPollResult where C.Duration == Duration {
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        var attempts = 0
        var plan = TxConfirmationPollPlan()

        while clock.now < deadline {
            try Task.checkCancellation()
            let elapsed = start.duration(to: clock.now)
            let preferredServer = plan.preferredServer(acceptedBy: preferredServerURL, elapsed: elapsed)
            let remainingBudget = clock.now.duration(to: deadline)
            guard remainingBudget > .zero else {
                break
            }

            attempts += 1
            do {
                let confirmation = try await fetch(preferredServer, remainingBudget)
                try Task.checkCancellation()
                if preferredServerURL != nil, preferredServer == nil {
                    plan.fullSweepCompleted(at: start.duration(to: clock.now))
                }
                if let confirmation {
                    return VotingTxConfirmationPollResult(confirmation: confirmation, attempts: attempts)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }

            let remainingAfterFetch = clock.now.duration(to: deadline)
            guard remainingAfterFetch > .zero else {
                break
            }
            let sleepDuration = min(retryDelay, remainingAfterFetch)
            try await clock.sleep(for: sleepDuration)
            try Task.checkCancellation()
        }

        return VotingTxConfirmationPollResult(confirmation: nil, attempts: attempts)
    }
}
#endif
