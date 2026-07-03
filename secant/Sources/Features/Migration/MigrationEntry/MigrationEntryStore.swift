//
//  MigrationEntryStore.swift
//  zodl
//
//  "Move to Ironwood" entry screen (MOB-1460, Figma S1 · 2867:10445 / 2867:5641 / 2867:5731). Lets
//  the user pick between migrating with privacy (scheduled, split transfers) or immediately (single
//  transfer, less privacy). `onAppear` loads the orchard-balance-to-migrate for the selected account
//  (MOB-1466); `nextTapped`'s delegate is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationEntry {
    @ObservableState
    struct State: Equatable {
        var selectedMode = MigrationMode.privateScheduled
        var orchardBalance = Zatoshi.zero
        /// e.g. `"$4,832.86"`; `nil` omits the parenthesized fiat amount.
        var fiatText: String?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var isDisclaimerVisible: Bool {
            selectedMode == .immediate
        }

        init(
            selectedMode: MigrationMode = .privateScheduled,
            orchardBalance: Zatoshi = Zatoshi.zero,
            fiatText: String? = nil
        ) {
            self.selectedMode = selectedMode
            self.orchardBalance = orchardBalance
            self.fiatText = fiatText
        }
    }

    enum Action: Equatable {
        /// The orchard balance to migrate for the selected account, loaded on `onAppear`.
        case balanceLoaded(Zatoshi)
        case delegate(Delegate)
        /// Inert for now; the "Find out more" destination (O-7) is undecided.
        case findOutMoreTapped
        case modeTapped(MigrationMode)
        case nextTapped
        case onAppear

        enum Delegate: Equatable {
            case chose(MigrationMode)
        }
    }

    @Dependency(\.migrationManager) var migrationManager

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .balanceLoaded(let balance):
                state.orchardBalance = balance
                return .none

            case .delegate:
                return .none

            case .findOutMoreTapped:
                return .none

            case .modeTapped(let mode):
                state.selectedMode = mode
                return .none

            case .nextTapped:
                return .send(.delegate(.chose(state.selectedMode)))

            case .onAppear:
                let accountUUID = state.selectedWalletAccount?.id
                return .run { send in
                    let balance = await migrationManager.orchardBalanceToMigrate(accountUUID)
                    await send(.balanceLoaded(balance))
                }
            }
        }
    }
}
