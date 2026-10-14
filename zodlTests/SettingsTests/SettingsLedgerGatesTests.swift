//
//  SettingsLedgerGatesTests.swift
//  zodlTests
//
//  MOB-2020 Phase 1.2: a Ledger account has no signing path yet (Phase 3), so Settings must keep
//  it out of the Coinholder Polling flow — `isLedgerAccount` is the single source of truth both
//  `SettingsView`'s row visibility and `.coinholderPollingTapped`'s handler (in
//  `SettingsCoordinator.swift`'s `coordinatorReduce`) read.
//
//  `Settings.State` carries `@Shared(.inMemory(...))` process-global storage (selected account,
//  wallet accounts, feature flags). `.serialized` only orders this suite's own tests — each test
//  also binds a fresh in-memory store via `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }`
//  to isolate it from cross-suite races on that storage, same idiom as
//  `SendConfirmationOrchardWarningTests.swift`.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SettingsLedgerGatesTests {
    private static func account(idByte: UInt8, vendor: WalletAccount.Vendor) -> WalletAccount {
        let keySource: String?
        switch vendor {
        case .keystone: keySource = "keystone"
        case .ledger: keySource = "ledger"
        case .zcash: keySource = nil
        }
        return WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Test",
                keySource: keySource,
                seedFingerprint: nil,
                hdAccountIndex: vendor == .ledger ? nil : Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    @Test func isLedgerAccountTrueOnlyForLedger() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let state = Settings.State()

            state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x01, vendor: .ledger) }
            #expect(state.isLedgerAccount)

            state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x02, vendor: .keystone) }
            #expect(!state.isLedgerAccount)

            state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x03, vendor: .zcash) }
            #expect(!state.isLedgerAccount)

            state.$selectedWalletAccount.withLock { $0 = nil }
            #expect(!state.isLedgerAccount)
        }
    }

    #if VOTING_ENABLED
    /// `Settings.State` is not `Equatable` (it carries a `StackState<Path.State>` over many
    /// screens), so `TestStore` cannot be built for it — same reason
    /// `RootTransactionsTests/RootTransactionsAccountSwitchTests.swift` drives `Root.State`
    /// through a plain `Store` instead. Here the handler under test lives entirely inside
    /// `coordinatorReduce()` (the main `Reduce`'s own `.coinholderPollingTapped` case is a
    /// documented no-op — "Handled in coordinatorReduce"), so calling that one sub-reducer's
    /// `reduce(into:action:)` directly exercises the exact same guard without needing a Store at
    /// all.
    @Test func coinholderPollingTappedLeavesVotingCoordFlowNilForALedgerAccount() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Settings.State()
            state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x04, vendor: .ledger) }

            _ = Settings().coordinatorReduce().reduce(into: &state, action: .coinholderPollingTapped)

            #expect(state.votingCoordFlow == nil)
        }
    }
    #endif
}
