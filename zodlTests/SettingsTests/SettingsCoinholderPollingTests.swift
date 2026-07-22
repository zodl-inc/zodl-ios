//
//  SettingsCoinholderPollingTests.swift
//  zodlTests
//
//  MOB-1507 — the Beta: Coinholder Polling entry is gated behind
//  FeatureFlags.coinholderPolling (Features/Settings/SettingsCoordinator.swift).
//  The row itself is flag-gated in SettingsView; these tests pin the reducer-side
//  guard so the hidden flow cannot open from a stray or replayed action.
//
//  Settings.State is not Equatable, so TestStore cannot host it — a plain Store
//  with withState probes is used instead; both actions return .none, so sends
//  settle synchronously on the main actor.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) @MainActor struct SettingsCoinholderPollingTests {
    @Test func tapIsIgnoredWhileFlagIsOff() {
        var state = Settings.State()
        state.$featureFlags.withLock { $0 = FeatureFlags() }
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        let store = Store(initialState: state) {
            Settings()
        }
        store.send(.coinholderPollingTapped)
        #expect(store.withState { $0.votingCoordFlow } == nil)
    }

    @Test func tapOpensVotingFlowWhileFlagIsOn() {
        let account = keystoneAccount()
        var state = Settings.State()
        state.$featureFlags.withLock { $0 = FeatureFlags(coinholderPolling: true) }
        state.$selectedWalletAccount.withLock { $0 = account }
        let store = Store(initialState: state) {
            Settings()
        }
        store.send(.coinholderPollingTapped)
        let voting = store.withState { $0.votingCoordFlow }
        #expect(voting != nil)
        #expect(voting?.isKeystoneUser == true)
        #expect(voting?.walletId == account.id.id.map { String(format: "%02x", $0) }.joined())
    }

    private func keystoneAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }
}
