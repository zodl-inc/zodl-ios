//
//  MigrationTypeMapping.swift
//  zodl
//
//  Explicit converters between the app's `Zatoshi`/`BlockHeight`-based migration value types
//  (Models/Migration/MigrationModels.swift) and the SDK's `UInt64`/`UInt32`-based migration types
//  (`ZcashLightClientKit.Model/Migration.swift`).
//
//  The two type families share short names (MigrationState, NoteSplitProposal, …), so SDK types are
//  always fully qualified as `ZcashLightClientKit.*`. This file is the single place the two meet.
//
//  Direction:
//  • `.sdk` on an app type produces the SDK type (used when calling the SDK).
//  • `.app` on a `ZcashLightClientKit` type produces the app type (used when caching SDK results).
//
//  Note: the app's `AttentionReason.transferStalled` case has no SDK counterpart — it is synthesized
//  by `LiveMigrationEngine` from `.inProgress` + an overdue flag, never decoded from an SDK value, so
//  it is absent from the `ZcashLightClientKit.AttentionReason -> app` mapping below by construction.
//

import Foundation
@preconcurrency import ZcashLightClientKit

// MARK: - Scalar conversions

/// `Zatoshi` is `Int64`-backed and always non-negative in practice; the SDK uses `UInt64`.
private func migrationZatoshiToUInt64(_ value: Zatoshi) -> UInt64 {
    UInt64(max(0, value.amount))
}

/// SDK `UInt64` zatoshi -> `Zatoshi`. Clamps values above `Int64.max` (never expected on-chain).
private func migrationUInt64ToZatoshi(_ value: UInt64) -> Zatoshi {
    Zatoshi(Int64(clamping: value))
}

/// `BlockHeight` is `Int`-backed; the SDK uses `UInt32`. Clamps negatives to 0 and overflow to `UInt32.max`.
private func migrationBlockHeightToUInt32(_ value: BlockHeight) -> UInt32 {
    UInt32(clamping: value)
}

/// SDK `UInt32` height -> `BlockHeight` (always fits in `Int`).
private func migrationUInt32ToBlockHeight(_ value: UInt32) -> BlockHeight {
    BlockHeight(value)
}

// MARK: - App -> SDK

extension NoteSplitProposal {
    var sdk: ZcashLightClientKit.NoteSplitProposal {
        ZcashLightClientKit.NoteSplitProposal(
            outputNotes: outputNotes.map(migrationZatoshiToUInt64),
            fee: migrationZatoshiToUInt64(fee)
        )
    }
}

extension TransferProposal {
    var sdk: ZcashLightClientKit.TransferProposal {
        ZcashLightClientKit.TransferProposal(
            id: id,
            amount: migrationZatoshiToUInt64(amount),
            anchorHeight: migrationBlockHeightToUInt32(anchorHeight),
            nextExecutableAfterHeight: migrationBlockHeightToUInt32(nextExecutableAfterHeight),
            expiryHeight: migrationBlockHeightToUInt32(expiryHeight)
        )
    }
}

extension MigrationSchedule {
    var sdk: ZcashLightClientKit.MigrationSchedule {
        ZcashLightClientKit.MigrationSchedule(
            transfers: transfers.map { $0.sdk },
            estimatedDurationHours: UInt32(clamping: estimatedDurationHours)
        )
    }
}

extension NetworkPrivacyOptions {
    var sdk: ZcashLightClientKit.NetworkPrivacyOptions {
        ZcashLightClientKit.NetworkPrivacyOptions(
            useTor: useTor,
            submissionEndpoint: submissionEndpoint
        )
    }
}

// MARK: - SDK -> App

extension ZcashLightClientKit.NoteSplitProposal {
    var app: NoteSplitProposal {
        NoteSplitProposal(
            outputNotes: outputNotes.map(migrationUInt64ToZatoshi),
            fee: migrationUInt64ToZatoshi(fee)
        )
    }
}

extension ZcashLightClientKit.TransferProposal {
    var app: TransferProposal {
        TransferProposal(
            id: id,
            amount: migrationUInt64ToZatoshi(amount),
            anchorHeight: migrationUInt32ToBlockHeight(anchorHeight),
            nextExecutableAfterHeight: migrationUInt32ToBlockHeight(nextExecutableAfterHeight),
            expiryHeight: migrationUInt32ToBlockHeight(expiryHeight)
        )
    }
}

extension ZcashLightClientKit.MigrationSchedule {
    var app: MigrationSchedule {
        MigrationSchedule(
            transfers: transfers.map { $0.app },
            estimatedDurationHours: Int(estimatedDurationHours)
        )
    }
}

extension ZcashLightClientKit.MigrationProgress {
    var app: MigrationProgress {
        MigrationProgress(
            completedTransfers: Int(completedTransfers),
            totalTransfers: Int(totalTransfers),
            remainingOrchard: migrationUInt64ToZatoshi(remainingOrchard),
            nextTransferReadyAtHeight: nextTransferReadyAtHeight.map(migrationUInt32ToBlockHeight)
        )
    }
}

extension ZcashLightClientKit.TransferResult {
    var app: TransferResult {
        switch self {
        case .success(let txid):
            return TransferResult.success(txId: txid)
        case .networkError(let retryable):
            return TransferResult.networkError(retryable: retryable)
        case .invalidNote:
            return TransferResult.invalidNote
        case .expired:
            return TransferResult.expired
        }
    }
}

extension ZcashLightClientKit.AttentionReason {
    var app: AttentionReason {
        switch self {
        case .invalidTransfer(let transferId):
            return AttentionReason.invalidTransfer(transferId: transferId)
        case .transferExpired:
            return AttentionReason.transferExpired
        case .syncRequiredBeforeNext:
            return AttentionReason.syncRequiredBeforeNext
        }
    }
}

extension ZcashLightClientKit.MigrationState {
    var app: MigrationState {
        switch self {
        case .notStarted:
            return MigrationState.notStarted
        case .splitPendingConfirmation:
            return MigrationState.splitPendingConfirmation
        case .readyToPropose:
            return MigrationState.readyToPropose
        case .inProgress(let progress):
            return MigrationState.inProgress(progress.app)
        case .requiresAttention(let reason):
            return MigrationState.requiresAttention(reason.app)
        case .complete:
            return MigrationState.complete
        }
    }
}
