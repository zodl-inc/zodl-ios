//
//  MigrationTypeMappingTests.swift
//  zodlTests
//
//  Verifies the explicit converters between the app's Zatoshi-based migration types and the SDK's
//  UInt64-based `ZcashLightClientKit` migration types (see MigrationTypeMapping.swift).
//
//  The two type families share short names (MigrationState, NoteSplitProposal, …) and both modules
//  are imported here, so app types are referenced through `App*` typealiases and SDK types are fully
//  qualified as `ZcashLightClientKit.*`.
//

import Testing
import Foundation
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

private typealias AppNoteSplitProposal = zodl_internal.NoteSplitProposal
private typealias AppTransferProposal = zodl_internal.TransferProposal
private typealias AppMigrationSchedule = zodl_internal.MigrationSchedule
private typealias AppNetworkPrivacyOptions = zodl_internal.NetworkPrivacyOptions
private typealias AppMigrationProgress = zodl_internal.MigrationProgress
private typealias AppTransferResult = zodl_internal.TransferResult
private typealias AppAttentionReason = zodl_internal.AttentionReason
private typealias AppMigrationState = zodl_internal.MigrationState

@Suite
struct MigrationTypeMappingTests {
    // MARK: - App -> SDK

    @Test func noteSplitProposalAppToSDK() {
        let app = AppNoteSplitProposal(outputNotes: [Zatoshi(1), Zatoshi(2)], fee: Zatoshi(10_000))
        let sdk = app.sdk
        #expect(sdk.outputNotes == [1, 2])
        #expect(sdk.fee == 10_000)
    }

    @Test func transferProposalAppToSDK() {
        let app = AppTransferProposal(
            id: "t1",
            amount: Zatoshi(500),
            anchorHeight: 100,
            nextExecutableAfterHeight: 200,
            expiryHeight: 300
        )
        let sdk = app.sdk
        #expect(sdk.id == "t1")
        #expect(sdk.amount == 500)
        #expect(sdk.anchorHeight == 100)
        #expect(sdk.nextExecutableAfterHeight == 200)
        #expect(sdk.expiryHeight == 300)
    }

    @Test func migrationScheduleAppToSDK() {
        let app = AppMigrationSchedule(
            transfers: [
                AppTransferProposal(id: "t1", amount: Zatoshi(500), anchorHeight: 1, nextExecutableAfterHeight: 2, expiryHeight: 3)
            ],
            estimatedDurationHours: 6
        )
        let sdk = app.sdk
        #expect(sdk.transfers.count == 1)
        #expect(sdk.transfers.first?.amount == 500)
        #expect(sdk.estimatedDurationHours == 6)
    }

    @Test func networkPrivacyOptionsAppToSDK() {
        let app = AppNetworkPrivacyOptions(useTor: true, submissionEndpoint: "https://example")
        let sdk = app.sdk
        #expect(sdk.useTor == true)
        #expect(sdk.submissionEndpoint == "https://example")
    }

    @Test func networkPrivacyOptionsAppToSDKNilEndpoint() {
        let sdk = AppNetworkPrivacyOptions(useTor: false).sdk
        #expect(sdk.useTor == false)
        #expect(sdk.submissionEndpoint == nil)
    }

    // MARK: - SDK -> App

    @Test func noteSplitProposalSDKToApp() {
        let sdk = ZcashLightClientKit.NoteSplitProposal(outputNotes: [1, 2], fee: 10_000)
        let app = sdk.app
        #expect(app.outputNotes == [Zatoshi(1), Zatoshi(2)])
        #expect(app.fee == Zatoshi(10_000))
    }

    @Test func transferProposalSDKToApp() {
        let sdk = ZcashLightClientKit.TransferProposal(
            id: "t1",
            amount: 500,
            anchorHeight: 100,
            nextExecutableAfterHeight: 200,
            expiryHeight: 300
        )
        let app = sdk.app
        #expect(app.id == "t1")
        #expect(app.amount == Zatoshi(500))
        #expect(app.anchorHeight == 100)
        #expect(app.nextExecutableAfterHeight == 200)
        #expect(app.expiryHeight == 300)
    }

    @Test func migrationScheduleSDKToApp() {
        let sdk = ZcashLightClientKit.MigrationSchedule(
            transfers: [
                ZcashLightClientKit.TransferProposal(id: "t1", amount: 500, anchorHeight: 1, nextExecutableAfterHeight: 2, expiryHeight: 3)
            ],
            estimatedDurationHours: 6
        )
        let app = sdk.app
        #expect(app.transfers.count == 1)
        #expect(app.transfers.first?.amount == Zatoshi(500))
        #expect(app.estimatedDurationHours == 6)
    }

    @Test func migrationProgressSDKToApp() {
        let sdk = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 3,
            remainingOrchard: 1_000,
            nextTransferReadyAtHeight: 250
        )
        let app = sdk.app
        #expect(app.completedTransfers == 1)
        #expect(app.totalTransfers == 3)
        #expect(app.remainingOrchard == Zatoshi(1_000))
        #expect(app.nextTransferReadyAtHeight == 250)
    }

    @Test func migrationProgressSDKToAppNilHeight() {
        let sdk = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 3,
            totalTransfers: 3,
            remainingOrchard: 0,
            nextTransferReadyAtHeight: nil
        )
        #expect(sdk.app.nextTransferReadyAtHeight == nil)
    }

    @Test func transferResultSDKToAppAllCases() {
        #expect(ZcashLightClientKit.TransferResult.success(txid: "abc").app == AppTransferResult.success(txId: "abc"))
        #expect(ZcashLightClientKit.TransferResult.networkError(retryable: true).app == AppTransferResult.networkError(retryable: true))
        #expect(ZcashLightClientKit.TransferResult.networkError(retryable: false).app == AppTransferResult.networkError(retryable: false))
        #expect(ZcashLightClientKit.TransferResult.invalidNote.app == AppTransferResult.invalidNote)
        #expect(ZcashLightClientKit.TransferResult.expired.app == AppTransferResult.expired)
    }

    @Test func attentionReasonSDKToAppAllCases() {
        #expect(ZcashLightClientKit.AttentionReason.invalidTransfer(transferId: "t1").app == AppAttentionReason.invalidTransfer(transferId: "t1"))
        #expect(ZcashLightClientKit.AttentionReason.transferExpired.app == AppAttentionReason.transferExpired)
        #expect(ZcashLightClientKit.AttentionReason.syncRequiredBeforeNext.app == AppAttentionReason.syncRequiredBeforeNext)
    }

    @Test func migrationStateSDKToAppSimpleCases() {
        #expect(ZcashLightClientKit.MigrationState.notStarted.app == AppMigrationState.notStarted)
        #expect(ZcashLightClientKit.MigrationState.splitPendingConfirmation.app == AppMigrationState.splitPendingConfirmation)
        #expect(ZcashLightClientKit.MigrationState.readyToPropose.app == AppMigrationState.readyToPropose)
        #expect(ZcashLightClientKit.MigrationState.complete.app == AppMigrationState.complete)
    }

    @Test func migrationStateSDKToAppInProgress() {
        let sdkProgress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 2,
            remainingOrchard: 5,
            nextTransferReadyAtHeight: 10
        )
        let state = ZcashLightClientKit.MigrationState.inProgress(sdkProgress).app
        let expected = AppMigrationState.inProgress(
            AppMigrationProgress(completedTransfers: 1, totalTransfers: 2, remainingOrchard: Zatoshi(5), nextTransferReadyAtHeight: 10)
        )
        #expect(state == expected)
    }

    @Test func migrationStateSDKToAppRequiresAttention() {
        let state = ZcashLightClientKit.MigrationState.requiresAttention(.invalidTransfer(transferId: "t9")).app
        #expect(state == AppMigrationState.requiresAttention(.invalidTransfer(transferId: "t9")))
    }

    // MARK: - Scalar edge cases

    @Test func uint64AboveInt64MaxClampsToZatoshiMax() {
        let sdk = ZcashLightClientKit.NoteSplitProposal(outputNotes: [UInt64.max], fee: 0)
        #expect(sdk.app.outputNotes == [Zatoshi(Int64.max)])
    }

    @Test func negativeBlockHeightClampsToZeroUInt32() {
        let app = AppTransferProposal(id: "t", amount: Zatoshi(1), anchorHeight: -5, nextExecutableAfterHeight: -1, expiryHeight: 0)
        #expect(app.sdk.anchorHeight == 0)
        #expect(app.sdk.nextExecutableAfterHeight == 0)
    }
}
