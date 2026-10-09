//
//  SDKSynchronizerTransactionMappingTests.swift
//  zodlTests
//
//  MOB-1955: `SDKSynchronizerClient.transactionStatesFromZcashTransactions` read the outputs of
//  every row with one `getTransactionOutputs(for:)` call per row -- 1,255 `v_tx_outputs` queries
//  per Activity refresh on a 1,255-transaction wallet, each materialising the whole notes union
//  (25 s per refresh on an iPhone 15, field 2026-09-14). The outputs now arrive in ONE batched
//  read and the mapping is a pure function of the rows, the chain tip and that dictionary, pinned
//  here row by row: the per-row flags and the address derive exactly as before.
//
//  The mapping helper used to take `any Synchronizer`, which the app tests cannot conform to
//  (noted on MOB-1856); the pure function is the seam that makes it testable.
//

import Foundation
import Testing
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct SDKSynchronizerTransactionMappingTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x42, count: 16))
    private static let otherAccountUUID = AccountUUID(id: [UInt8](repeating: 0x24, count: 16))
    /// A valid mainnet transparent address (the one `zodlTests` already uses elsewhere).
    private static let transparentAddress = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po"

    private static func overview(rawID: Data, account: AccountUUID = accountUUID) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: account,
            blockTime: 1_699_290_621,
            expiryHeight: nil,
            fee: Zatoshi(10_000),
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: BlockHeight(4_100_000),
            raw: nil,
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
    }

    private static func output(rawID: Data, pool: ZcashTransaction.Output.Pool, recipient: TransactionRecipient) -> ZcashTransaction.Output {
        ZcashTransaction.Output(
            rawID: rawID,
            pool: pool,
            index: 0,
            fromAccount: accountUUID,
            recipient: recipient,
            value: Zatoshi(100_000),
            isChange: false,
            memo: nil
        )
    }

    /// A transparent output to a transparent address sets both flags and the address; a shielded
    /// output to an internal account sets neither and leaves the address empty.
    @Test func flagsAndAddressDeriveFromTheBatchedOutputs() throws {
        let transparentTx = Data([0x01, 0x01, 0x01, 0x01])
        let shieldedTx = Data([0x02, 0x02, 0x02, 0x02])
        let transparentRecipient = TransactionRecipient.address(try Recipient(Self.transparentAddress, network: NetworkType.mainnet))
        let outputs: [Data: [ZcashTransaction.Output]] = [
            transparentTx: [Self.output(rawID: transparentTx, pool: ZcashTransaction.Output.Pool.transaparent, recipient: transparentRecipient)],
            shieldedTx: [Self.output(rawID: shieldedTx, pool: ZcashTransaction.Output.Pool.orchard, recipient: TransactionRecipient.internalAccount(Self.otherAccountUUID))]
        ]

        let states = SDKSynchronizerClient.transactionStates(
            accountUUID: Self.accountUUID,
            zcashTransactions: [Self.overview(rawID: transparentTx), Self.overview(rawID: shieldedTx)],
            currentChainTip: BlockHeight(4_200_000),
            outputsByTransaction: outputs
        )

        let transparent = try #require(states[id: transparentTx.toHexStringTxId()])
        #expect(transparent.hasTransparentOutputs)
        #expect(transparent.isTransparentRecipient)
        #expect(transparent.zAddress == Self.transparentAddress)

        let shielded = try #require(states[id: shieldedTx.toHexStringTxId()])
        #expect(!shielded.hasTransparentOutputs)
        #expect(!shielded.isTransparentRecipient)
        #expect(shielded.zAddress == nil)
    }

    /// A row the batch has no entry for maps like a row whose per-row read answered `[]`.
    @Test func aRowWithoutOutputsMapsWithoutFlags() throws {
        let rawID = Data([0x03, 0x03, 0x03, 0x03])

        let states = SDKSynchronizerClient.transactionStates(
            accountUUID: Self.accountUUID,
            zcashTransactions: [Self.overview(rawID: rawID)],
            currentChainTip: nil,
            outputsByTransaction: [:]
        )

        let state = try #require(states[id: rawID.toHexStringTxId()])
        #expect(!state.hasTransparentOutputs)
        #expect(!state.isTransparentRecipient)
        #expect(state.zAddress == nil)
        #expect(state.rawID == rawID)
    }

    /// Only the selected account's rows are mapped, and no account maps to no rows.
    @Test func onlyTheSelectedAccountsRowsAreMapped() {
        let mine = Data([0x04, 0x04, 0x04, 0x04])
        let theirs = Data([0x05, 0x05, 0x05, 0x05])
        let rows = [Self.overview(rawID: mine), Self.overview(rawID: theirs, account: Self.otherAccountUUID)]

        let states = SDKSynchronizerClient.transactionStates(
            accountUUID: Self.accountUUID,
            zcashTransactions: rows,
            currentChainTip: nil,
            outputsByTransaction: [:]
        )
        #expect(states.map(\.id) == [mine.toHexStringTxId()])

        let none = SDKSynchronizerClient.transactionStates(
            accountUUID: nil,
            zcashTransactions: rows,
            currentChainTip: nil,
            outputsByTransaction: [:]
        )
        #expect(none.isEmpty)
    }
}
