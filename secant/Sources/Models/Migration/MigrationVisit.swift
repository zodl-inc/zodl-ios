//
//  MigrationVisit.swift
//  zodl
//
//  What a given app-open is FOR, decided ONCE before any sync starts.
//
//  This is the app half of ZIP 318's session separation. The engine decides WHAT to do next
//  (`MigrationAdvanceStep`) but is explicitly memoryless about sessions — upstream's own words:
//  "enforcing the session separation is the CONSUMER's runtime policy". This type is that policy.
//
//  The rule: a waking session is used EITHER to sync the wallet OR to broadcast a due transfer,
//  never both, so a network observer cannot correlate a wallet's sync traffic with the transactions
//  it broadcasts.
//
//  WHY THIS IS DECIDED BEFORE SYNC STARTS, not by stopping sync afterwards. The app already has a
//  reactive gate (`isMigrationSyncBlocked`) that halts an in-flight sync for a broadcast, and that
//  gate is still there and still useful. But halting is too late for the privacy property: the
//  correlation exists the moment sync CONNECTS, not when it finishes. A session that starts syncing
//  and is then stopped has already produced exactly the traffic the separation is meant to prevent.
//  So the decision moves ahead of `start()`.
//
//  Preparations are deliberately NOT a send visit. Upstream is explicit that a preparation is proved
//  and broadcast at the same wake-up — it anchors to a fresh checkpoint at the tip like an ordinary
//  transaction, so nothing about it is timing-correlated with a pool crossing. Only TRANSFERS, whose
//  broadcast heights are the privacy schedule, earn a broadcast-only session.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// What this app-open is for. See the file header for the rule and why it is decided up front.
enum MigrationVisit: Equatable, Sendable {
    /// At least one account has a proven transfer DUE. This open is a broadcast session: it must
    /// not initiate sync.
    case send
    /// Nothing is due to broadcast. Sync normally; the prove sweep runs when sync reaches the tip.
    case sync
}

extension MigrationVisit {
    /// The wallet-wide decision from every account's advance step.
    ///
    /// Wallet-wide, not per-account, and that is deliberate: sync is a single wallet-level activity,
    /// so if ANY account is mid-broadcast the whole wallet must stay off the wire. A Zodl wallet and
    /// a Keystone wallet run independent plans but share one network identity.
    ///
    /// `nil` entries (an account with no stored run, or a read that failed) simply do not vote.
    static func decide(advanceSteps: [MigrationAdvanceStep?]) -> MigrationVisit {
        let hasDueBroadcast = advanceSteps.contains { step in
            if case .broadcast = step { return true }
            return false
        }
        return hasDueBroadcast ? .send : .sync
    }
}

// MARK: - R12 v1: send-priority scheduling

extension MigrationVisit {
    /// GROUND_RULES R12 v1 (send-priority, Lukas 2026-08-03): how far ahead of a scheduled send a
    /// session already belongs to the SEND rather than to sync.
    ///
    /// THE LIVELOCK THIS CLOSES (field, same day): every completed sync pass re-stamps
    /// `privacyBuffer` seconds of send-silence, so a user who opens the app more often than
    /// buffer+window NEVER broadcasts — and it selects exactly the anxious user opening Zodl to
    /// check whether the migration works. The rule in Lukas's own casework: send in 60 min → safe
    /// to sync; 20 min → still safe; inside the horizon → don't sync, deliver at the window, sync
    /// after. ZIP 318 is unaffected: the same silence surrounds the send — which side yields is
    /// scheduling, not exposure.
    ///
    /// "Safe to sync" means a pass can complete AND its silence stamp can fully expire before the
    /// window opens — hence buffer plus a sync allowance.
    static func syncSafetyHorizon(privacyBuffer: TimeInterval) -> TimeInterval {
        privacyBuffer + 120
    }

    /// Upgrades a `.sync` verdict to `.send` when the next scheduled send is inside the horizon.
    /// Pure, so the field discussion's 60/40/9-minute table is directly testable. A `.send` from
    /// `decide` passes through untouched; `nil` ETA (nothing headed to the wire) never upgrades.
    static func upgradedForImminence(
        _ visit: MigrationVisit,
        earliestSendETA: TimeInterval?,
        privacyBuffer: TimeInterval
    ) -> MigrationVisit {
        guard visit == .sync, let earliestSendETA else { return visit }
        return earliestSendETA <= syncSafetyHorizon(privacyBuffer: privacyBuffer) ? .send : .sync
    }

    /// The earliest moment a broadcast can actually go out, in seconds from now: the LATER of the
    /// next broadcast-bound transaction's own window and the standing silence stamp
    /// (`gateResidualSeconds`). `nil` when no signed/proved TRANSFER carries a schedule — the same
    /// transfers-only rule as `decide`, and for the same reason (see the file header): preparations
    /// are proved and broadcast at the same wake and are not timing-correlated, so they never claim
    /// a session ahead of time either.
    static func earliestSendETASeconds(
        statuses: [MigrationTransactionStatus],
        clock: MigrationChainClock,
        gateResidualSeconds: TimeInterval?
    ) -> TimeInterval? {
        let candidateMinutes = statuses.compactMap { status -> Int? in
            guard case MigrationTransactionStatus.Kind.transfer = status.kind else { return nil }
            switch status.state {
            case MigrationTransactionStatus.State.signed, MigrationTransactionStatus.State.proved:
                return MigrationETA.minutesFromNow(scheduledHeight: status.scheduledHeight, clock: clock)
            default:
                // Broadcast/mined are already on the wire; invalid never sends; awaitingSignature
                // needs a ceremony no amount of session-holding provides.
                return nil
            }
        }
        guard let windowMinutes = candidateMinutes.min() else { return nil }
        return max(TimeInterval(max(0, windowMinutes)) * 60, gateResidualSeconds ?? 0)
    }
}
