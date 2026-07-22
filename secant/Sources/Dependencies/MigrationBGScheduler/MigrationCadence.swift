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
//  R8-T5 (#8, S4): `AccountRearmInput.isUnreadable` marks an account whose SDK reads threw inside
//  `arm(margin:)` — conservative-active rather than dropped, so `representativeState` can never
//  wrongly resolve `.complete` while its true state is unknown (see `RearmPlan`'s doc). `RearmPlan
//  .winnerAccountUUID` carries which account `nextTransferNumber` came from, so the manual-delivery
//  "ready to send" notification `arm(margin:)` schedules can be attributed to the right account.
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
        let accountUUID: AccountUUID
        let state: MigrationState
        let progress: MigrationProgress?
        /// The `rescheduleOverdueMigrationTransfer` probe's height, when a proposal exists —
        /// preferred over `progress?.nextTransferReadyAtHeight` (see `planRearm`'s doc).
        let nextExecutableAfterHeight: BlockHeight?
        /// R8-T5 (#8): true when `arm(margin:)`'s SDK read for this account threw — see that catch
        /// branch's doc. `state`/`progress`/`nextExecutableAfterHeight` are unused placeholders when
        /// this is `true`; `planRearm` checks this FIRST and never consults them.
        var isUnreadable: Bool = false
    }

    struct RearmPlan: Equatable {
        /// `.complete` exactly when no account has an active run (mirrors the BG session tree's own
        /// EVERY-account-complete/notStarted cancel-all trigger) — any other account's genuine,
        /// non-complete/non-notStarted state otherwise. WHICH one doesn't matter: `WakeupAction
        /// .decide` only ever branches on `== .complete`.
        ///
        /// R8-T5 (#8): an `isUnreadable` account ALSO keeps this from resolving `.complete` — its
        /// true state is unknown, so it is conservatively treated as active, mirroring the BG
        /// session tree's own `MigrationAccountClassification.unreadable`
        /// (`RootInitialization.swift`'s `isDoneClassification`: `.unreadable` deliberately does NOT
        /// count as done, blocking a premature `cancelAll`). Before this fix, `arm(margin:)`'s catch
        /// branch simply DROPPED a throwing account from `rearmInputs` instead of contributing an
        /// entry here at all — a dropped account could never block `.complete` resolution, so a
        /// transient read failure on an account with an active run could wrongly satisfy "every
        /// account done" and trigger `WakeupAction.cancelAll`, cancelling the BG request AND every
        /// migration notification out from under that still-running account.
        let representativeState: MigrationState
        let earliestNextExecutableAfterHeight: BlockHeight?
        let nextTransferNumber: Int
        /// R8-T5 (S4): the account `nextTransferNumber` (the resolvable-height branch, or its R8-T3
        /// #16 fallback) was actually sourced from — so the manual-delivery "ready to send"
        /// notification can carry the RIGHT account instead of composing for this winner but
        /// leaving the payload account-less (S4). Only ever a genuinely-readable, active account —
        /// an `isUnreadable` entry contributes NOTHING here (its real transfer number is unknown, so
        /// attributing one to it would be a fabrication a genuinely active account's own number must
        /// never be overwritten by). `nil` when no readable active account ever contributed (no
        /// accounts, every account `.complete`/`.notStarted`, or — R8-T5 #8 — every account
        /// unreadable): a nil payload is the honest value there, and routes as today's account-less
        /// behavior on tap (S4-c).
        let winnerAccountUUID: AccountUUID?
    }

    /// Reduces one `AccountRearmInput` per candidate account down to the single earliest-across-
    /// accounts height (+ representative state/next-transfer-number) `arm(margin:)` feeds into
    /// `window(margin:preferredExecutableAt:now:)` / `WakeupAction.decide`, both unchanged.
    /// `.complete`/`.notStarted` accounts have no active run and contribute nothing. Every other
    /// account's height is `nextExecutableAfterHeight` when known, else `progress?
    /// .nextTransferReadyAtHeight`; the minimum wins. A tie, or an active account with neither
    /// height available, keeps whichever the loop reached first — callers pass accounts selected-
    /// first, matching the BG session tree's own tie-break precedence.
    ///
    /// R8-T3 (#16): `nextTransferNumber` used to be assigned ONLY inside the height-resolution
    /// branch below, so an active account whose height is unresolvable on BOTH sources left it
    /// stranded at the loop's initial `1` regardless of `completedTransfers` — the BG-scheduled
    /// manual-ready notification then read "Transfer 1" instead of "Transfer N". `fallbackTransferNumber`
    /// restores the pre-PR floor (unconditional `completedTransfers + 1`, `git show 1c3ef253 --
    /// Dependencies/MigrationBGScheduler/MigrationCadence.swift`) by tracking the last active
    /// account's own next-transfer-number alongside `representativeState` (same "whichever, it
    /// doesn't matter which" tie-break); it's used only when NO account anywhere resolved a height
    /// (`earliestHeight == nil`) — the resolvable path's `nextTransferNumber` (set exclusively
    /// inside the height-resolution branch, never touched by a later account that merely re-sets
    /// the fallback) is unchanged.
    static func planRearm(_ accounts: [AccountRearmInput]) -> RearmPlan {
        var representativeState = MigrationState.complete
        var earliestHeight: BlockHeight?
        var nextTransferNumber = 1
        var fallbackTransferNumber = 1
        var winnerAccountUUID: AccountUUID?
        var fallbackAccountUUID: AccountUUID?

        for account in accounts {
            // R8-T5 (#8): conservative-active — an unreadable account's true state is unknown, so it
            // keeps `representativeState` from ever resolving `.complete` (see `RearmPlan`'s doc),
            // but contributes nothing else: no fallback/winner account, no transfer number. Checked
            // FIRST, before any of `state`/`progress`/`nextExecutableAfterHeight` (all placeholders
            // for this entry) are consulted.
            guard !account.isUnreadable else {
                representativeState = MigrationState.readyToPropose
                continue
            }

            guard account.state != MigrationState.complete, account.state != MigrationState.notStarted else { continue }
            representativeState = account.state
            fallbackTransferNumber = (account.progress?.completedTransfers ?? 0) + 1
            fallbackAccountUUID = account.accountUUID

            guard let height = account.nextExecutableAfterHeight ?? account.progress?.nextTransferReadyAtHeight else { continue }

            let isEarlier = earliestHeight.map { height < $0 } ?? true
            guard isEarlier else { continue }

            earliestHeight = height
            nextTransferNumber = (account.progress?.completedTransfers ?? 0) + 1
            winnerAccountUUID = account.accountUUID
        }

        return RearmPlan(
            representativeState: representativeState,
            earliestNextExecutableAfterHeight: earliestHeight,
            nextTransferNumber: earliestHeight != nil ? nextTransferNumber : fallbackTransferNumber,
            winnerAccountUUID: earliestHeight != nil ? winnerAccountUUID : fallbackAccountUUID
        )
    }
}
