//
//  MigrationCadence.swift
//  Zashi
//
//  Pure background-wakeup timing math for the Orchard -> Ironwood migration (MOB-1467, §8.3).
//  `window(margin:preferredExecutableAt:now:)` is the single formula both `scheduleFirstWindow`
//  and `scheduleNextWindow` use in the `MigrationBGSchedulerClient` LiveKey — only the margin
//  constant differs between them. Table-tested directly, no SDK dependency (see
//  MigrationCadenceTests).
//
//  MOB-1496 (W5): `planRearm(_:)` is the multi-account counterpart — `MigrationBGSchedulerImpl
//  .arm(margin:)` now fans out over every candidate account, and this pure reduction picks the
//  earliest-across-accounts height (+ a representative non-complete state and its transfer number)
//  that `window(margin:preferredExecutableAt:now:)`/`WakeupAction.decide` then consume unchanged —
//  mirrors `WakeupAction.decide`'s own "pure decision, effectful caller" split.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum MigrationCadence {
    static let firstWindowMargin: TimeInterval = 30 * 60          // §8.3
    static let nextWindowMargin: TimeInterval = 6.5 * 60 * 60     // §8.3

    /// earliestBeginDate for the next wakeup. The SDK's per-transfer executable time is
    /// authoritative when known; the app margin is both the fallback (used whenever the SDK can't
    /// resolve a preferred time, e.g. `estimateTimestamp` returns `nil`) and a floor (never wake
    /// before the margin — §8.3's 30 min/6.5 h cushions over the SDK's ~10 min/~6 h expectations).
    static func window(margin: TimeInterval, preferredExecutableAt: Date?, now: Date) -> Date {
        max(preferredExecutableAt ?? Date.distantPast, now.addingTimeInterval(margin))
    }

    // MARK: - MOB-1496 (W5): multi-account re-arm reduction

    /// One candidate account's SDK-observed migration data, as `arm(margin:)` gathers it across
    /// every candidate account before reducing to the earliest window via `planRearm`.
    struct AccountRearmInput: Equatable {
        let state: MigrationState
        let progress: MigrationProgress?
        /// The `rescheduleOverdueMigrationTransfer` probe's height, when a proposal exists —
        /// preferred over `progress?.nextTransferReadyAtHeight` (see `planRearm`'s doc).
        let nextExecutableAfterHeight: BlockHeight?
    }

    struct RearmPlan: Equatable {
        /// `.complete` exactly when no account has an active run (mirrors the BG session tree's own
        /// EVERY-account-complete/notStarted cancel-all trigger) — any other account's genuine,
        /// non-complete/non-notStarted state otherwise. WHICH one doesn't matter: `WakeupAction
        /// .decide` only ever branches on `== .complete`.
        let representativeState: MigrationState
        let earliestNextExecutableAfterHeight: BlockHeight?
        let nextTransferNumber: Int
    }

    /// Reduces one `AccountRearmInput` per candidate account down to the single earliest-across-
    /// accounts height (+ representative state/next-transfer-number) `arm(margin:)` feeds into
    /// `window(margin:preferredExecutableAt:now:)` / `WakeupAction.decide`, both unchanged.
    /// `.complete`/`.notStarted` accounts have no active run and contribute nothing. Every other
    /// account's height is `nextExecutableAfterHeight` when known, else `progress?
    /// .nextTransferReadyAtHeight`; the minimum wins. A tie, or an active account with neither
    /// height available, keeps whichever the loop reached first — callers pass accounts selected-
    /// first, matching the BG session tree's own tie-break precedence.
    static func planRearm(_ accounts: [AccountRearmInput]) -> RearmPlan {
        var representativeState = MigrationState.complete
        var earliestHeight: BlockHeight?
        var nextTransferNumber = 1

        for account in accounts {
            guard account.state != MigrationState.complete, account.state != MigrationState.notStarted else { continue }
            representativeState = account.state

            guard let height = account.nextExecutableAfterHeight ?? account.progress?.nextTransferReadyAtHeight else { continue }

            let isEarlier = earliestHeight.map { height < $0 } ?? true
            guard isEarlier else { continue }

            earliestHeight = height
            nextTransferNumber = (account.progress?.completedTransfers ?? 0) + 1
        }

        return RearmPlan(
            representativeState: representativeState,
            earliestNextExecutableAfterHeight: earliestHeight,
            nextTransferNumber: nextTransferNumber
        )
    }
}
