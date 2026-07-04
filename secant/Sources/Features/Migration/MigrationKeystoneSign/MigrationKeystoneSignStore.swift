//
//  MigrationKeystoneSignStore.swift
//  zodl
//
//  Migration-owned Keystone signing screen (MOB-1468/1469, Figma sign frame 2867:11861). Visually
//  mirrors `SignWithKeystoneView`'s composition exactly (SendConfirmation cannot host this — its
//  PCZT pipeline is proposal-centric). One screen instance per SEQUENTIAL signing session: `pczt`
//  is the single redacted, QR-ready PCZT for session `sessionIndex` of `sessionTotal` (1-based;
//  note split and immediate mode are naturally 1 of 1, a plan commit runs one session per
//  transfer). The `UREncoder` is computed live in the view via the send flow's proven
//  `sdkSynchronizer.urEncoderForPCZT(pczt)` — never cached in `State` (the same approach
//  `SignWithKeystoneView` uses), since `UREncoder` is a non-`Equatable`, non-`Sendable` class that
//  cannot live in an `@ObservableState` `Equatable` struct. The coordinator consumes both
//  delegates (`.getSignature` -> scan -> next session or submit/store, `.rejected` -> deferred pop
//  discarding the whole queue) — see `MigrationCoordFlowCoordinator`'s Keystone rows.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationKeystoneSign {
    @ObservableState
    struct State: Equatable {
        /// The redacted, QR-ready PCZT this session signs.
        var pczt = Pczt()
        /// 1-based position of this session in the signing queue (display: "Transfer i of N").
        var sessionIndex = 1
        /// Total sessions in the queue; the "i of N" indicator only renders when > 1.
        var sessionTotal = 1
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(pczt: Pczt = Pczt(), sessionIndex: Int = 1, sessionTotal: Int = 1) {
            self.pczt = pczt
            self.sessionIndex = sessionIndex
            self.sessionTotal = sessionTotal
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
        Reduce { _, action in
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
