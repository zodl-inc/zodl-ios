//
//  MigrationKeystoneSignTests.swift
//  zodlTests
//
//  Covers the MigrationKeystoneSign reducer
//  (Features/Migration/MigrationKeystoneSign/MigrationKeystoneSignStore.swift) for MOB-1468/
//  MOB-1513: the default state (including the per-ceremony `requestId`), `getSignatureTapped`/
//  `rejectTapped` delegate emissions, the `.onAppear` build effect
//  (`sdkSynchronizer.buildKeystoneSignBatchQRParts`) populating `frames` on success or delegating
//  `.buildFailed` on a throw, and the `.delegate` action itself producing no further state change or
//  effects. No shared/global state driven by this reducer directly -> no `.serialized`.
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
        #expect(state.frames.isEmpty)
        #expect(state.selectedWalletAccount == nil)
    }

    @MainActor @Test func initWithPcztsPopulatesState() async {
        let pczts: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let state = MigrationKeystoneSign.State(pczts: pczts)

        #expect(state.pczts == pczts)
        #expect(state.frames.isEmpty)
    }

    /// MOB-1513: `requestId` is a fresh UUID's 16 raw bytes, generated once per ceremony entry
    /// (Android parity) — never all-zero, and two ceremonies never collide.
    @MainActor @Test func requestIdIsSixteenFreshRandomBytesPerCeremony() async {
        let first = MigrationKeystoneSign.State()
        let second = MigrationKeystoneSign.State()

        #expect(first.requestId.count == 16)
        #expect(second.requestId.count == 16)
        #expect(first.requestId != second.requestId)
    }

    /// MOB-1513: `.onAppear` calls `buildKeystoneSignBatchQRParts` with this ceremony's `pczts` and
    /// `requestId`, and Android-parity `maxFragmentLen` (150) — a success populates `frames`.
    @MainActor @Test func onAppearBuildSuccessPopulatesFrames() async {
        let pczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        let capturedArgs = LockIsolated<(Data, [MigrationUnsignedTransferPczt], Int)?>(nil)
        let state = MigrationKeystoneSign.State(pczts: pczts)
        let expectedRequestId = state.requestId
        let store = TestStore(initialState: state) {
            MigrationKeystoneSign()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.buildKeystoneSignBatchQRParts = { requestId, pczts, maxFragmentLen in
                capturedArgs.setValue((requestId, pczts, maxFragmentLen))
                return ["FRAME1", "FRAME2", "FRAME3"]
            }
        }

        await store.send(.onAppear)
        await store.receive(\.framesBuilt) {
            $0.frames = ["FRAME1", "FRAME2", "FRAME3"]
        }

        #expect(capturedArgs.value?.0 == expectedRequestId)
        #expect(capturedArgs.value?.1 == pczts)
        #expect(capturedArgs.value?.2 == MigrationKeystoneSign.maxFragmentLen)
        #expect(MigrationKeystoneSign.maxFragmentLen == 150)
    }

    /// A redundant re-appear (defensive — this ceremony never re-enters this screen mid-flight)
    /// never rebuilds frames it already has.
    @MainActor @Test func onAppearIsIdempotentOnceFramesArePopulated() async {
        var state = MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])
        state.frames = ["ALREADY-BUILT"]
        let store = TestStore(initialState: state) {
            MigrationKeystoneSign()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.buildKeystoneSignBatchQRParts = { _, _, _ in
                Issue.record("Must not rebuild once frames are already populated")
                return []
            }
        }

        await store.send(.onAppear)
    }

    /// MOB-1513: a build failure (`buildKeystoneSignBatchQRParts` throws) delegates `.buildFailed` —
    /// the coordinator maps this onto the ceremony's existing abandon path
    /// (`keystoneScanAbandoned` semantics), the same honest-failure surface a scan-side failure uses.
    @MainActor @Test func onAppearBuildFailureDelegatesBuildFailed() async {
        struct BuildFailure: Error { }
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])) {
            MigrationKeystoneSign()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.buildKeystoneSignBatchQRParts = { _, _, _ in throw BuildFailure() }
        }

        await store.send(.onAppear)
        await store.receive(\.framesBuildFailed)
        await store.receive(.delegate(.buildFailed))

        #expect(store.state.frames.isEmpty)
    }

    /// MOB-1513 (R8): SINGLE-PCZT mode (`redactedSinglePczt` set — the immediate lane's production
    /// ceremony) never builds batch frames: the view computes the production `urEncoderForPCZT` QR
    /// live over the redacted bytes, so `.onAppear` must not touch the batch bridge at all.
    @MainActor @Test func onAppearInSinglePcztModeNeverBuildsBatchFrames() async {
        let state = MigrationKeystoneSign.State(
            pczts: [MigrationUnsignedTransferPczt(id: "immediate", pczt: Data([0xAA]))],
            redactedSinglePczt: Data([0xAA, 0x0F])
        )
        let store = TestStore(initialState: state) {
            MigrationKeystoneSign()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.buildKeystoneSignBatchQRParts = { _, _, _ in
                Issue.record("Single-PCZT mode must never call the batch QR builder")
                return []
            }
        }

        await store.send(.onAppear)

        #expect(store.state.frames.isEmpty)
    }

    @MainActor @Test func getSignatureTappedEmitsDelegateGetSignature() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])) {
            MigrationKeystoneSign()
        }

        await store.send(.getSignatureTapped)
        await store.receive(.delegate(.getSignature))
    }

    @MainActor @Test func rejectTappedEmitsDelegateRejected() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])) {
            MigrationKeystoneSign()
        }

        await store.send(.rejectTapped)
        await store.receive(.delegate(.rejected))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])) {
            MigrationKeystoneSign()
        }

        await store.send(.delegate(.getSignature))
        await store.send(.delegate(.rejected))
        await store.send(.delegate(.buildFailed))
    }
}
