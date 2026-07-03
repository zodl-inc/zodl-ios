//
//  MigrationEntryStore.swift
//  zodl
//
//  "Move to Ironwood" entry screen (MOB-1460, Figma S1 · 2867:10445 / 2867:5641 / 2867:5731). Lets
//  the user pick between migrating with privacy (scheduled, split transfers) or immediately (single
//  transfer, less privacy). The delegate is emitted but consumed by nobody yet — chaining into the
//  rest of the migration flow lands in MOB-1466.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationEntry {
    @ObservableState
    struct State: Equatable {
        var selectedMode = MigrationMode.privateScheduled
        /// Placeholder; real balance data lands in MOB-1466.
        var orchardBalance = Zatoshi.zero
        /// e.g. `"$4,832.86"`; `nil` omits the parenthesized fiat amount.
        var fiatText: String?

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
        case delegate(Delegate)
        /// Inert for now; the "Find out more" destination (O-7) is undecided.
        case findOutMoreTapped
        case modeTapped(MigrationMode)
        case nextTapped

        enum Delegate: Equatable {
            case chose(MigrationMode)
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .findOutMoreTapped:
                return .none

            case .modeTapped(let mode):
                state.selectedMode = mode
                return .none

            case .nextTapped:
                return .send(.delegate(.chose(state.selectedMode)))
            }
        }
    }
}
