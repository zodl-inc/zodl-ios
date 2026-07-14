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
//  struct. Stubbed today: the batch encoder returns `nil`, so the QR area renders the same
//  empty/loading treatment `SignWithKeystoneView` shows while `pcztForUI == nil` — dormant, by
//  design, until the SDK + Keystone batch support land (MOB-1455). The coordinator consumes both
//  delegates (`.getSignature` -> scan -> submit/store, `.rejected` -> deferred pop) — MOB-1468.
//
//  MOB-1480 adds a simulator-only bypass: a "Simulate signed result" button, visible iff
//  `MigrationSimulatorFlag.isEnabled && migrationSimulator.readout().isActive` (computed once in
//  `onAppear`), delegates `.simulateSignature` so the coordinator can feed the exact post-scan path
//  with the batch already carried in `State.pczts` — no physical Keystone device required.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationKeystoneSign {
    @ObservableState
    struct State: Equatable {
        var pczts: [Pczt] = []
        /// MOB-1480: drives the simulator-only "Simulate signed result" button's visibility — set
        /// once in `onAppear`, never touched anywhere else.
        var isSimulatorBypassVisible = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(pczts: [Pczt] = []) {
            self.pczts = pczts
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case getSignatureTapped
        case onAppear
        case rejectTapped
        /// MOB-1480: the simulator-only "Simulate signed result" button tap (visible iff
        /// `State.isSimulatorBypassVisible`). The coordinator handles the delegate by mirroring the
        /// real scanned-batch path, minus the scan step itself.
        case simulateSignatureTapped

        enum Delegate: Equatable {
            case getSignature
            case rejected
            case simulateSignature
        }
    }

    @Dependency(\.migrationSimulator) var migrationSimulator

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .getSignatureTapped:
                return .send(.delegate(.getSignature))

            case .onAppear:
                state.isSimulatorBypassVisible = MigrationSimulatorFlag.isEnabled && migrationSimulator.readout().isActive
                return .none

            case .rejectTapped:
                return .send(.delegate(.rejected))

            case .simulateSignatureTapped:
                return .send(.delegate(.simulateSignature))
            }
        }
    }
}
