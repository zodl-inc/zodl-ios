//
//  SDKSynchronizerTest.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Combine
import ComposableArchitecture
import Foundation
import ZcashLightClientKit
import Models
import Utils
import URKit

extension HTTPURLResponse {
    public static var mockResponse: HTTPURLResponse {
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
    public static let testValue = Self(
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
        createProposedTransactions: unimplemented("\(Self.self).createProposedTransactions", placeholder: .success(txIds: [])),
        proposeShielding: unimplemented("\(Self.self).proposeShielding", placeholder: nil),
        isSeedRelevantToAnyDerivedAccount: unimplemented("\(Self.self).isSeedRelevantToAnyDerivedAccount"),
        refreshExchangeRateUSD: unimplemented("\(Self.self).refreshExchangeRateUSD", placeholder: {}()),
        evaluateBestOf: { _, _, _, _, _, _ in fatalError("evaluateBestOf not implemented") },
        walletAccounts: unimplemented("\(Self.self).walletAccounts", placeholder: []),
        estimateBirthdayHeight: unimplemented("\(Self.self).estimateBirthdayHeight", placeholder: BlockHeight(0)),
        createPCZTFromProposal: unimplemented("\(Self.self).createPCZTFromProposal", placeholder: Pczt()),
        addProofsToPCZT: unimplemented("\(Self.self).addProofsToPCZT", placeholder: Pczt()),
        createTransactionFromPCZT: unimplemented("\(Self.self).createTransactionFromPCZT", placeholder: .success(txIds: [])),
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
        checkWalletSpendability: unimplemented("\(Self.self).checkWalletSpendability", placeholder: SpendabilityResult(earliestHeight: 0, latestHeight: 0, spentNoteIds: [], totalSpentValue: 0)),
        getPIRPendingSpends: unimplemented("\(Self.self).getPIRPendingSpends", placeholder: PIRPendingSpends(notes: [], totalValue: 0))
    )
}

extension SDKSynchronizerClient {
    public static let noOp = Self(
        stateStream: { Empty().eraseToAnyPublisher() },
        eventStream: { Empty().eraseToAnyPublisher() },
        exchangeRateUSDStream: { Empty().eraseToAnyPublisher() },
        latestState: { .zero },
        prepareWith: { _, _, _, _, _ in },
        start: { _ in },
        stop: { },
        isSyncing: { false },
        isInitialized: { false },
        importAccount: { _, _, _, _, _, _ in nil },
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
        createProposedTransactions: { _, _ in .success(txIds: []) },
        proposeShielding: { _, _, _, _ in nil },
        isSeedRelevantToAnyDerivedAccount: { _ in false },
        refreshExchangeRateUSD: { },
        evaluateBestOf: { _, _, _, _, _, _ in [] },
        walletAccounts: { [] },
        estimateBirthdayHeight: { _ in BlockHeight(0) },
        createPCZTFromProposal: { _, _ in Pczt() },
        addProofsToPCZT: { _ in Pczt() },
        createTransactionFromPCZT: { _, _ in .success(txIds: []) },
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
        checkWalletSpendability: { _, _ in SpendabilityResult(earliestHeight: 0, latestHeight: 0, spentNoteIds: [], totalSpentValue: 0) },
        getPIRPendingSpends: { PIRPendingSpends(notes: [], totalValue: 0) }
    )

    public static let mock = Self.mocked()
}

extension SDKSynchronizerClient {
    public static func mocked(
        stateStream: @escaping () -> AnyPublisher<SynchronizerState, Never> = { Just(.zero).eraseToAnyPublisher() },
        eventStream: @escaping () -> AnyPublisher<SynchronizerEvent, Never> = { Empty().eraseToAnyPublisher() },
        exchangeRateUSDStream: @escaping () -> AnyPublisher<FiatCurrencyResult?, Never> = { Empty().eraseToAnyPublisher() },
        latestState: @escaping () -> SynchronizerState = { .zero },
        latestScannedHeight: @escaping () -> BlockHeight = { 0 },
        prepareWith: @escaping ([UInt8], BlockHeight, WalletInitMode, String, String?) throws -> Void = { _, _, _, _, _ in },
        start: @escaping (_ retry: Bool) throws -> Void = { _ in },
        stop: @escaping () -> Void = { },
        isSyncing: @escaping () -> Bool = { false },
        isInitialized: @escaping () -> Bool = { false },
        importAccount: @escaping (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?) async throws -> AccountUUID? = { _, _, _, _, _, _ in nil },
        rewind: @escaping (RewindPolicy) -> AnyPublisher<Void, Error> = { _ in return Empty<Void, Error>().eraseToAnyPublisher() },
        getAllTransactions: @escaping (AccountUUID?) -> IdentifiedArrayOf<TransactionState> = { _ in
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
        transactionStatesFromZcashTransactions: @escaping (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState> = { _, _ in IdentifiedArrayOf<TransactionState>(uniqueElements: []) },
        getMemos: @escaping (_ rawID: Data) -> [Memo] = { _ in [] },
        txIdExists: @escaping (String?) -> Bool = { _ in false },
        getUnifiedAddress: @escaping (_ account: AccountUUID) -> UnifiedAddress? = { _ in
            // swiftlint:disable force_try
            try! UnifiedAddress(
                encoding: """
                utest1zkkkjfxkamagznjr6ayemffj2d2gacdwpzcyw669pvg06xevzqslpmm27zjsctlkstl2vsw62xrjktmzqcu4yu9zdhdxqz3kafa4j2q85y6mv74rzjcgjg8c0ytrg7d\
                wyzwtgnuc76h
                """,
                network: .testnet
            )
        },
        getTransparentAddress: @escaping (_ account: AccountUUID) -> TransparentAddress? = { _ in return nil },
        getSaplingAddress: @escaping (_ account: AccountUUID) async -> SaplingAddress? = { _ in
            // swiftlint:disable:next force_try
            try! SaplingAddress(
                encoding: "ztestsapling1edm52k336nk70gxqxedd89slrrf5xwnnp5rt6gqnk0tgw4mynv6fcx42ym6x27yac5amvfvwypz",
                network: .testnet
            )
        },
        getAccountsBalances: @escaping () async -> [AccountUUID: AccountBalance] = { [:] },
        wipe: @escaping () -> AnyPublisher<Void, Error>? = { Fail(error: "Error").eraseToAnyPublisher() },
        switchToEndpoint: @escaping (LightWalletEndpoint) async throws -> Void = { _ in },
        proposeTransfer:
        @escaping (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal = { _, _, _, _ in .testOnlyFakeProposal(totalFee: 0) },
        createProposedTransactions:
        @escaping (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult = { _, _ in .success(txIds: []) },
        proposeShielding:
        @escaping (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal? = { _, _, _, _ in nil },
        isSeedRelevantToAnyDerivedAccount: @escaping ([UInt8]) async throws -> Bool = { _ in false },
        refreshExchangeRateUSD: @escaping () -> Void = { },
        evaluateBestOf: @escaping ([LightWalletEndpoint], Double, Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _, _, _, _, _, _ in [] },
        walletAccounts: @escaping () async throws -> [WalletAccount] = { [] },
        estimateBirthdayHeight: @escaping (Date) -> BlockHeight = { _ in BlockHeight(0) },
        createPCZTFromProposal: @escaping (AccountUUID, Proposal) async throws -> Pczt = { _, _ in Pczt() },
        addProofsToPCZT: @escaping (Data) async throws -> Pczt = { _ in Pczt() },
        createTransactionFromPCZT: @escaping (Pczt, Pczt) async throws -> CreateProposedTransactionsResult = { _, _ in .success(txIds: []) },
        urEncoderForPCZT: @escaping (Pczt) -> UREncoder? = { _ in nil },
        redactPCZTForSigner: @escaping (Pczt) async throws -> Pczt = { _ in Pczt() },
        fetchTxidsWithMemoContaining: @escaping (String) async throws -> [Data] = { _ in [] },
        getCustomUnifiedAddress: @escaping (AccountUUID, Set<ReceiverType>) async throws -> UnifiedAddress? = { _, _ in nil },
        torEnabled: @escaping (Bool) async throws -> Void = { _ in },
        exchangeRateEnabled: @escaping (Bool) async throws -> Void = { _ in },
        isTorSuccessfullyInitialized: @escaping () async -> Bool? = { nil },
        httpRequestOverTor: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in (Data(), HTTPURLResponse.mockResponse) },
        debugDatabaseSql: @escaping (String) -> String = { _ in "" },
        getSingleUseTransparentAddress: @escaping (AccountUUID) async throws -> SingleUseTransparentAddress = { _ in
            SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
        },
        checkSingleUseTransparentAddresses: @escaping (AccountUUID) async throws -> TransparentAddressCheckResult = { _ in .notFound },
        updateTransparentAddressTransactions: @escaping (String) async throws -> TransparentAddressCheckResult = { _ in .notFound },
        fetchUTXOsByAddress: @escaping (String, AccountUUID) async throws -> TransparentAddressCheckResult = { _, _ in .notFound },
        enhanceTransactionBy: @escaping (String) async throws -> Void = { _ in },
        checkWalletSpendability: @escaping (String, SpendabilityProgressHandler?) async throws -> SpendabilityResult = { _, _ in SpendabilityResult(earliestHeight: 0, latestHeight: 0, spentNoteIds: [], totalSpentValue: 0) },
        getPIRPendingSpends: @escaping () async throws -> PIRPendingSpends = { PIRPendingSpends(notes: [], totalValue: 0) }
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
            createProposedTransactions: createProposedTransactions,
            proposeShielding: proposeShielding,
            isSeedRelevantToAnyDerivedAccount: isSeedRelevantToAnyDerivedAccount,
            refreshExchangeRateUSD: refreshExchangeRateUSD,
            evaluateBestOf: evaluateBestOf,
            walletAccounts: walletAccounts,
            estimateBirthdayHeight: estimateBirthdayHeight,
            createPCZTFromProposal: createPCZTFromProposal,
            addProofsToPCZT: addProofsToPCZT,
            createTransactionFromPCZT: createTransactionFromPCZT,
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
            checkWalletSpendability: checkWalletSpendability,
            getPIRPendingSpends: getPIRPendingSpends
        )
    }
}
