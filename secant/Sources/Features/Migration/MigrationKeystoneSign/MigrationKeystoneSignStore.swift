//
//  MigrationKeystoneSignStore.swift
//  zodl
//
//  Migration-owned Keystone signing screen (MOB-1468, Figma sign frame 2867:11861). Visually
//  mirrors `SignWithKeystoneView`'s composition exactly (SendConfirmation cannot host this — its
//  PCZT pipeline is single-PCZT and proposal-centric). Batched single-session signing: this screen
//  always carries the full `[Pczt]` for the current signing context (note split / plan commit /
//  immediate review are all sessions of 1..N, uniformly). The `UREncoder` is computed live in the
//  view via `sdkSynchronizer.urEncoderForMigrationPCZTBatch(pczts)` — never cached in `State` (the
//  same approach `SignWithKeystoneView` uses for `urEncoderForPCZT`), since `UREncoder` is a
//  non-`Equatable`, non-`Sendable` class that cannot live in an `@ObservableState` `Equatable`
//  struct. The batch encoder still returns `nil` today — no batch UR format exists yet (a joint
//  SDK + Keystone-team ask, device support unvalidated; see `urEncoderForMigrationPCZTBatch` in
//  `SDKSynchronizerLive`), independent of the migration SDK wiring otherwise being complete — so
//  the QR area renders the same empty/loading treatment `SignWithKeystoneView` shows while
//  `pcztForUI == nil`. The coordinator consumes both delegates (`.getSignature` -> scan ->
//  submit/store, `.rejected` -> deferred pop) — MOB-1468.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationKeystoneSign {
    @ObservableState
    struct State: Equatable {
        var pczts: [MigrationUnsignedTransferPczt] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(pczts: [MigrationUnsignedTransferPczt] = []) {
            self.pczts = pczts
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case getSignatureTapped
        case onAppear
        case rejectTapped

        enum Delegate: Equatable {
            case getSignature
            case rejected
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .getSignatureTapped:
                return .send(.delegate(.getSignature))

            case .onAppear:
                return .none

            case .rejectTapped:
                return .send(.delegate(.rejected))
            }
        }
    }
}
