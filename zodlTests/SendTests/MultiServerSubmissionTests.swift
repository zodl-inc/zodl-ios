//
//  MultiServerSubmissionTests.swift
//  secantTests
//
//  Created by Michal Fousek on 2026-06-12.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// MARK: - Endpoint selection

@Suite struct MultiServerSubmissionEndpointSelectionTests {
    private func preferences(automaticServerSelection: Bool?) -> UserPreferencesStorageClient {
        var preferences = UserPreferencesStorageClient()
        preferences.automaticServerSelection = { automaticServerSelection }
        return preferences
    }

    private func environment(networkType: NetworkType, endpointHost: String) -> ZcashSDKEnvironment {
        var environment = ZcashSDKEnvironment.test()
        environment.endpoint = { LightWalletEndpoint(address: endpointHost, port: 443) }
        environment.network = { ZcashNetworkBuilder.network(for: networkType) }
        return environment
    }

    @Test func automaticModeUsesAllKnownMainnetServers() {
        let endpoints = SDKSynchronizerClient.selectedSubmissionEndpoints(
            userStoredPreferences: preferences(automaticServerSelection: true),
            zcashSDKEnvironment: environment(networkType: .mainnet, endpointHost: "fallback.server")
        )

        // Hardcoded on purpose: comparing against `ZcashSDKEnvironment.endpoints(for:)` would
        // pass even if the known-server list shrank or changed, since the implementation
        // returns exactly that call.
        #expect(
            endpoints.map { $0.server() } == [
                "zec.rocks:443",
                "na.zec.rocks:443",
                "sa.zec.rocks:443",
                "eu.zec.rocks:443",
                "ap.zec.rocks:443",
                "us.zec.stardust.rest:443",
                "eu.zec.stardust.rest:443"
            ]
        )
    }

    @Test func manualModeUsesSelectedServerOnly() {
        let endpoints = SDKSynchronizerClient.selectedSubmissionEndpoints(
            userStoredPreferences: preferences(automaticServerSelection: false),
            zcashSDKEnvironment: environment(networkType: .mainnet, endpointHost: "manual.server")
        )

        #expect(endpoints.map { $0.server() } == ["manual.server:443"])
    }

    @Test func uninitializedModeFallsBackToCurrentEnvironmentEndpoint() {
        let endpoints = SDKSynchronizerClient.selectedSubmissionEndpoints(
            userStoredPreferences: preferences(automaticServerSelection: nil),
            zcashSDKEnvironment: environment(networkType: .mainnet, endpointHost: "fallback.server")
        )

        #expect(endpoints.map { $0.server() } == ["fallback.server:443"])
    }
}

// MARK: - Outcome mapping

@Suite struct MultiServerSubmissionOutcomeMappingTests {
    private let endpoints = [
        LightWalletEndpoint(address: "private.wallet.node", port: 9067),
        LightWalletEndpoint(address: "server2", port: 443),
        LightWalletEndpoint(address: "server3", port: 443)
    ]

    private let txIdA = Data([0xAA]).toHexStringTxId()
    private let txIdB = Data([0xBB]).toHexStringTxId()
    private let txIdC = Data([0xCC]).toHexStringTxId()

    private let timeoutDescription = SDKSynchronizerClient.MultiServerSubmission.timeoutDescription

    private func map(
        txIds: [String],
        outcomes: [TransactionSubmissionOutcome]
    ) -> SDKSynchronizerClient.CreateProposedTransactionsResult {
        SDKSynchronizerClient.mapSubmissionOutcomes(txIds: txIds, outcomes: outcomes, endpoints: endpoints)
    }

    @Test func allAcceptedMapsToSuccess() {
        let result = map(
            txIds: [txIdA, txIdB],
            outcomes: [.accepted(by: endpoints[0]), .accepted(by: endpoints[1])]
        )

        #expect(result == .success(txIds: [txIdA, txIdB]))
    }

    @Test func singleRejectedMapsToFailure() {
        let result = map(
            txIds: [txIdA],
            outcomes: [.rejected(code: -25, message: "bad-txns-inputs-missingorspent")]
        )

        #expect(result == .failure(txIds: [txIdA], code: -25, description: "bad-txns-inputs-missingorspent"))
    }

    @Test func rejectedFirstTransactionInBatchMapsToFailure() {
        // A rejection with no acceptances maps to .failure even when later
        // transactions were not attempted, matching the previous implementation.
        let result = map(
            txIds: [txIdA, txIdB],
            outcomes: [.rejected(code: -25, message: "bad-txns-inputs-missingorspent"), .notAttempted]
        )

        #expect(result == .failure(txIds: [txIdA, txIdB], code: -25, description: "bad-txns-inputs-missingorspent"))
    }

    @Test func singleUnreachableMapsToPlainGrpcFailure() {
        let result = map(txIds: [txIdA], outcomes: [.unreachable])

        #expect(result == .grpcFailure(txIds: [txIdA]))
    }

    @Test func singleCancelledMapsLikeUnreachable() {
        let result = map(txIds: [txIdA], outcomes: [.cancelled])

        #expect(result == .grpcFailure(txIds: [txIdA]))
    }

    @Test func singleTimeoutMapsToTimeoutGrpcFailure() {
        let result = map(txIds: [txIdA], outcomes: [.timedOut])

        #expect(result == .grpcFailure(txIds: [txIdA], reason: .timeout))
    }

    @Test func unreachableFirstTransactionInBatchWithNoAcceptanceMapsToGrpcFailure() {
        // Zero acceptances must never read as "partially accepted": trailing `.notAttempted`
        // reports are ignored the same way the `.rejected` branch ignores them.
        let result = map(txIds: [txIdA, txIdB], outcomes: [.unreachable, .notAttempted])

        #expect(result == .grpcFailure(txIds: [txIdA, txIdB]))
    }

    @Test func cancelledFirstTransactionInBatchMapsToGrpcFailureLikeUnreachable() {
        let result = map(txIds: [txIdA, txIdB], outcomes: [.cancelled, .notAttempted])

        #expect(result == .grpcFailure(txIds: [txIdA, txIdB]))
    }

    @Test func timeoutFirstTransactionInBatchWithNoAcceptanceMapsToTimeoutGrpcFailure() {
        let result = map(txIds: [txIdA, txIdB], outcomes: [.timedOut, .notAttempted])

        #expect(result == .grpcFailure(txIds: [txIdA, txIdB], reason: .timeout))
    }

    @Test func acceptanceAfterTransportFailureMapsToPartial() {
        // With per-transaction submission a later transaction can be accepted after an
        // earlier one failed, so acceptances are counted across the whole batch, not
        // just the prefix before the first failure.
        let result = map(txIds: [txIdA, txIdB], outcomes: [.timedOut, .accepted(by: endpoints[0])])

        #expect(
            result == .partial(
                txIds: [txIdA, txIdB],
                statuses: [timeoutDescription, "accepted by endpoint 1"]
            )
        )
    }

    @Test func cancelledStatusIsDistinctFromUnreachable() {
        let result = map(txIds: [txIdA, txIdB], outcomes: [.accepted(by: endpoints[0]), .cancelled])

        #expect(
            result == .partial(
                txIds: [txIdA, txIdB],
                statuses: ["accepted by endpoint 1", "submission cancelled"]
            )
        )
    }

    @Test func acceptedThenRejectedMapsToPartialWithRedactedStatuses() {
        let result = map(
            txIds: [txIdA, txIdB, txIdC],
            outcomes: [
                .accepted(by: endpoints[0]),
                .rejected(code: -25, message: "bad-txns-inputs-missingorspent"),
                .notAttempted
            ]
        )

        let expectedStatuses = [
            "accepted by endpoint 1",
            "rejected code: -25",
            "notAttempted"
        ]
        #expect(result == .partial(txIds: [txIdA, txIdB, txIdC], statuses: expectedStatuses))
        #expect(!expectedStatuses.joined(separator: " ").contains("private.wallet.node"))
    }

    @Test func acceptedThenTimedOutMapsToPartial() {
        let result = map(
            txIds: [txIdA, txIdB],
            outcomes: [.accepted(by: endpoints[1]), .timedOut]
        )

        #expect(
            result == .partial(
                txIds: [txIdA, txIdB],
                statuses: ["accepted by endpoint 2", timeoutDescription]
            )
        )
    }

    @Test func acceptedLabelReflectsEndpointPositionInSubmissionList() {
        let result = map(
            txIds: [txIdA, txIdB],
            outcomes: [.accepted(by: endpoints[2]), .unreachable]
        )

        #expect(
            result == .partial(
                txIds: [txIdA, txIdB],
                statuses: ["accepted by endpoint 3", "all servers unreachable"]
            )
        )
    }

    @Test func emptyTransactionListMapsToFailure() {
        let result = map(txIds: [], outcomes: [])

        #expect(result == .failure(txIds: [], code: -1, description: "No transactions created"))
    }

    @Test func missingOutcomesAreTreatedAsNotAttempted() {
        let result = map(txIds: [txIdA, txIdB], outcomes: [.accepted(by: endpoints[0])])

        #expect(
            result == .partial(
                txIds: [txIdA, txIdB],
                statuses: ["accepted by endpoint 1", "notAttempted"]
            )
        )
    }
}

// MARK: - Created-transaction submission glue

@Suite struct MultiServerSubmissionSubmitCreatedTransactionsTests {
    private let testAccountUUID = AccountUUID(id: [UInt8](repeating: 0, count: 16))

    private func manualPreferences() -> UserPreferencesStorageClient {
        var preferences = UserPreferencesStorageClient()
        preferences.automaticServerSelection = { false }
        return preferences
    }

    private func environment(endpoint: LightWalletEndpoint) -> ZcashSDKEnvironment {
        var environment = ZcashSDKEnvironment.test()
        environment.endpoint = { endpoint }
        environment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
        return environment
    }

    private func makeCreatedTransaction(raw: Data, rawID: Data) throws -> CreatedTransaction {
        let overview = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: raw,
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 1,
            poolCrossingValue: nil,
            isTrusted: true,
            zip318Kind: ZcashTransaction.Overview.ZIP318Kind.notClassified
        )
        return try CreatedTransaction(overview: overview)
    }

    @Test func emptyTransactionListFailsWithoutSubmitting() async {
        let submitCallCount = LockIsolated<Int>(0)

        let result = await SDKSynchronizerClient.submitCreatedTransactions(
            [],
            logPrefix: "[MultiSubmit/Test]",
            userStoredPreferences: manualPreferences(),
            zcashSDKEnvironment: environment(endpoint: LightWalletEndpoint(address: "manual.server", port: 443)),
            submit: { _, _ in
                submitCallCount.withValue { $0 += 1 }
                return []
            }
        )

        #expect(result == .failure(txIds: [], code: -1, description: "No transactions created"))
        #expect(submitCallCount.withValue { $0 } == 0)
    }

    @Test func submitsToSelectedEndpointsAndDerivesTxIds() async throws {
        let tx1 = try makeCreatedTransaction(raw: Data([0x01, 0x02]), rawID: Data([0xAA]))
        let tx2 = try makeCreatedTransaction(raw: Data([0x03, 0x04]), rawID: Data([0xBB]))
        let manualEndpoint = LightWalletEndpoint(address: "manual.server", port: 9067)
        let submittedEndpoints = LockIsolated<[String]>([])
        let submittedRawTxs = LockIsolated<[Data]>([])

        let result = await SDKSynchronizerClient.submitCreatedTransactions(
            [tx1, tx2],
            logPrefix: "[MultiSubmit/Test]",
            userStoredPreferences: manualPreferences(),
            zcashSDKEnvironment: environment(endpoint: manualEndpoint),
            submit: { transactions, endpoints in
                submittedEndpoints.withValue { $0.append(contentsOf: endpoints.map { $0.server() }) }
                submittedRawTxs.withValue { $0.append(contentsOf: transactions.map { $0.raw }) }
                return transactions.map { transaction in
                    (txId: transaction.txId, outcome: .accepted(by: manualEndpoint))
                }
            }
        )

        #expect(result == .success(txIds: [Data([0xAA]).toHexStringTxId(), Data([0xBB]).toHexStringTxId()]))
        #expect(submittedEndpoints.withValue { $0 } == ["manual.server:9067"])
        #expect(submittedRawTxs.withValue { $0 } == [Data([0x01, 0x02]), Data([0x03, 0x04])])
    }

    @Test func missingReportsAreNotMistakenForSuccess() async throws {
        let tx1 = try makeCreatedTransaction(raw: Data([0x01, 0x02]), rawID: Data([0xAA]))
        let tx2 = try makeCreatedTransaction(raw: Data([0x03, 0x04]), rawID: Data([0xBB]))

        let result = await SDKSynchronizerClient.submitCreatedTransactions(
            [tx1, tx2],
            logPrefix: "[MultiSubmit/Test]",
            userStoredPreferences: manualPreferences(),
            zcashSDKEnvironment: environment(endpoint: LightWalletEndpoint(address: "manual.server", port: 9067)),
            submit: { _, _ in [] }
        )

        // Nothing was accepted, so this must not surface as "partially accepted" either —
        // the transactions are in the wallet and may still be broadcast by retries.
        #expect(
            result == .grpcFailure(
                txIds: [Data([0xAA]).toHexStringTxId(), Data([0xBB]).toHexStringTxId()]
            )
        )
    }

    @Test func everyTransactionIsSubmittedEvenAfterEarlierFailures() async throws {
        let tx1 = try makeCreatedTransaction(raw: Data([0x01]), rawID: Data([0xAA]))
        let tx2 = try makeCreatedTransaction(raw: Data([0x02]), rawID: Data([0xBB]))
        let tx3 = try makeCreatedTransaction(raw: Data([0x03]), rawID: Data([0xCC]))
        let endpoint = LightWalletEndpoint(address: "manual.server", port: 9067)
        let submittedTxIds = LockIsolated<[Data]>([])

        let reports = await SDKSynchronizerClient.submitTransactionsIndividually(
            [tx1, tx2, tx3],
            to: [endpoint],
            submitSingle: { transaction, _ in
                submittedTxIds.withValue { $0.append(transaction.txId) }
                if transaction.txId == tx1.txId { return .timedOut }
                if transaction.txId == tx2.txId { return .rejected(code: -25, message: "low fee") }
                return .accepted(by: endpoint)
            }
        )

        // A failure must not stop the later transactions from being submitted: an unsubmitted
        // transaction never gets a retry plan in the SDK and would be stranded forever.
        #expect(submittedTxIds.withValue { $0 } == [tx1.txId, tx2.txId, tx3.txId])
        #expect(reports.map { $0.txId } == [tx1.txId, tx2.txId, tx3.txId])
        #expect(reports.map { $0.outcome } == [.timedOut, .rejected(code: -25, message: "low fee"), .accepted(by: endpoint)])
    }

    @Test func reportsArePairedByTxIdNotPosition() async throws {
        let tx1 = try makeCreatedTransaction(raw: Data([0x01, 0x02]), rawID: Data([0xAA]))
        let tx2 = try makeCreatedTransaction(raw: Data([0x03, 0x04]), rawID: Data([0xBB]))
        let endpoint = LightWalletEndpoint(address: "manual.server", port: 9067)

        let result = await SDKSynchronizerClient.submitCreatedTransactions(
            [tx1, tx2],
            logPrefix: "[MultiSubmit/Test]",
            userStoredPreferences: manualPreferences(),
            zcashSDKEnvironment: environment(endpoint: endpoint),
            submit: { transactions, _ in
                // Reports deliberately returned out of order: pairing must use the report's
                // txId, not its position.
                [
                    (txId: transactions[1].txId, outcome: .accepted(by: endpoint)),
                    (txId: transactions[0].txId, outcome: .rejected(code: -25, message: "low fee"))
                ]
            }
        )

        #expect(
            result == .partial(
                txIds: [Data([0xAA]).toHexStringTxId(), Data([0xBB]).toHexStringTxId()],
                statuses: ["rejected code: -25", "accepted by endpoint 1"]
            )
        )
    }
}
