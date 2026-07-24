//
//  MigrationKeystoneSignStore.swift
//  zodl
//
//  Migration-owned Keystone signing screen (MOB-1468, Figma sign frame 2867:11861). Visually
//  mirrors `SignWithKeystoneView`'s composition exactly (SendConfirmation cannot host this — its
//  PCZT pipeline is single-PCZT and proposal-centric). Batched single-session signing: this screen
//  always carries the full `[Pczt]` for the current signing context (note split / plan commit /
//  immediate review are all sessions of 1..N, uniformly, ONE animated QR per ceremony — no app-side
//  chunking, the SDK's fountain encoder decides the frame count).
//
//  MOB-1513: adopts the SDK's real Keystone batch-signing bridge
//  (`Synchronizer.buildKeystoneSignBatchQRParts(requestId:pczts:maxFragmentLen:)`) — the joint SDK +
//  Keystone-team ask this screen used to wait on (`urEncoderForMigrationPCZTBatch`, always nil) is
//  now real. `State` gains `requestId` (a fresh UUID's 16 raw bytes, generated once per ceremony
//  entry — Android parity) and `frames: [String]` (the built animated-QR frame strings; `[String]`
//  is Equatable/Sendable and can live in `@ObservableState`, unlike the old `UREncoder` — a
//  non-Equatable, non-Sendable class that could only ever be computed live in the view). An
//  `.onAppear` effect calls the bridge once and stores the resulting frames; the view cycles them
//  via `AnimatedQRCode(frames:size:)` (same 0.2s cadence as `SignWithKeystoneView`'s `UREncoder`
//  path) once they arrive, showing the same empty/loading treatment meanwhile. A build failure
//  delegates `.buildFailed`, which the coordinator maps onto the ceremony's existing abandon path
//  (`keystoneScanAbandoned` semantics) — the same honest-failure surface a scan-side failure uses.
//
//  The coordinator consumes both delegates (`.getSignature` -> scan -> decode/apply, `.rejected` ->
//  deferred pop) — MOB-1468.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationKeystoneSign {
    /// MOB-1513: the animated QR's maximum per-frame payload length. Android parity
    /// (`KeystoneBatchChunking`'s equivalent constant on that platform).
    static let maxFragmentLen = 150

    @ObservableState
    struct State: Equatable {
        var pczts: [MigrationUnsignedTransferPczt] = []
        /// MOB-1513: this ceremony's correlation token — round-tripped by the signing device and
        /// checked at scan completion (`decodeKeystoneSignBatchPart(_:expectedRequestId:)`) to reject
        /// a scan of an unrelated/stale response. A fresh UUID's 16 raw bytes, generated once per
        /// ceremony entry (Android parity) — never regenerated across this screen's lifetime, so a
        /// stray extra `.onAppear` can't silently invalidate an in-flight scan.
        let requestId: Data
        /// MOB-1513: the built animated-QR frame strings (`buildKeystoneSignBatchQRParts`), cycled by
        /// the view via `AnimatedQRCode(frames:size:)`. Empty until the `.onAppear` build effect
        /// resolves — the view shows the same empty/loading treatment `SignWithKeystoneView` shows
        /// while `pcztForUI == nil`.
        var frames: [String] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(pczts: [MigrationUnsignedTransferPczt] = []) {
            self.pczts = pczts
            self.requestId = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case framesBuildFailed
        case framesBuilt([String])
        case getSignatureTapped
        case onAppear
        case rejectTapped

        enum Delegate: Equatable {
            /// MOB-1513: `buildKeystoneSignBatchQRParts` threw — the coordinator maps this onto the
            /// ceremony's existing abandon path (`keystoneScanAbandoned` semantics).
            case buildFailed
            case getSignature
            case rejected
        }
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .framesBuildFailed:
                return .send(.delegate(.buildFailed))

            case .framesBuilt(let frames):
                state.frames = frames
                return .none

            case .getSignatureTapped:
                return .send(.delegate(.getSignature))

            case .onAppear:
                // Idempotent: a redundant re-appear (defensive — this ceremony never re-enters this
                // screen mid-flight) never rebuilds frames it already has.
                guard state.frames.isEmpty else { return .none }
                return .run { [pczts = state.pczts, requestId = state.requestId] send in
                    do {
                        let frames = try await sdkSynchronizer.buildKeystoneSignBatchQRParts(requestId, pczts, MigrationKeystoneSign.maxFragmentLen)
                        await send(.framesBuilt(frames))
                    } catch {
                        await send(.framesBuildFailed)
                    }
                }

            case .rejectTapped:
                return .send(.delegate(.rejected))
            }
        }
    }
}
