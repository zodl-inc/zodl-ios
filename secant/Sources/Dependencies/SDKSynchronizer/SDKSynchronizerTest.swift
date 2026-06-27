//
//  SDKSynchronizerTest.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit
import URKit

extension HTTPURLResponse {
    static var mockResponse: HTTPURLResponse {
        let url = URL(string: "https://example.com")!
        return HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

extension SDKSynchronizerClient: TestDependencyKey {
    static let testValue = Self(
        stateStream: unimplemented("\(Self.self).stateStream", placeholder: Empty().eraseToAnyPublisher()),
        eventStream: unimplemented("\(Self.self).eventStream", placeholder: Empty().eraseToAnyPublisher()),
        exchangeRateUSDStream: unimplemented("\(Self.self).exchangeRateUSDStream", placeholder: Empty().eraseToAnyPublisher()),
        latestState: unimplemented("\(Self.self).latestState", placeholder: .zero),
        prepareWith: unimplemented("\(Self.self).prepareWith"),
        start: unimplemented("\(Self.self).start"),
        stop: unimplemented("\(Self.self).stop", placeholder: {}()),
        isSyncing: unimplemented("\(Self.self).isSyncing", placeholder: false),
        isInitialized: unimplemented("\(Self.self).isInitialized", placeholder: false),
        importAccount: unimplemented("\(Self.self).importAccount", placeholder: nil),
        deleteAccount: unimplemented("\(Self.self).deleteAccount"),
        rescanFrom: unimplemented("\(Self.self).rescanFrom"),
        rewind: unimplemented("\(Self.self).rewind", placeholder: Fail(error: "Error").eraseToAnyPublisher()),
        getAllTransactions: unimplemented("\(Self.self).getAllTransactions", placeholder: []),
        transactionStatesFromZcashTransactions: unimplemented("\(Self.self).transactionStatesFromZcashTransactions", placeholder: []),
        getMemos: unimplemented("\(Self.self).getMemos", placeholder: []),
        txIdExists: unimplemented("\(Self.self).txIdExists", placeholder: false),
        getUnifiedAddress: unimplemented("\(Self.self).getUnifiedAddress", placeholder: nil),
        getTransparentAddress: unimplemented("\(Self.self).getTransparentAddress", placeholder: nil),
        getSaplingAddress: unimplemented("\(Self.self).getSaplingAddress", placeholder: nil),
        getAccountsBalances: unimplemented("\(Self.self).getAccountsBalances", placeholder: [:]),
        wipe: unimplemented("\(Self.self).wipe", placeholder: nil),
        switchToEndpoint: unimplemented("\(Self.self).switchToEndpoint"),
        proposeTransfer: unimplemented("\(Self.self).proposeTransfer", placeholder: .testOnlyFakeProposal(totalFee: 0)),
        createAndSubmitProposedTransactions: unimplemented("\(Self.self).createAndSubmitProposedTransactions", placeholder: .success(txIds: [])),
        proposeShielding: unimplemented("\(Self.self).proposeShielding", placeholder: nil),
        isSeedRelevantToAnyDerivedAccount: unimplemented("\(Self.self).isSeedRelevantToAnyDerivedAccount"),
        refreshExchangeRateUSD: unimplemented("\(Self.self).refreshExchangeRateUSD", placeholder: {}()),
        evaluateBestOf: { _, _, _, _, _ in fatalError("evaluateBestOf not implemented") },
        walletAccounts: unimplemented("\(Self.self).walletAccounts", placeholder: []),
        estimateBirthdayHeight: unimplemented("\(Self.self).estimateBirthdayHeight", placeholder: BlockHeight(0)),
        estimateTimestamp: unimplemented("\(Self.self).estimateTimestamp", placeholder: nil),
        createPCZTFromProposal: unimplemented("\(Self.self).createPCZTFromProposal", placeholder: Pczt()),
        addProofsToPCZT: unimplemented("\(Self.self).addProofsToPCZT", placeholder: Pczt()),
        createAndSubmitTransactionFromPCZT: unimplemented("\(Self.self).createAndSubmitTransactionFromPCZT", placeholder: .success(txIds: [])),
        urEncoderForPCZT: unimplemented("\(Self.self).urEncoderForPCZT", placeholder: nil),
        redactPCZTForSigner: unimplemented("\(Self.self).redactPCZTForSigner", placeholder: Pczt()),
        fetchTxidsWithMemoContaining: unimplemented("\(Self.self).fetchTxidsWithMemoContaining", placeholder: []),
        getCustomUnifiedAddress: unimplemented("\(Self.self).getCustomUnifiedAddress", placeholder: nil),
        torEnabled: unimplemented("\(Self.self).torEnabled"),
        exchangeRateEnabled: unimplemented("\(Self.self).exchangeRateEnabled"),
        isTorSuccessfullyInitialized: unimplemented("\(Self.self).isTorSuccessfullyInitialized", placeholder: nil),
        httpRequestOverTor: unimplemented("\(Self.self).httpRequestOverTor", placeholder: (Data(), HTTPURLResponse.mockResponse)),
        debugDatabaseSql: unimplemented("\(Self.self).debugDatabaseSql", placeholder: ""),
        getSingleUseTransparentAddress: unimplemented(
            "\(Self.self).getSingleUseTransparentAddress",
            placeholder: SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
        ),
        checkSingleUseTransparentAddresses: unimplemented("\(Self.self).checkSingleUseTransparentAddresses", placeholder: .notFound),
        updateTransparentAddressTransactions: unimplemented("\(Self.self).updateTransparentAddressTransactions", placeholder: .notFound),
        fetchUTXOsByAddress: unimplemented("\(Self.self).fetchUTXOsByAddress", placeholder: .notFound),
        enhanceTransactionBy: unimplemented("\(Self.self).enhanceTransactionBy"),
        getTreeState: unimplemented("\(Self.self).getTreeState", placeholder: Data())
    )
}

extension SDKSynchronizerClient {
    static let noOp = Self(
        stateStream: { Empty().eraseToAnyPublisher() },
        eventStream: { Empty().eraseToAnyPublisher() },
        exchangeRateUSDStream: { Empty().eraseToAnyPublisher() },
        latestState: { .zero },
        prepareWith: { _, _, _, _, _ in },
        start: { _ in },
        stop: { },
        isSyncing: { false },
        isInitialized: { false },
        importAccount: { _, _, _, _, _, _, _ in nil },
        deleteAccount: { _ in },
        rescanFrom: { _ in },
        rewind: { _ in Empty<Void, Error>().eraseToAnyPublisher() },
        getAllTransactions: { _ in [] },
        transactionStatesFromZcashTransactions: { _, _ in [] },
        getMemos: { _ in [] },
        txIdExists: { _ in false },
        getUnifiedAddress: { _ in nil },
        getTransparentAddress: { _ in nil },
        getSaplingAddress: { _ in nil },
        getAccountsBalances: { [:] },
        wipe: { Empty<Void, Error>().eraseToAnyPublisher() },
        switchToEndpoint: { _ in },
        proposeTransfer: { _, _, _, _ in .testOnlyFakeProposal(totalFee: 0) },
        createAndSubmitProposedTransactions: { _, _ in .success(txIds: []) },
        proposeShielding: { _, _, _, _ in nil },
        isSeedRelevantToAnyDerivedAccount: { _ in false },
        refreshExchangeRateUSD: { },
        evaluateBestOf: { _, _, _, _, _ in [] },
        walletAccounts: { [] },
        estimateBirthdayHeight: { _ in BlockHeight(0) },
        estimateTimestamp: { _ in nil },
        createPCZTFromProposal: { _, _ in Pczt() },
        addProofsToPCZT: { _ in Pczt() },
        createAndSubmitTransactionFromPCZT: { _, _ in .success(txIds: []) },
        urEncoderForPCZT: { _ in nil },
        redactPCZTForSigner: { _ in Pczt() },
        fetchTxidsWithMemoContaining: { _ in [] },
        getCustomUnifiedAddress: { _, _ in nil },
        torEnabled: { _ in },
        exchangeRateEnabled: { _ in },
        isTorSuccessfullyInitialized: { nil },
        httpRequestOverTor: { _ in (data: Data(), response: HTTPURLResponse.mockResponse) },
        debugDatabaseSql: { _ in "" },
        getSingleUseTransparentAddress: { _ in
            SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
        },
        checkSingleUseTransparentAddresses: { _ in .notFound },
        updateTransparentAddressTransactions: { _ in .notFound },
        fetchUTXOsByAddress: { _, _ in .notFound },
        enhanceTransactionBy: { _ in },
        getTreeState: { _ in Data() }
    )

    static let mock = Self.mocked()
}

extension SDKSynchronizerClient {
    static func mocked(
        stateStream: @escaping @Sendable () -> AnyPublisher<SynchronizerState, Never> = { Just(.zero).eraseToAnyPublisher() },
        eventStream: @escaping @Sendable () -> AnyPublisher<SynchronizerEvent, Never> = { Empty().eraseToAnyPublisher() },
        exchangeRateUSDStream: @escaping @Sendable () -> AnyPublisher<FiatCurrencyResult?, Never> = { Empty().eraseToAnyPublisher() },
        latestState: @escaping @Sendable () -> SynchronizerState = { .zero },
        latestScannedHeight: @escaping @Sendable () -> BlockHeight = { 0 },
        prepareWith: @escaping @Sendable ([UInt8]?, BlockHeight, WalletInitMode, String, String?) throws -> Void = { _, _, _, _, _ in },
        start: @escaping @Sendable (_ retry: Bool) throws -> Void = { _ in },
        stop: @escaping @Sendable () -> Void = { },
        isSyncing: @escaping @Sendable () -> Bool = { false },
        isInitialized: @escaping @Sendable () -> Bool = { false },
    importAccount: @escaping @Sendable (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?, BlockHeight?) async throws -> AccountUUID? = { _, _, _, _, _, _, _ in nil },
        deleteAccount: @escaping @Sendable (AccountUUID) async throws -> Void = { _ in },
        rescanFrom: @escaping @Sendable (BlockHeight) async throws -> Void = { _ in },
        rewind: @escaping @Sendable (RewindPolicy) -> AnyPublisher<Void, Error> = { _ in return Empty<Void, Error>().eraseToAnyPublisher() },
        getAllTransactions: @escaping @Sendable (AccountUUID?) -> IdentifiedArrayOf<TransactionState> = { _ in
            let mockedCleared: [TransactionStateMockHelper] = [
                TransactionStateMockHelper(date: 1651039202, amount: Zatoshi(1), status: .paid, uuid: "aa11"),
                TransactionStateMockHelper(date: 1651039101, amount: Zatoshi(2), uuid: "bb22"),
                TransactionStateMockHelper(date: 1651039000, amount: Zatoshi(3), status: .paid, uuid: "cc33"),
                TransactionStateMockHelper(date: 1651039505, amount: Zatoshi(4), uuid: "dd44"),
                TransactionStateMockHelper(date: 1651039404, amount: Zatoshi(5), uuid: "ee55")
            ]

            var clearedTransactions = mockedCleared
                .map {
                    let transaction = TransactionState.placeholder(
                        amount: $0.amount,
                        fee: Zatoshi(10),
                        shielded: $0.shielded,
                        status: $0.status,
                        timestamp: $0.date,
                        uuid: $0.uuid
                    )
                    return transaction
                }
        
            let mockedPending: [TransactionStateMockHelper] = [
                TransactionStateMockHelper(
                    date: 1651039606,
                    amount: Zatoshi(6),
                    status: .paid,
                    uuid: "ff66"
                ),
                TransactionStateMockHelper(date: 1651039303, amount: Zatoshi(7), uuid: "gg77"),
                TransactionStateMockHelper(date: 1651039707, amount: Zatoshi(8), status: .paid, uuid: "hh88"),
                TransactionStateMockHelper(date: 1651039808, amount: Zatoshi(9), uuid: "ii99")
            ]

            let pendingTransactions = mockedPending
                .map {
                    let transaction = TransactionState.placeholder(
                        amount: $0.amount,
                        fee: Zatoshi(10),
                        shielded: $0.shielded,
                        status: $0.amount.amount > 5 ? .sending : $0.status,
                        timestamp: $0.date,
                        uuid: $0.uuid
                    )
                    return transaction
                }
            
            clearedTransactions.append(contentsOf: pendingTransactions)

            return IdentifiedArrayOf<TransactionState>(uniqueElements: clearedTransactions)
        },
        transactionStatesFromZcashTransactions: @escaping @Sendable (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState> = { _, _ in IdentifiedArrayOf<TransactionState>(uniqueElements: []) },
        getMemos: @escaping @Sendable (_ rawID: Data) -> [Memo] = { _ in [] },
        txIdExists: @escaping @Sendable (String?) -> Bool = { _ in false },
        getUnifiedAddress: @escaping @Sendable (_ account: AccountUUID) -> UnifiedAddress? = { _ in
            // swiftlint:disable force_try
            try! UnifiedAddress(
                encoding: """
                utest1zkkkjfxkamagznjr6ayemffj2d2gacdwpzcyw669pvg06xevzqslpmm27zjsctlkstl2vsw62xrjktmzqcu4yu9zdhdxqz3kafa4j2q85y6mv74rzjcgjg8c0ytrg7d\
                wyzwtgnuc76h
                """,
                network: .testnet
            )
        },
        getTransparentAddress: @escaping @Sendable (_ account: AccountUUID) -> TransparentAddress? = { _ in return nil },
        getSaplingAddress: @escaping @Sendable (_ account: AccountUUID) async -> SaplingAddress? = { _ in
            // swiftlint:disable:next force_try
            try! SaplingAddress(
                encoding: "ztestsapling1edm52k336nk70gxqxedd89slrrf5xwnnp5rt6gqnk0tgw4mynv6fcx42ym6x27yac5amvfvwypz",
                network: .testnet
            )
        },
        getAccountsBalances: @escaping @Sendable () async -> [AccountUUID: AccountBalance] = { [:] },
        wipe: @escaping @Sendable () -> AnyPublisher<Void, Error>? = { Fail(error: "Error").eraseToAnyPublisher() },
        switchToEndpoint: @escaping @Sendable (LightWalletEndpoint) async throws -> Void = { _ in },
        proposeTransfer:
        @escaping @Sendable (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal = { _, _, _, _ in .testOnlyFakeProposal(totalFee: 0) },
        createAndSubmitProposedTransactions:
        @escaping @Sendable (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult = { _, _ in .success(txIds: []) },
        proposeShielding:
        @escaping @Sendable (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal? = { _, _, _, _ in nil },
        isSeedRelevantToAnyDerivedAccount: @escaping @Sendable ([UInt8]) async throws -> Bool = { _ in false },
        refreshExchangeRateUSD: @escaping @Sendable () -> Void = { },
        evaluateBestOf: @escaping @Sendable ([LightWalletEndpoint], Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _, _, _, _, _ in [] },
        walletAccounts: @escaping @Sendable () async throws -> [WalletAccount] = { [] },
        estimateBirthdayHeight: @escaping @Sendable (Date) -> BlockHeight = { _ in BlockHeight(0) },
        estimateTimestamp: @escaping @Sendable (BlockHeight) -> TimeInterval? = { _ in nil },
        createPCZTFromProposal: @escaping @Sendable (AccountUUID, Proposal) async throws -> Pczt = { _, _ in Pczt() },
        addProofsToPCZT: @escaping @Sendable (Data) async throws -> Pczt = { _ in Pczt() },
        createAndSubmitTransactionFromPCZT: @escaping @Sendable (Pczt, Pczt) async throws -> CreateProposedTransactionsResult = { _, _ in .success(txIds: []) },
        urEncoderForPCZT: @escaping @Sendable (Pczt) -> UREncoder? = { _ in nil },
        redactPCZTForSigner: @escaping @Sendable (Pczt) async throws -> Pczt = { _ in Pczt() },
        fetchTxidsWithMemoContaining: @escaping @Sendable (String) async throws -> [Data] = { _ in [] },
        getCustomUnifiedAddress: @escaping @Sendable (AccountUUID, Set<ReceiverType>) async throws -> UnifiedAddress? = { _, _ in nil },
        torEnabled: @escaping @Sendable (Bool) async throws -> Void = { _ in },
        exchangeRateEnabled: @escaping @Sendable (Bool) async throws -> Void = { _ in },
        isTorSuccessfullyInitialized: @escaping @Sendable () async -> Bool? = { nil },
        httpRequestOverTor: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in (Data(), HTTPURLResponse.mockResponse) },
        debugDatabaseSql: @escaping @Sendable (String) -> String = { _ in "" },
        getSingleUseTransparentAddress: @escaping @Sendable (AccountUUID) async throws -> SingleUseTransparentAddress = { _ in
            SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
        },
        checkSingleUseTransparentAddresses: @escaping @Sendable (AccountUUID) async throws -> TransparentAddressCheckResult = { _ in .notFound },
        updateTransparentAddressTransactions: @escaping @Sendable (String) async throws -> TransparentAddressCheckResult = { _ in .notFound },
        fetchUTXOsByAddress: @escaping @Sendable (String, AccountUUID) async throws -> TransparentAddressCheckResult = { _, _ in .notFound },
        enhanceTransactionBy: @escaping @Sendable (String) async throws -> Void = { _ in },
        getTreeState: @escaping @Sendable (UInt64) async throws -> Data = { _ in Data() }
    ) -> SDKSynchronizerClient {
        SDKSynchronizerClient(
            stateStream: stateStream,
            eventStream: eventStream,
            exchangeRateUSDStream: exchangeRateUSDStream,
            latestState: latestState,
            prepareWith: prepareWith,
            start: start,
            stop: stop,
            isSyncing: isSyncing,
            isInitialized: isInitialized,
            importAccount: importAccount,
            deleteAccount: deleteAccount,
            rescanFrom: rescanFrom,
            rewind: rewind,
            getAllTransactions: getAllTransactions,
            transactionStatesFromZcashTransactions: transactionStatesFromZcashTransactions,
            getMemos: getMemos,
            txIdExists: txIdExists,
            getUnifiedAddress: getUnifiedAddress,
            getTransparentAddress: getTransparentAddress,
            getSaplingAddress: getSaplingAddress,
            getAccountsBalances: getAccountsBalances,
            wipe: wipe,
            switchToEndpoint: switchToEndpoint,
            proposeTransfer: proposeTransfer,
            createAndSubmitProposedTransactions: createAndSubmitProposedTransactions,
            proposeShielding: proposeShielding,
            isSeedRelevantToAnyDerivedAccount: isSeedRelevantToAnyDerivedAccount,
            refreshExchangeRateUSD: refreshExchangeRateUSD,
            evaluateBestOf: evaluateBestOf,
            walletAccounts: walletAccounts,
            estimateBirthdayHeight: estimateBirthdayHeight,
            estimateTimestamp: estimateTimestamp,
            createPCZTFromProposal: createPCZTFromProposal,
            addProofsToPCZT: addProofsToPCZT,
            createAndSubmitTransactionFromPCZT: createAndSubmitTransactionFromPCZT,
            urEncoderForPCZT: urEncoderForPCZT,
            redactPCZTForSigner: redactPCZTForSigner,
            fetchTxidsWithMemoContaining: fetchTxidsWithMemoContaining,
            getCustomUnifiedAddress: getCustomUnifiedAddress,
            torEnabled: torEnabled,
            exchangeRateEnabled: exchangeRateEnabled,
            isTorSuccessfullyInitialized: isTorSuccessfullyInitialized,
            httpRequestOverTor: httpRequestOverTor,
            debugDatabaseSql: debugDatabaseSql,
            getSingleUseTransparentAddress: getSingleUseTransparentAddress,
            checkSingleUseTransparentAddresses: checkSingleUseTransparentAddresses,
            updateTransparentAddressTransactions: updateTransparentAddressTransactions,
            fetchUTXOsByAddress: fetchUTXOsByAddress,
            enhanceTransactionBy: enhanceTransactionBy,
            getTreeState: getTreeState
        )
    }
}
