//
//  MigrationModelsTests.swift
//  zodlTests
//
//  Covers Codable round-trips and basic invariants for the Orchard -> Ironwood migration
//  value models (Models/Migration/MigrationModels.swift). No shared/global state -> no
//  `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationModelsTests {
    @Test func migrationModeCodableRoundTrip() throws {
        for mode in [MigrationMode.immediate, MigrationMode.privateScheduled] {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(MigrationMode.self, from: data) == mode)
        }
    }

    @Test func networkPrivacyOptionsCodableRoundTripWithNilEndpoint() throws {
        let original = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(NetworkPrivacyOptions.self, from: data) == original)
    }

    @Test func networkPrivacyOptionsCodableRoundTripWithNonNilEndpoint() throws {
        let original = NetworkPrivacyOptions(useTor: false, submissionEndpoint: "https://example.com:9067")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(NetworkPrivacyOptions.self, from: data) == original)
    }

    @Test func transferResultCodableRoundTripAllCases() throws {
        let cases: [TransferResult] = [
            TransferResult.success(txId: "abc123"),
            TransferResult.networkError(retryable: true),
            TransferResult.invalidNote,
            TransferResult.expired
        ]

        for original in cases {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(TransferResult.self, from: data) == original)
        }
    }

    @Test func attentionReasonCodableRoundTripAllCases() throws {
        let cases: [AttentionReason] = [
            AttentionReason.invalidTransfer(transferId: "transfer-1"),
            AttentionReason.transferExpired,
            AttentionReason.syncRequiredBeforeNext,
            AttentionReason.transferStalled(transferNumber: 3)
        ]

        for original in cases {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(AttentionReason.self, from: data) == original)
        }
    }

    @Test func migrationStateCodableRoundTripAllCases() throws {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 123_456
        )

        let cases: [MigrationState] = [
            MigrationState.notStarted,
            MigrationState.splitPendingConfirmation,
            MigrationState.readyToPropose,
            MigrationState.inProgress(progress),
            MigrationState.requiresAttention(AttentionReason.transferExpired),
            MigrationState.complete
        ]

        for original in cases {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(MigrationState.self, from: data) == original)
        }
    }

    @Test func migrationScheduleCodableRoundTripWithNonTrivialTransferGraph() throws {
        let transfers = [
            TransferProposal(
                id: "transfer-1",
                amount: Zatoshi(500),
                anchorHeight: 100,
                nextExecutableAfterHeight: 110,
                expiryHeight: 200
            ),
            TransferProposal(
                id: "transfer-2",
                amount: Zatoshi(1_500),
                anchorHeight: 110,
                nextExecutableAfterHeight: 220,
                expiryHeight: 310
            ),
            TransferProposal(
                id: "transfer-3",
                amount: Zatoshi(2_500),
                anchorHeight: 220,
                nextExecutableAfterHeight: 330,
                expiryHeight: 420
            )
        ]
        let original = MigrationSchedule(transfers: transfers, estimatedDurationHours: 72)

        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MigrationSchedule.self, from: data) == original)
    }

    @Test func migrationTransferRowCodableRoundTripEachStatus() throws {
        let statuses: [MigrationTransferRow.Status] = [
            MigrationTransferRow.Status.sent,
            MigrationTransferRow.Status.active,
            MigrationTransferRow.Status.overdue,
            MigrationTransferRow.Status.pending,
            MigrationTransferRow.Status.invalid,
            MigrationTransferRow.Status.expired
        ]

        for (index, status) in statuses.enumerated() {
            let original = MigrationTransferRow(
                id: "row-\(index)",
                index: index,
                amount: Zatoshi(Int64(100 * (index + 1))),
                status: status,
                hoursFromNow: index
            )
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(MigrationTransferRow.self, from: data) == original)
        }
    }

    @Test func migrationSummaryZeroIsAllZero() {
        let zero = MigrationSummary.zero
        #expect(zero.transferred == Zatoshi.zero)
        #expect(zero.dust == Zatoshi.zero)
        #expect(zero.transfersSent == 0)
        #expect(zero.transfersTotal == 0)
        #expect(zero.estimatedDurationHours == 0)
    }

    @Test func transferProposalIdDrivesIdentifiable() {
        let proposal = TransferProposal(
            id: "transfer-42",
            amount: Zatoshi(999),
            anchorHeight: 10,
            nextExecutableAfterHeight: 20,
            expiryHeight: 30
        )
        #expect(proposal.id == "transfer-42")
    }
}
