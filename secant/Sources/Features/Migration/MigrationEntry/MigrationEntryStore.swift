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
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationEntry {
    @ObservableState
    struct State: Equatable {
        var selectedMode = MigrationMode.privateScheduled
        var orchardBalance = Zatoshi.zero
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var isDisclaimerVisible: Bool {
            selectedMode == .immediate
        }

        /// `orchardBalance` converted to the user's fiat currency, e.g. `"$4,832.86"`; `nil` when
        /// no exchange rate is available (the exchange-rate feature is optional app-wide) — the
        /// parenthesized fiat amount is omitted in that case.
        var fiatText: String? {
            currencyConversion?.convert(orchardBalance)
        }

        init(
            selectedMode: MigrationMode = .privateScheduled,
            orchardBalance: Zatoshi = Zatoshi.zero
        ) {
            self.selectedMode = selectedMode
            self.orchardBalance = orchardBalance
        }
    }

    enum Action: Equatable {
        /// The orchard balance to migrate for the selected account, loaded on `onAppear`.
        case balanceLoaded(Zatoshi)
        case delegate(Delegate)
        /// The nav-bar back button. Entry is the flow's root screen, so SwiftUI `dismiss()` is a
        /// no-op here — the coordinator consumes this and exits the flow via `flowFinished`
        /// (mirrors `SendForm.dismissRequired`).
        case dismissRequired
        /// Opens the Ironwood migration support article (O-7 destination, MOB-1508) in the
        /// system browser.
        case findOutMoreTapped
        case modeTapped(MigrationMode)
        case nextTapped
        case onAppear

        enum Delegate: Equatable {
            case chose(MigrationMode)
        }
    }

    static let findOutMoreURLString = "https://support.zodl.com/article/42-moving-your-funds-to-ironwood"

    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.openURL) var openURL

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .balanceLoaded(let balance):
                state.orchardBalance = balance
                return .none

            case .delegate:
                return .none

            case .dismissRequired:
                return .none

            case .findOutMoreTapped:
                guard let url = URL(string: MigrationEntry.findOutMoreURLString) else { return .none }
                return .run { _ in await openURL(url) }

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
