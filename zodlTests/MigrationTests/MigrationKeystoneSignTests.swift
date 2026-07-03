//
//  MigrationKeystoneSignTests.swift
//  zodlTests
//
//  Covers the MigrationKeystoneSign reducer
//  (Features/Migration/MigrationKeystoneSign/MigrationKeystoneSignStore.swift) for MOB-1468: the
//  default state, `getSignatureTapped`/`rejectTapped` delegate emissions, `onAppear`'s no-op
//  contract, and the `.delegate` action itself producing no further state change or effects. The
//  `UREncoder` is computed live in the view via `sdkSynchronizer.urEncoderForMigrationPCZTBatch`
//  (mirroring `SignWithKeystoneView`'s `urEncoderForPCZT` approach) rather than cached in `State`,
//  so there is no encoder-loading effect at the reducer level to assert on here. No shared/global
//  state driven by this reducer directly -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationKeystoneSignTests {
    @MainActor @Test func defaultStateHasNoPCZTsAndNoSelectedAccount() async {
        let state = MigrationKeystoneSign.State()

        #expect(state.pczts.isEmpty)
        #expect(state.selectedWalletAccount == nil)
    }

    @MainActor @Test func initWithPcztsPopulatesState() async {
        let pczts: [Pczt] = [Data([0xAA]), Data([0xBB])]
        let state = MigrationKeystoneSign.State(pczts: pczts)

        #expect(state.pczts == pczts)
    }

    @MainActor @Test func onAppearProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [Pczt()])) {
            MigrationKeystoneSign()
        }

        await store.send(.onAppear)
    }

    @MainActor @Test func getSignatureTappedEmitsDelegateGetSignature() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [Pczt()])) {
            MigrationKeystoneSign()
        }

        await store.send(.getSignatureTapped)
        await store.receive(.delegate(.getSignature))
    }

    @MainActor @Test func rejectTappedEmitsDelegateRejected() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [Pczt()])) {
            MigrationKeystoneSign()
        }

        await store.send(.rejectTapped)
        await store.receive(.delegate(.rejected))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [Pczt()])) {
            MigrationKeystoneSign()
        }

        await store.send(.delegate(.getSignature))
        await store.send(.delegate(.rejected))
    }
}
