//
//  AdvancedSettingsDebugResetTests.swift
//  zodlTests
//
//  Ironwood announcement, workstream 3 — the debug-only Advanced Settings row
//  (Features/Settings/AdvancedSettingsStore.swift) that lets non-App-Store builds clear the
//  Ironwood-announcement keychain flag for retesting. Unlike the other Advanced Settings rows it
//  must NOT route through the local-authentication gate (`operationAccessCheck`), since it
//  destroys nothing. Complements AdvancedSettingsTests / AdvancedSettingsAuthGateTests.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct AdvancedSettingsDebugResetTests {
    @MainActor @Test func debugResetWritesFlagFalseExactlyOnceWithoutAuthenticationOrFurtherActions() async {
        let calls = LockIsolated<[Bool]>([])
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.walletStorage.importIronwoodAnnouncementFlag = { value in
                calls.withValue { $0.append(value) }
            }
            // localAuthentication is intentionally left unimplemented: this debug-only reset must
            // never route through the biometric gate the sensitive production rows use. If it
            // accidentally did, the unimplemented closure would fail this test.
        }

        await store.send(.debugResetIronwoodAnnouncementTapped)

        // Exactly one call, writing `false` (the gate only treats exactly `true` as "already
        // shown", so `false` is equivalent to clearing the flag).
        #expect(calls.value == [false])

        // No further action was produced (exhaustive TestStore would fail on an unreceived one).
        await store.finish()
    }
}
