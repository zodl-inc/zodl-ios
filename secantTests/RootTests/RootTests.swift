//
//  RootTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 12.04.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
class RootTests: XCTestCase {
    private enum FlexaTestConstants {
        static let commerceSessionId = "commerce-session-id"
        static let txId = "flexa-tx-id"
        static let recipientAddress = "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE"
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

    func testWalletInitializationState_Uninitialized() throws {
        let walletState = Root.walletInitializationState(
            databaseFiles: .noOp,
            walletStorage: .noOp,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .uninitialized)
    }

    func testWalletInitializationState_FilesPresentKeysMissing() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return true },
            removeItem: { _ in }
        )

        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: .noOp,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .keysMissing)
    }

    func testWalletInitializationState_FilesMissingKeysMissing() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return false },
            removeItem: { _ in }
        )

        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: .noOp,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .uninitialized)
    }
    
    func testWalletInitializationState_FilesMissing() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return false },
            removeItem: { _ in }
        )

        var walletStorage = WalletStorageClient.noOp
        walletStorage.areKeysPresent = { true }
        
        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: walletStorage,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .filesMissing)
    }
    
    func testWalletInitializationState_Initialized() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return true },
            removeItem: { _ in }
        )

        var walletStorage = WalletStorageClient.noOp
        walletStorage.areKeysPresent = { true }
        
        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: walletStorage,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .initialized)
    }

    @MainActor func testRespondToWalletInitializationState_Uninitialized() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        store.dependencies.databaseFiles = .noOp

        await store.send(.initialization(.respondToWalletInitializationState(.uninitialized)))

        await store.receive(.destination(.updateDestination(.onboarding))) { state in
            state.destinationState.destination = .onboarding
            state.appInitializationState = .uninitialized
        }
        
        await store.finish()
    }

    func testRespondToWalletInitializationState_KeysMissing() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        store.dependencies.databaseFiles = .noOp

        await store.send(.initialization(.respondToWalletInitializationState(.keysMissing))) { state in
            state.appInitializationState = .keysMissing
        }
        
        await store.receive(.destination(.updateDestination(.onboarding))) { state in
            state.destinationState.internalDestination = .onboarding
            state.destinationState.previousDestination = .welcome
        }
        
        await store.finish()
    }

    func testRespondToWalletInitializationState_FilesMissing() async throws {
        let walletStorageError: Error = "export failed"
        let zcashError = ZcashError.unknown(walletStorageError)

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletStorage.exportWallet = { throw zcashError }

        await store.send(.initialization(.respondToWalletInitializationState(.filesMissing))) { state in
            state.appInitializationState = .filesMissing
            state.isRestoringWallet = true
        }
        
        await store.receive(.initialization(.initializeSDK(.restoreWallet)))

        await store.receive(.initialization(.checkBackupPhraseValidation))

        await store.receive(.initialization(.initializationFailed(zcashError))) { state in
            state.appInitializationState = .failed
            state.alert = AlertState.initializationFailed(zcashError)
        }
        
        await store.receive(.initialization(.initializationFailed(zcashError)))
        
        await store.finish()
    }

    func testRespondToWalletInitializationState_Initialized() async throws {
        let walletStorageError: Error = "export failed"
        let zcashError = ZcashError.unknown(walletStorageError)

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletStorage.exportWallet = { throw walletStorageError }
        store.dependencies.userDefaults = .noOp

        await store.send(.initialization(.respondToWalletInitializationState(.initialized)))

        await store.receive(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(.initialization(.checkBackupPhraseValidation))
        
        await store.receive(.initialization(.initializationFailed(zcashError))) { state in
            state.appInitializationState = .failed
            state.alert = AlertState.initializationFailed(zcashError)
        }
        
        await store.receive(.initialization(.initializationFailed(zcashError)))

        await store.finish()
    }

    func testFlexaGrpcFailureWithoutReasonFailsEvenWhenTxExistsLocally() async throws {
        let transactionSentCalls = LockIsolated<[(String, String)]>([])
        let alertCalls = LockIsolated<[(String, String)]>([])
        let store = makeFlexaStore(
            result: .grpcFailure(txIds: [FlexaTestConstants.txId]),
            txIdExists: true,
            transactionSent: { commerceSessionId, txId in
                transactionSentCalls.withValue { $0.append((commerceSessionId, txId)) }
            },
            flexaAlert: { title, message in
                alertCalls.withValue { $0.append((title, message)) }
            }
        )

        await store.send(.flexaOnTransactionRequest(makeFlexaTransaction()))

        await store.receive(.flexaTransactionFailed(String(localizable: .partnersFlexaTransactionFailedMessage)))

        await store.finish()

        transactionSentCalls.withValue { XCTAssertTrue($0.isEmpty) }
        alertCalls.withValue { XCTAssertEqual($0.count, 1) }
    }

    func testFlexaGrpcFailureTimeoutFailsEvenWhenTxExistsLocally() async throws {
        let transactionSentCalls = LockIsolated<[(String, String)]>([])
        let alertCalls = LockIsolated<[(String, String)]>([])
        let store = makeFlexaStore(
            result: .grpcFailure(
                txIds: [FlexaTestConstants.txId],
                description: "Timed out waiting for endpoint response",
                reason: .timeout
            ),
            txIdExists: true,
            transactionSent: { commerceSessionId, txId in
                transactionSentCalls.withValue { $0.append((commerceSessionId, txId)) }
            },
            flexaAlert: { title, message in
                alertCalls.withValue { $0.append((title, message)) }
            }
        )

        await store.send(.flexaOnTransactionRequest(makeFlexaTransaction()))

        await store.receive(.flexaTransactionFailed(String(localizable: .partnersFlexaTransactionFailedMessage)))

        await store.finish()

        transactionSentCalls.withValue { XCTAssertTrue($0.isEmpty) }
        alertCalls.withValue { XCTAssertEqual($0.count, 1) }
    }

    func testFlexaSuccessReportsTransactionSentWhenTxExistsLocally() async throws {
        let transactionSentCalls = LockIsolated<[(String, String)]>([])
        let alertCalls = LockIsolated<[(String, String)]>([])
        let store = makeFlexaStore(
            result: .success(txIds: [FlexaTestConstants.txId]),
            txIdExists: true,
            transactionSent: { commerceSessionId, txId in
                transactionSentCalls.withValue { $0.append((commerceSessionId, txId)) }
            },
            flexaAlert: { title, message in
                alertCalls.withValue { $0.append((title, message)) }
            }
        )

        await store.send(.flexaOnTransactionRequest(makeFlexaTransaction()))

        await store.finish()

        transactionSentCalls.withValue {
            XCTAssertEqual($0.count, 1)
            XCTAssertEqual($0.first?.0, FlexaTestConstants.commerceSessionId)
            XCTAssertEqual($0.first?.1, FlexaTestConstants.txId)
        }
        alertCalls.withValue { XCTAssertTrue($0.isEmpty) }
    }

    func testFlexaSuccessFailsWhenTxIsMissingLocally() async throws {
        let transactionSentCalls = LockIsolated<[(String, String)]>([])
        let alertCalls = LockIsolated<[(String, String)]>([])
        let store = makeFlexaStore(
            result: .success(txIds: [FlexaTestConstants.txId]),
            txIdExists: false,
            transactionSent: { commerceSessionId, txId in
                transactionSentCalls.withValue { $0.append((commerceSessionId, txId)) }
            },
            flexaAlert: { title, message in
                alertCalls.withValue { $0.append((title, message)) }
            }
        )

        await store.send(.flexaOnTransactionRequest(makeFlexaTransaction()))

        await store.receive(.flexaTransactionFailed(String(localizable: .partnersFlexaTransactionFailedMessage)))

        await store.finish()

        transactionSentCalls.withValue { XCTAssertTrue($0.isEmpty) }
        alertCalls.withValue { XCTAssertEqual($0.count, 1) }
    }

    private func makeFlexaStore(
        result: SDKSynchronizerClient.CreateProposedTransactionsResult,
        txIdExists: Bool,
        transactionSent: @escaping @Sendable (String, String) -> Void,
        flexaAlert: @escaping @Sendable (String, String) -> Void
    ) -> TestStore<Root.State, Root.Action> {
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        }

        store.exhaustivity = .off
        store.dependencies.derivationTool = .liveValue
        store.dependencies.flexaHandler = .noOp
        store.dependencies.flexaHandler.transactionSent = transactionSent
        store.dependencies.flexaHandler.flexaAlert = flexaAlert
        store.dependencies.localAuthentication = .mockAuthenticationSucceeded
        store.dependencies.mnemonic = .mock
        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in result }
        store.dependencies.sdkSynchronizer.proposeTransfer = { _, _, _, _ in .testOnlyFakeProposal(totalFee: 0) }
        store.dependencies.sdkSynchronizer.txIdExists = { _ in txIdExists }
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletStorage.exportWallet = { .placeholder }
        store.dependencies.zcashSDKEnvironment = .testValue

        return store
    }

    private func makeFlexaTransaction() -> FlexaTransaction {
        FlexaTransaction(
            amount: Zatoshi(100_000),
            address: FlexaTestConstants.recipientAddress,
            commerceSessionId: FlexaTestConstants.commerceSessionId
        )
    }
}
