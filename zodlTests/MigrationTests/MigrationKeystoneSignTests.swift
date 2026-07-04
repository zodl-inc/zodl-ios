//
//  MigrationKeystoneSignTests.swift
//  zodlTests
//
//  Covers the MigrationKeystoneSign reducer
//  (Features/Migration/MigrationKeystoneSign/MigrationKeystoneSignStore.swift) for MOB-1468/1469:
//  the default state, the per-session `pczt`/`sessionIndex`/`sessionTotal` init (one screen
//  instance per sequential signing session — the "Transfer i of N" indicator renders from these,
//  and only when `sessionTotal > 1`), `getSignatureTapped`/`rejectTapped` delegate emissions,
//  `onAppear`'s no-op contract, and the `.delegate` action itself producing no further state
//  change or effects. The `UREncoder` is computed live in the view via the send flow's
//  `sdkSynchronizer.urEncoderForPCZT(pczt)` (mirroring `SignWithKeystoneView`) rather than cached
//  in `State`, so there is no encoder-loading effect at the reducer level to assert on here. No
//  shared/global state driven by this reducer directly -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationKeystoneSignTests {
    @MainActor @Test func defaultStateIsASingleSessionWithAnEmptyPCZT() async {
        let state = MigrationKeystoneSign.State()

        #expect(state.pczt.isEmpty)
        #expect(state.sessionIndex == 1)
        #expect(state.sessionTotal == 1)
        #expect(state.selectedWalletAccount == nil)
    }

    @MainActor @Test func initWithSessionFieldsPopulatesState() async {
        let pczt: Pczt = Data([0xAA, 0xBB])
        let state = MigrationKeystoneSign.State(pczt: pczt, sessionIndex: 2, sessionTotal: 5)

        #expect(state.pczt == pczt)
        #expect(state.sessionIndex == 2)
        #expect(state.sessionTotal == 5)
    }

    @MainActor @Test func onAppearProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczt: Pczt())) {
            MigrationKeystoneSign()
        }

        await store.send(.onAppear)
    }

    @MainActor @Test func getSignatureTappedEmitsDelegateGetSignature() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczt: Pczt())) {
            MigrationKeystoneSign()
        }

        await store.send(.getSignatureTapped)
        await store.receive(.delegate(.getSignature))
    }

    @MainActor @Test func rejectTappedEmitsDelegateRejected() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczt: Pczt())) {
            MigrationKeystoneSign()
        }

        await store.send(.rejectTapped)
        await store.receive(.delegate(.rejected))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczt: Pczt())) {
            MigrationKeystoneSign()
        }

        await store.send(.delegate(.getSignature))
        await store.send(.delegate(.rejected))
    }

    @MainActor @Test func sessionIndicatorLocalizationRendersIndexAndTotal() async {
        // The view's "Transfer i of N" indicator (rendered only when sessionTotal > 1) uses the
        // migration-owned session key — pin the argument order (index before total).
        let label = String(localizable: .migrationKeystoneSignSession(2, 5))

        #expect(label.contains("2"))
        #expect(label.contains("5"))
        #expect(label.range(of: "2")!.lowerBound < label.range(of: "5")!.lowerBound)
    }
}
