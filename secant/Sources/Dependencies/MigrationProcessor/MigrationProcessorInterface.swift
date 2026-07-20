//
//  MigrationProcessorInterface.swift
//  ZODL
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import Combine

extension DependencyValues {
    var migrationProcessor: MigrationProcessorClient {
        get { self[MigrationProcessorClient.self] }
        set { self[MigrationProcessorClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationProcessorClient {
    // MARK: - State

    /// Full migration lifecycle state machine.
    enum Phase: Equatable {
        case unknown
        case notStarted
        /// SDK reported note split is required before a schedule can be proposed.
        case awaitingNoteSplitConfirm(NoteSplitProposalModel)
        /// Note split tx broadcast; waiting on-chain confirmation.
        case awaitingSplitConfirmation
        /// Notes ready; user needs to review and approve the transfer schedule.
        case proposalReview(MigrationScheduleModel)
        /// Active migration — one transfer per app open.
        case inProgress(MigrationProgressModel)
        /// SDK returned an error that requires user acknowledgement before retrying.
        case requiresAttention(AttentionReason)
        /// All transfers confirmed; migration complete.
        case complete
        case failed(ZcashError)
    }

    enum AttentionReason: Equatable {
        /// A transfer references notes already spent (e.g. from another device).
        case invalidTransfer
        /// Transfer expiry height passed before it was broadcast.
        case transferExpired
        /// Wallet must sync before the next transfer can be attempted.
        case syncRequired
    }

    // MARK: - Supporting models
    // These mirror the shapes in SDK PR #2006. Field names kept identical so wiring is a
    // search-and-replace once the SDK lands.

    struct NoteSplitProposalModel: Equatable {
        let outputNotes: [Int64]
        let feeSatoshi: Int64
    }

    struct MigrationScheduleModel: Equatable {
        let transfers: [TransferProposalModel]
        let estimatedDurationHours: Int
    }

    struct TransferProposalModel: Equatable {
        let id: String
        let amountZatoshi: Int64
        let nextExecutableAfterHeight: Int64
        let expiryHeight: Int64
    }

    struct MigrationProgressModel: Equatable {
        let completedTransfers: Int
        let totalTransfers: Int
        let remainingOrchardZatoshi: Int64
        /// Nil when the next transfer is already due.
        let nextTransferReadyAtHeight: Int64?
    }

    // MARK: - Client interface

    /// Observe migration phase changes. Subscribe once in Root; drive UI from emitted values.
    var observe: @Sendable () -> AnyPublisher<MigrationProcessorClient.Phase, Never> = {
        Empty().eraseToAnyPublisher()
    }

    /// Check migration state on every app open; emits updated phase to the publisher.
    var refresh: @Sendable () -> Void

    /// User confirmed the note-split proposal. Submits the split tx and transitions to
    /// `.awaitingSplitConfirmation`.
    var confirmNoteSplit: @Sendable (NoteSplitProposalModel) -> Void

    /// User approved the full migration schedule. Signs (or hands PCZT to Keystone) and
    /// transitions to `.inProgress`.
    var confirmSchedule: @Sendable (MigrationScheduleModel) -> Void

    /// Execute the next pending transfer for the current app open. Called after `confirmSchedule`
    /// and on each subsequent open while state is `.inProgress`.
    /// - Parameter useTor: Pass `true` (default). Expose a toggle in UI per design doc §9.3.
    var executeNextTransfer: @Sendable (_ useTor: Bool) -> Void

    /// Re-propose the current migration step after a recoverable failure. Transitions back to
    /// `.proposalReview`.
    var restart: @Sendable () -> Void
}
