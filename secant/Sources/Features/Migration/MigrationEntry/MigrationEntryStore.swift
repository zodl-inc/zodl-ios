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
        var isInAppBrowserOn = false
        /// Audit 2026-08-03 (C10): single-flight for Next — two fast taps used to emit two
        /// `.chose` delegates and push two identical next screens. Mirrors
        /// `MigrationComplete.isMigratingAnyway`; re-armed by `.onAppear` when the user backs
        /// onto this screen.
        var isProceeding = false
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

    enum Action: BindableAction, Equatable {
        /// The orchard balance to migrate for the selected account, loaded on `onAppear`.
        case balanceLoaded(Zatoshi)
        case binding(BindingAction<MigrationEntry.State>)
        case delegate(Delegate)
        /// The nav-bar back button. Entry is the flow's root screen, so SwiftUI `dismiss()` is a
        /// no-op here — the coordinator consumes this and exits the flow via `flowFinished`
        /// (mirrors `SendForm.dismissRequired`).
        case dismissRequired
        /// Opens the Ironwood migration support article (O-7 destination, MOB-1508) in the
        /// IN-APP browser.
        case findOutMoreTapped
        case modeTapped(MigrationMode)
        case nextTapped
        case onAppear

        enum Delegate: Equatable {
            case chose(MigrationMode)
        }
    }

    /// The same support article `IronwoodAnnouncementView.ironwoodAnnouncementFAQURL` points at —
    /// it is the "moving your funds" guide, which is what both surfaces link to.
    static let findOutMoreURLString = "https://support.zodl.com/article/42-moving-your-funds-to-ironwood"

    @Dependency(\.migrationManager) var migrationManager

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .balanceLoaded(let balance):
                state.orchardBalance = balance
                return .none

            case .binding:
                return .none

            case .delegate:
                return .none

            case .dismissRequired:
                return .none

            case .findOutMoreTapped:
                // FIELD FIX (not a Phase-2 gap): #1930 opened this through `@Dependency(\.openURL)`,
                // which kicks the user out to Safari. Every other article link in the app — About's
                // policy/terms, the Keystone advert, the Ironwood announcement's own "Learn more" —
                // presents `InAppBrowserView` in a sheet, so migration was the odd one out. Fixed
                // HERE rather than left as an intentional divergence, because Phase 7's Keystone
                // firmware link and any later article link would have copied the wrong idiom from
                // this screen. #1930's `findOutMoreOpensSupportArticle` test asserts the openURL
                // effect; when tests are ported, that assertion changes with it.
                state.isInAppBrowserOn = true
                return .none

            case .modeTapped(let mode):
                state.selectedMode = mode
                return .none

            case .nextTapped:
                guard !state.isProceeding else { return .none }
                state.isProceeding = true
                return .send(.delegate(.chose(state.selectedMode)))

            case .onAppear:
                state.isProceeding = false
                let accountUUID = state.selectedWalletAccount?.id
                return .run { send in
                    let balance = await migrationManager.orchardBalanceToMigrate(accountUUID)
                    await send(.balanceLoaded(balance))
                }
            }
        }
    }
}
