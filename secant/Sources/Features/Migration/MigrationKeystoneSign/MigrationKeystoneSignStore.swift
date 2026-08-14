//
//  MigrationKeystoneSignStore.swift
//  zodl
//
//  Migration-owned Keystone signing screen (MOB-1468, Figma sign frame 2867:11861). Visually
//  mirrors `SignWithKeystoneView`'s composition exactly (SendConfirmation cannot host this — its
//  PCZT pipeline is single-PCZT and proposal-centric). Batched signing: this screen carries the
//  current ROUND's slice of the signing context's batch — MOB-1513 (R9) caps a round at
//  one signing round's ACTION budget (96 for Keystone; a preparation weighs 16, a transfer 3), so a large
//  batch signs across several sign→scan round trips driven by `MigrationCoordFlowCoordinator`,
//  while a batch within the cap remains ONE animated QR per ceremony (within a round the SDK's
//  fountain encoder still decides the frame count). `roundIndex`/`totalRounds` surface "Round X of
//  Y" for multi-round ceremonies.
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
//  The coordinator consumes all three delegates (`.getSignature` -> scan -> decode/apply,
//  `.rejected` -> deferred pop, `.buildFailed` -> `keystoneScanAbandoned`) — MOB-1468
//  (`.buildFailed` added by MOB-1513, per this file's header above).
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationKeystoneSign {
    /// MOB-1513: the animated QR's maximum per-frame payload length. Android parity
    /// (the equivalent budget on that platform).
    static let maxFragmentLen = 150

    @ObservableState
    struct State: Equatable {
        var pczts: [MigrationUnsignedTransferPczt] = []
        /// MOB-1513: this ceremony's correlation token — round-tripped by the signing device and
        /// checked at scan completion (`decodeKeystoneSignBatchPart(_:expectedRequestId:)`) to reject
        /// a scan of an unrelated/stale response. A fresh UUID's 16 raw bytes, generated once per
        /// ceremony entry (Android parity) — never regenerated across this screen's lifetime, so a
        /// stray extra `.onAppear` can't silently invalidate an in-flight scan. Batch-mode only —
        /// the single-PCZT mode's production `zcash-pczt` protocol has no request-id concept.
        let requestId: Data
        /// MOB-1513: the built animated-QR frame strings (`buildKeystoneSignBatchQRParts`), cycled by
        /// the view via `AnimatedQRCode(frames:size:)`. Empty until the `.onAppear` build effect
        /// resolves — the view shows the same empty/loading treatment `SignWithKeystoneView` shows
        /// while `pcztForUI == nil`. Batch-mode only — stays empty in single-PCZT mode.
        var frames: [String] = []
        /// MOB-1513 (R8): non-nil puts this screen in SINGLE-PCZT mode — the immediate lane's
        /// PRODUCTION ceremony: the view computes `urEncoderForPCZT` live over these
        /// redacted-for-signer bytes (`SignWithKeystoneView` parity; a `UREncoder` is a
        /// non-`Equatable`, non-`Sendable` class that can't live in `@ObservableState`), the batch
        /// frames build never runs, and the coordinator configures the scan session with the
        /// production checker. `pczts` then carries the single UNREDACTED original the coordinator's
        /// post-scan submit reads (`addProofsToPCZT` needs the full PCZT — the redaction is
        /// wire-only). Batch (scheduled/recovery) ceremonies leave this nil and behave exactly as
        /// before.
        var redactedSinglePczt: Data?
        /// MOB-1513 (R9): this screen's 0-based position in the ceremony's capped signing
        /// sequence — display-only ("Round X of Y"); the coordinator owns the actual round
        /// bookkeeping (`MigrationCoordFlow.State.keystoneBatchRounds`).
        let roundIndex: Int
        /// MOB-1513 (R9): how many rounds the whole ceremony needs
        /// (the SDK packer's round count). 1 — the common case — hides the indicator.
        let totalRounds: Int
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(
            pczts: [MigrationUnsignedTransferPczt] = [],
            redactedSinglePczt: Data? = nil,
            roundIndex: Int = 0,
            totalRounds: Int = 1
        ) {
            self.pczts = pczts
            self.redactedSinglePczt = redactedSinglePczt
            self.roundIndex = roundIndex
            self.totalRounds = totalRounds
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
                // MOB-1513 (R8): single-PCZT mode never builds batch frames — the view computes the
                // production `urEncoderForPCZT` QR live over `redactedSinglePczt`.
                guard state.redactedSinglePczt == nil else { return .none }
                // Idempotent: a redundant re-appear (defensive — this ceremony never re-enters this
                // screen mid-flight) never rebuilds frames it already has.
                guard state.frames.isEmpty else { return .none }
                return .run { [pczts = state.pczts, requestId = state.requestId] send in
                    do {
                        let frames = try await sdkSynchronizer.buildKeystoneSignBatchQRParts(requestId, pczts, MigrationKeystoneSign.maxFragmentLen)
                        await send(.framesBuilt(frames))
                    } catch {
                        LoggerProxy.error("[MOB-1513] Keystone batch QR frames build failed: \(error)")
                        await send(.framesBuildFailed)
                    }
                }

            case .rejectTapped:
                return .send(.delegate(.rejected))
            }
        }
    }
}
