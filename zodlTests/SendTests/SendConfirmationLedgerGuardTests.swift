//
//  SendConfirmationLedgerGuardTests.swift
//  zodlTests
//
//  MOB-2020 Phase 1.2: software signing derives a spending key from the wallet's seed, and a
//  Ledger account never has one to derive against — `.sendTriggered`'s vendor guard must reject a
//  Ledger-selected send before `derivationTool.deriveSpendingKey` is ever reached, matching the
//  same failure path the missing-proposal guard above it uses.
//
//  `SendConfirmation.State` carries `@Shared(.inMemory(...))` process-global storage (selected
//  account, wallet accounts, address book, feature flags). `.serialized` only orders this suite's
//  own tests — each test also binds a fresh in-memory store via
//  `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }` to isolate it from
//  cross-suite races on that storage, same idiom as `SendConfirmationOrchardWarningTests.swift`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SendConfirmationLedgerGuardTests {
    private static func ledgerAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0E, count: 16)),
                name: "Ledger",
                keySource: "ledger",
                seedFingerprint: nil,
                hdAccountIndex: nil,
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeState(proposal: Proposal?) -> SendConfirmation.State {
        SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: proposal
        )
    }

    @Test func sendTriggeredWithLedgerAccountSendsTheFailureActionWithoutDerivingASpendingKey() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 0)
            var initialState = makeState(proposal: proposal)
            initialState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let didDeriveKey = LockIsolated(false)
            let store = TestStore(initialState: initialState) {
                SendConfirmation()
            } withDependencies: {
                $0.derivationTool = .liveValue
                $0.derivationTool.deriveSpendingKey = { _, _, _ in
                    didDeriveKey.setValue(true)
                    Issue.record("deriveSpendingKey must not be called for a Ledger account")
                    throw "unexpected key derivation".toZcashError()
                }
                $0.mainQueue = .immediate
                // `.sendFailed`'s cascade runs all the way to `.updateResult`, which vibrates.
                // `AudioServicesClient` has no `testValue` by design (see
                // `RootSendCompletionRefreshTests.swift`), so any test that drains that far must
                // override it explicitly — same idiom as `MultiServerSubmitRoutingTests.swift`.
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            }
            store.exhaustivity = .off

            await store.send(.sendTriggered)
            await store.receive(\.sendFailed)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(!didDeriveKey.value)
        }
    }
}
