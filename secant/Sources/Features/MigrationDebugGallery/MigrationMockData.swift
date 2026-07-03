//
//  MigrationMockData.swift
//  zodl
//
//  DEBUG-only fixtures for the Ironwood migration screens gallery (MOB-1465). Values mirror the
//  Figma frames / each screen's own `#Preview` states so visual parity holds between the gallery
//  and the screens' previews. Deduplicating the previews themselves onto this namespace is
//  deliberately deferred (see MOB-1465 spec) — no churn on in-review migration screen PRs.
//

#if DEBUG

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// Centralized fixture values for `MigrationDebugGalleryView`.
enum MigrationMockData {
    // MARK: - Shared amounts

    static let fiatText = "$4,832.86"
    static let orchardBalance = Zatoshi(1_245_800_000)
    static let fee = Zatoshi(100_000)
    static let txId = "e87f1c02a94b7d3e6f5041c9b8a2d7e6f5041c9b8a2d7e6f5041c9b8a2d7e6f5"

    /// The 5-transfer set from the Figma frames: 3.51220 / 2.87410 / 2.43100 / 1.99830 / 1.64240 ZEC.
    static var freshRows: IdentifiedArrayOf<MigrationTransferRow> {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .active, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .pending, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 24)
        ]
    }

    /// The re-created variant's frame: two already sent, one active, two pending.
    static var recreatedRows: IdentifiedArrayOf<MigrationTransferRow> {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 17),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 0),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 6),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 12)
        ]
    }

    /// Status progress frame: two sent, one active, two pending.
    static var progressRows: IdentifiedArrayOf<MigrationTransferRow> {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 6),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 18)
        ]
    }

    /// The resume/re-scheduling frame: two sent, one overdue, two pending.
    static var resumeRows: IdentifiedArrayOf<MigrationTransferRow> {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 11),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 1),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 7)
        ]
    }

    // MARK: - Entry & Network Privacy

    static var entryPrivacy: MigrationEntry.State {
        MigrationEntry.State(
            selectedMode: .privateScheduled,
            orchardBalance: orchardBalance,
            fiatText: fiatText
        )
    }

    static var entryImmediate: MigrationEntry.State {
        MigrationEntry.State(
            selectedMode: .immediate,
            orchardBalance: orchardBalance,
            fiatText: fiatText
        )
    }

    static var networkPrivacyImmediate: MigrationNetworkPrivacy.State {
        MigrationNetworkPrivacy.State(variant: .immediate)
    }

    static var networkPrivacyScheduled: MigrationNetworkPrivacy.State {
        MigrationNetworkPrivacy.State(variant: .scheduled(transferCount: 5), isTorOn: true)
    }

    // MARK: - Note Split

    static var noteSplitExplainer: MigrationNoteSplit.State {
        MigrationNoteSplit.State(phase: .explainer, amount: orchardBalance, fee: fee)
    }

    static var noteSplitSplitting: MigrationNoteSplit.State {
        MigrationNoteSplit.State(phase: .splitting, amount: orchardBalance, fee: fee, txId: txId)
    }

    static var noteSplitConfirmed: MigrationNoteSplit.State {
        MigrationNoteSplit.State(phase: .confirmed, amount: orchardBalance, fee: fee, txId: txId)
    }

    static var noteSplitFailure: MigrationNoteSplit.State {
        MigrationNoteSplit.State(
            phase: .splitting,
            amount: orchardBalance,
            fee: fee,
            txId: txId,
            isFailurePresented: true
        )
    }

    // MARK: - Permissions

    static var backgroundDelivery: MigrationBackgroundDelivery.State {
        MigrationBackgroundDelivery.State()
    }

    static var notificationsScheduled: MigrationNotifications.State {
        MigrationNotifications.State(variant: .scheduled)
    }

    static var notificationsManual: MigrationNotifications.State {
        MigrationNotifications.State(variant: .manual)
    }

    // MARK: - Plan & Review

    static var planScheduled: MigrationTransferPlan.State {
        MigrationTransferPlan.State(variant: .scheduled, rows: freshRows, totalDurationHours: 24)
    }

    static var planManual: MigrationTransferPlan.State {
        MigrationTransferPlan.State(variant: .manual, rows: freshRows, totalDurationHours: 24)
    }

    static var planRecreated: MigrationTransferPlan.State {
        MigrationTransferPlan.State(variant: .recreated, rows: recreatedRows, totalDurationHours: 12)
    }

    static var reviewImmediate: MigrationReviewTransfer.State {
        MigrationReviewTransfer.State(mode: .immediate, amount: orchardBalance, fee: fee)
    }

    static var reviewManualStep: MigrationReviewTransfer.State {
        MigrationReviewTransfer.State(
            mode: .manualStep(number: 3, total: 5),
            amount: Zatoshi(243_100_000),
            fee: fee
        )
    }

    // MARK: - Sending & Scheduled

    static var sending: MigrationSending.State {
        MigrationSending.State(phase: .sending)
    }

    static var sent: MigrationSending.State {
        MigrationSending.State(phase: .success, txId: txId)
    }

    static var sendingFailure: MigrationSending.State {
        MigrationSending.State(phase: .sending, isFailurePresented: true)
    }

    static var migrationScheduled: MigrationScheduled.State {
        MigrationScheduled.State(totalAmount: orchardBalance, sentCount: 0, totalCount: 5, durationHours: 24)
    }

    // MARK: - Status, Recovery & Complete

    static var statusProgress: MigrationStatus.State {
        MigrationStatus.State(presentation: .progress, rows: progressRows, totalDurationHours: 24)
    }

    static var statusResume: MigrationStatus.State {
        MigrationStatus.State(
            presentation: .resume,
            rows: resumeRows,
            totalDurationHours: 24,
            stalledNumber: 3,
            stalledHoursAgo: 5
        )
    }

    static var statusRescheduling: MigrationStatus.State {
        MigrationStatus.State(
            presentation: .resume,
            rows: resumeRows,
            totalDurationHours: 24,
            stalledNumber: 3,
            stalledHoursAgo: 5,
            isRescheduling: true
        )
    }

    static var recoveryNotesSpent: MigrationRecovery.State {
        MigrationRecovery.State(reason: .notesSpent, firstTransfer: 3, lastTransfer: 5)
    }

    static var recoveryExpired: MigrationRecovery.State {
        MigrationRecovery.State(reason: .expired, firstTransfer: 3, lastTransfer: 5)
    }

    static var completeWithDust: MigrationComplete.State {
        MigrationComplete.State(
            totalTransferred: orchardBalance,
            dust: Zatoshi(31_000),
            transfersSent: 5,
            transfersTotal: 5,
            durationHours: 24
        )
    }

    static var completeClean: MigrationComplete.State {
        MigrationComplete.State(
            totalTransferred: orchardBalance,
            dust: .zero,
            transfersSent: 5,
            transfersTotal: 5,
            durationHours: 24
        )
    }
}

#endif
