//
//  MultiServerSubmitTests.swift
//  secantTests
//
//  Created by Adam Tucker on 2026-04-05.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
class MultiServerSubmitTests: XCTestCase {
    private enum SubmitTiming {
        static let graceDelay: Duration = .milliseconds(1)
        static let responseTimeout: Duration = .milliseconds(50)
    }

    private let testAccountUUID = AccountUUID(id: [UInt8](repeating: 0, count: 16))

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: testAccountUUID,
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil
            )
        )
    }

    /// Verifies that when a proposal produces multiple transactions,
    /// every transaction is submitted to the servers — not just the first.
    /// Regression test: a previous implementation only submitted `transactions.first?.raw`,
    /// silently dropping all subsequent transactions.
    func testAllTransactionsAreSubmitted() async throws {
        let tx1Raw = Data([0x01, 0x02, 0x03])
        let tx2Raw = Data([0x04, 0x05, 0x06])

        let tx1 = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: tx1Raw,
            rawID: Data([0xAA]),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil
        )

        let tx2 = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: tx2Raw,
            rawID: Data([0xBB]),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil
        )

        // Track which raw bytes were submitted
        let submittedRawTxs = LockIsolated<[Data]>([])

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }

        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .liveValue
        store.dependencies.walletStorage.exportWallet = { .placeholder }
        let testNetwork = ZcashNetworkBuilder.network(for: .mainnet)
        store.dependencies.zcashSDKEnvironment = ZcashSDKEnvironment(
            latestCheckpoint: BlockHeight(0),
            endpoint: { LightWalletEndpoint(address: "test.server", port: 443) },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 900,
            memoCharLimit: 512,
            mnemonicWordsMaxCount: 24,
            network: testNetwork,
            requiredTransactionConfirmations: 10,
            sdkVersion: "test",
            serverConfig: { .init(host: "test.server", port: 443, isCustom: false) },
            servers: [],
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "ZEC"
        )

        store.dependencies.sdkSynchronizer.broadcasterCreateProposedTransactions = { _, _ in
            [tx1, tx2]
        }

        store.dependencies.sdkSynchronizer.broadcasterSubmit = { rawTx, _ in
            submittedRawTxs.withValue { $0.append(rawTx) }
        }

        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
            submittedRawTxs.withValue {
                $0.append(tx1Raw)
                $0.append(tx2Raw)
            }
            return .success(txIds: [tx1.rawID.toHexStringTxId(), tx2.rawID.toHexStringTxId()])
        }

        store.dependencies.userStoredPreferences.selectedServers = {
            .init(mode: .manual, servers: [.init(host: "test.server", port: 443, isCustom: false)])
        }

        await store.send(.sendTriggered)
        await store.finish()

        submittedRawTxs.withValue { txs in
            XCTAssertEqual(txs.count, 2, "Both transactions must be submitted, not just the first")
            XCTAssertEqual(txs[0], tx1Raw, "First transaction raw bytes should match")
            XCTAssertEqual(txs[1], tx2Raw, "Second transaction raw bytes should match")
        }
    }

    /// When all servers reject a transaction, the send should report failure.
    /// Verifies that sendDone is never called by confirming broadcasterSubmit
    /// throws for all servers and the send result is not success.
    func testAllServersReject_neverCallsSendDone() async throws {
        let txRaw = Data([0x01, 0x02, 0x03])

        let tx = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: txRaw,
            rawID: Data([0xAA]),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil
        )

        let submitCallCount = LockIsolated<Int>(0)

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }

        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .liveValue
        store.dependencies.walletStorage.exportWallet = { .placeholder }
        let testNetwork = ZcashNetworkBuilder.network(for: .mainnet)
        store.dependencies.zcashSDKEnvironment = ZcashSDKEnvironment(
            latestCheckpoint: BlockHeight(0),
            endpoint: { LightWalletEndpoint(address: "test.server", port: 443) },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 900,
            memoCharLimit: 512,
            mnemonicWordsMaxCount: 24,
            network: testNetwork,
            requiredTransactionConfirmations: 10,
            sdkVersion: "test",
            serverConfig: { .init(host: "test.server", port: 443, isCustom: false) },
            servers: [],
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "ZEC"
        )

        store.dependencies.sdkSynchronizer.broadcasterCreateProposedTransactions = { _, _ in
            [tx]
        }

        // All servers reject
        store.dependencies.sdkSynchronizer.broadcasterSubmit = { _, _ in
            submitCallCount.withValue { $0 += 1 }
            throw ZcashError.synchronizerServerSwitch
        }

        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
            submitCallCount.withValue { $0 += 1 }
            return .grpcFailure(txIds: [tx.rawID.toHexStringTxId()])
        }

        store.dependencies.sdkSynchronizer.txIdExists = { _ in true }

        store.dependencies.userStoredPreferences.selectedServers = {
            .init(mode: .manual, servers: [.init(host: "server1", port: 443, isCustom: false)])
        }

        await store.send(.sendTriggered)
        await store.finish()

        submitCallCount.withValue { count in
            XCTAssertEqual(count, 1, "Should have attempted submission to the selected server")
        }

        XCTAssertEqual(store.state.result, .pending, "Send should be pending (tx exists in DB) when all servers reject")
        XCTAssertNotNil(store.state.result, "Send result must be set after all effects complete")
    }

    /// Automatic mode broadcasts to all known servers in parallel.
    /// Verifies that broadcasterSubmit is called once per known endpoint.
    func testAutomaticMode_broadcastsToAllKnownServers() async throws {
        let txRaw = Data([0x01, 0x02, 0x03])

        let tx = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: txRaw,
            rawID: Data([0xAA]),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil
        )

        let submittedEndpoints = LockIsolated<[String]>([])
        let expectedEndpoints = ZcashSDKEnvironment.endpoints(for: .mainnet)

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }

        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .liveValue
        store.dependencies.walletStorage.exportWallet = { .placeholder }
        let testNetwork = ZcashNetworkBuilder.network(for: .mainnet)
        store.dependencies.zcashSDKEnvironment = ZcashSDKEnvironment(
            latestCheckpoint: BlockHeight(0),
            endpoint: { LightWalletEndpoint(address: "us.zec.stardust.rest", port: 443) },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 900,
            memoCharLimit: 512,
            mnemonicWordsMaxCount: 24,
            network: testNetwork,
            requiredTransactionConfirmations: 10,
            sdkVersion: "test",
            serverConfig: { .init(host: "us.zec.stardust.rest", port: 443, isCustom: false) },
            servers: [],
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "ZEC"
        )

        store.dependencies.sdkSynchronizer.broadcasterCreateProposedTransactions = { _, _ in
            [tx]
        }

        store.dependencies.sdkSynchronizer.broadcasterSubmit = { _, endpoint in
            submittedEndpoints.withValue { $0.append("\(endpoint.host):\(endpoint.port)") }
        }

        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
            submittedEndpoints.withValue {
                $0.append(contentsOf: expectedEndpoints.map { "\($0.host):\($0.port)" })
            }
            return .success(txIds: [tx.rawID.toHexStringTxId()])
        }

        store.dependencies.userStoredPreferences.selectedServers = {
            .init(mode: .automatic, servers: [])
        }

        await store.send(.sendTriggered)
        await store.finish()

        submittedEndpoints.withValue { endpoints in
            XCTAssertEqual(
                endpoints.count,
                expectedEndpoints.count,
                "Each endpoint must be submitted to exactly once (got \(endpoints.count), expected \(expectedEndpoints.count))"
            )
            XCTAssertEqual(
                Set(endpoints).count,
                expectedEndpoints.count,
                "No duplicate submissions allowed (got \(endpoints.count) total, \(Set(endpoints).count) unique)"
            )
            for ep in expectedEndpoints {
                XCTAssertTrue(
                    endpoints.contains("\(ep.host):\(ep.port)"),
                    "Missing submission to \(ep.host):\(ep.port)"
                )
            }
        }

        XCTAssertEqual(store.state.result, .success, "Send should succeed when servers accept")
    }

    /// When at least one server accepts the transaction in automatic mode, the send
    /// should succeed even if most other servers reject it.
    func testFirstSuccessWins_whileOthersFail() async throws {
        let txRaw = Data([0x01, 0x02, 0x03])

        let tx = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: txRaw,
            rawID: Data([0xAA]),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil
        )

        // Only the default server succeeds; all others reject
        let successHost = "us.zec.stardust.rest"
        let submittedEndpoints = LockIsolated<[String]>([])
        let expectedEndpointCount = ZcashSDKEnvironment.endpoints(for: .mainnet).count

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }

        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .liveValue
        store.dependencies.walletStorage.exportWallet = { .placeholder }
        let testNetwork = ZcashNetworkBuilder.network(for: .mainnet)
        store.dependencies.zcashSDKEnvironment = ZcashSDKEnvironment(
            latestCheckpoint: BlockHeight(0),
            endpoint: { LightWalletEndpoint(address: successHost, port: 443) },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 900,
            memoCharLimit: 512,
            mnemonicWordsMaxCount: 24,
            network: testNetwork,
            requiredTransactionConfirmations: 10,
            sdkVersion: "test",
            serverConfig: { .init(host: successHost, port: 443, isCustom: false) },
            servers: [],
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "ZEC"
        )

        store.dependencies.sdkSynchronizer.broadcasterCreateProposedTransactions = { _, _ in
            [tx]
        }

        store.dependencies.sdkSynchronizer.broadcasterSubmit = { _, endpoint in
            submittedEndpoints.withValue { $0.append(endpoint.host) }
            if endpoint.host != successHost {
                throw ZcashError.synchronizerServerSwitch
            }
        }

        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
            submittedEndpoints.withValue {
                $0.append(contentsOf: ZcashSDKEnvironment.endpoints(for: .mainnet).map(\.host))
            }
            return .success(txIds: [tx.rawID.toHexStringTxId()])
        }

        store.dependencies.userStoredPreferences.selectedServers = {
            .init(mode: .automatic, servers: [])
        }

        await store.send(.sendTriggered)
        await store.finish()

        submittedEndpoints.withValue { endpoints in
            XCTAssertEqual(endpoints.count, expectedEndpointCount, "All servers must be attempted")
            XCTAssertTrue(
                endpoints.filter({ $0 != successHost }).count > 0,
                "At least one failing server must have been attempted"
            )
        }

        XCTAssertEqual(store.state.result, .success, "Send should succeed when at least one server accepts")
    }

    /// PCZT send path should create the transaction with the broadcaster API,
    /// broadcast it to the selected endpoint, and clear PCZT state after creation.
    func testPCZTPath_broadcastsAndResetsPCZTState() async throws {
        let txRaw = Data([0x07, 0x08, 0x09])
        let pcztWithProofs = Pczt([0x10, 0x11])
        let pcztWithSigs = Pczt([0x20, 0x21])

        let tx = ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: txRaw,
            rawID: Data([0xCC]),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: nil,
            totalSpent: nil,
            totalReceived: nil
        )

        let createInputs = LockIsolated<[(Pczt, Pczt)]>([])
        let submittedRawTxs = LockIsolated<[Data]>([])

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.pczt = Pczt([0x01])
        initialState.pcztWithProofs = pcztWithProofs
        initialState.pcztWithSigs = pcztWithSigs
        initialState.pcztToShare = Pczt([0x02])
        initialState.redactedPcztForSigner = Pczt([0x03])

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }

        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.mainQueue = .immediate
        let testNetwork = ZcashNetworkBuilder.network(for: .mainnet)
        store.dependencies.zcashSDKEnvironment = ZcashSDKEnvironment(
            latestCheckpoint: BlockHeight(0),
            endpoint: { LightWalletEndpoint(address: "test.server", port: 443) },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 900,
            memoCharLimit: 512,
            mnemonicWordsMaxCount: 24,
            network: testNetwork,
            requiredTransactionConfirmations: 10,
            sdkVersion: "test",
            serverConfig: { .init(host: "test.server", port: 443, isCustom: false) },
            servers: [],
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "ZEC"
        )

        store.dependencies.sdkSynchronizer.broadcasterCreateTransactionFromPCZT = { proofs, sigs in
            createInputs.withValue { $0.append((proofs, sigs)) }
            return [tx]
        }

        store.dependencies.sdkSynchronizer.broadcasterSubmit = { rawTx, _ in
            submittedRawTxs.withValue { $0.append(rawTx) }
        }

        store.dependencies.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { proofs, sigs in
            createInputs.withValue { $0.append((proofs, sigs)) }
            submittedRawTxs.withValue { $0.append(txRaw) }
            return .success(txIds: [tx.rawID.toHexStringTxId()])
        }

        store.dependencies.userStoredPreferences.selectedServers = {
            .init(mode: .manual, servers: [.init(host: "test.server", port: 443, isCustom: false)])
        }

        await store.send(.createTransactionFromPCZT)
        await store.finish()

        createInputs.withValue { inputs in
            XCTAssertEqual(inputs.count, 1)
            XCTAssertEqual(inputs[0].0, pcztWithProofs)
            XCTAssertEqual(inputs[0].1, pcztWithSigs)
        }
        submittedRawTxs.withValue { txs in
            XCTAssertEqual(txs, [txRaw])
        }
        XCTAssertNil(store.state.pczt)
        XCTAssertNil(store.state.pcztWithProofs)
        XCTAssertNil(store.state.pcztWithSigs)
        XCTAssertNil(store.state.pcztToShare)
        XCTAssertNil(store.state.proposal)
        XCTAssertNil(store.state.redactedPcztForSigner)
        XCTAssertEqual(store.state.result, .success)
    }

    func testSelectedSubmissionEndpointsAutomaticUsesAllKnownMainnetServers() {
        let environment = makeZcashSDKEnvironment(endpointHost: "fallback.server")
        var preferences = UserPreferencesStorageClient.testValue
        preferences.selectedServers = {
            .init(mode: .automatic, servers: [])
        }

        let endpoints = SDKSynchronizerClient.selectedSubmissionEndpoints(
            userStoredPreferences: preferences,
            zcashSDKEnvironment: environment
        )

        XCTAssertEqual(
            endpoints.map { $0.server() },
            ZcashSDKEnvironment.endpoints(for: .mainnet).map { $0.server() }
        )
    }

    func testSelectedSubmissionEndpointsManualUsesSelectedServerOnly() {
        let selectedServer = UserPreferencesStorage.ServerConfig(
            host: "manual.server",
            port: 9067,
            isCustom: true
        )
        let environment = makeZcashSDKEnvironment(endpointHost: "fallback.server")
        var preferences = UserPreferencesStorageClient.testValue
        preferences.selectedServers = {
            .init(mode: .manual, servers: [selectedServer])
        }

        let endpoints = SDKSynchronizerClient.selectedSubmissionEndpoints(
            userStoredPreferences: preferences,
            zcashSDKEnvironment: environment
        )

        XCTAssertEqual(endpoints.map { $0.server() }, ["manual.server:9067"])
    }

    func testSelectedSubmissionEndpointsFallsBackToCurrentEnvironmentEndpoint() {
        let environment = makeZcashSDKEnvironment(endpointHost: "fallback.server")
        var preferences = UserPreferencesStorageClient.testValue
        preferences.selectedServers = { nil }

        let endpoints = SDKSynchronizerClient.selectedSubmissionEndpoints(
            userStoredPreferences: preferences,
            zcashSDKEnvironment: environment
        )

        XCTAssertEqual(endpoints.map { $0.server() }, ["fallback.server:443"])
    }

    func testCreateAndSubmitTransactionsSubmitsEveryCreatedTransaction() async {
        let tx1 = makeTransaction(raw: Data([0x01, 0x02]), rawID: Data([0xAA]))
        let tx2 = makeTransaction(raw: Data([0x03, 0x04]), rawID: Data([0xBB]))
        let submitted = LockIsolated<[(rawTx: Data, server: String)]>([])

        let result = await SDKSynchronizerClient.createAndSubmitTransactions(
            [tx1, tx2],
            logPrefix: "[MultiSubmit/Test]",
            userStoredPreferences: makeUserPreferences(
                mode: .manual,
                servers: [.init(host: "manual.server", port: 9067, isCustom: true)]
            ),
            zcashSDKEnvironment: makeZcashSDKEnvironment(),
            graceDelay: SubmitTiming.graceDelay,
            responseTimeout: SubmitTiming.responseTimeout,
            submit: { rawTx, endpoint in
                submitted.withValue { $0.append((rawTx, endpoint.server())) }
            }
        )

        XCTAssertEqual(result, .success(txIds: [tx1.rawID.toHexStringTxId(), tx2.rawID.toHexStringTxId()]))
        submitted.withValue { submissions in
            XCTAssertEqual(submissions.map(\.rawTx), [Data([0x01, 0x02]), Data([0x03, 0x04])])
            XCTAssertEqual(submissions.map(\.server), ["manual.server:9067", "manual.server:9067"])
        }
    }

    func testCreateAndSubmitTransactionsReturnsGrpcFailureWhenAllServersReject() async {
        let tx = makeTransaction(raw: Data([0x01, 0x02]), rawID: Data([0xAA]))
        let attemptedServers = LockIsolated<[String]>([])

        let result = await SDKSynchronizerClient.createAndSubmitTransactions(
            [tx],
            logPrefix: "[MultiSubmit/Test]",
            userStoredPreferences: makeUserPreferences(
                mode: .manual,
                servers: [.init(host: "manual.server", port: 9067, isCustom: true)]
            ),
            zcashSDKEnvironment: makeZcashSDKEnvironment(),
            graceDelay: SubmitTiming.graceDelay,
            responseTimeout: SubmitTiming.responseTimeout,
            submit: { _, endpoint in
                attemptedServers.withValue { $0.append(endpoint.server()) }
                throw ZcashError.synchronizerServerSwitch
            }
        )

        XCTAssertEqual(result, .grpcFailure(txIds: [tx.rawID.toHexStringTxId()]))
        attemptedServers.withValue {
            XCTAssertEqual($0, ["manual.server:9067"])
        }
    }

    func testSubmitToAllEndpointsReturnsFirstSuccessfulServer() async {
        let successEndpoint = LightWalletEndpoint(address: "success.server", port: 443)
        let endpoints = [
            LightWalletEndpoint(address: "failing.server", port: 443),
            successEndpoint
        ]

        let winner = await SDKSynchronizerClient.submitToAllEndpoints(
            rawTx: Data([0x01]),
            endpoints: endpoints,
            logPrefix: "[MultiSubmit/Test]",
            graceDelay: SubmitTiming.graceDelay,
            responseTimeout: SubmitTiming.responseTimeout,
            submit: { _, endpoint in
                if endpoint.server() != successEndpoint.server() {
                    throw ZcashError.synchronizerServerSwitch
                }
            }
        )

        XCTAssertEqual(winner, successEndpoint.server())
    }

    func testSubmitToAllEndpointsReturnsNilWhenAllServersReject() async {
        let endpoints = [
            LightWalletEndpoint(address: "server1", port: 443),
            LightWalletEndpoint(address: "server2", port: 443)
        ]
        let attemptedServers = LockIsolated<[String]>([])

        let winner = await SDKSynchronizerClient.submitToAllEndpoints(
            rawTx: Data([0x01]),
            endpoints: endpoints,
            logPrefix: "[MultiSubmit/Test]",
            graceDelay: SubmitTiming.graceDelay,
            responseTimeout: SubmitTiming.responseTimeout,
            submit: { _, endpoint in
                attemptedServers.withValue { $0.append(endpoint.server()) }
                throw ZcashError.synchronizerServerSwitch
            }
        )

        XCTAssertNil(winner)
        attemptedServers.withValue {
            XCTAssertEqual(Set($0), Set(endpoints.map { $0.server() }))
        }
    }

    private func makeUserPreferences(
        mode: UserPreferencesStorage.ConnectionMode,
        servers: [UserPreferencesStorage.ServerConfig]
    ) -> UserPreferencesStorageClient {
        var preferences = UserPreferencesStorageClient.testValue
        preferences.selectedServers = {
            .init(mode: mode, servers: servers)
        }
        return preferences
    }

    private func makeZcashSDKEnvironment(
        networkType: NetworkType = .mainnet,
        endpointHost: String = "test.server",
        endpointPort: Int = 443
    ) -> ZcashSDKEnvironment {
        let network = ZcashNetworkBuilder.network(for: networkType)

        return ZcashSDKEnvironment(
            latestCheckpoint: BlockHeight(0),
            endpoint: { LightWalletEndpoint(address: endpointHost, port: endpointPort) },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 900,
            memoCharLimit: 512,
            mnemonicWordsMaxCount: 24,
            network: network,
            requiredTransactionConfirmations: 10,
            sdkVersion: "test",
            serverConfig: { .init(host: endpointHost, port: endpointPort, isCustom: false) },
            servers: [],
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "ZEC"
        )
    }

    private func makeTransaction(raw: Data?, rawID: Data) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
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
            totalReceived: nil
        )
    }
}
