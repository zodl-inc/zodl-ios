#if canImport(UIKit)
import UIKit
#endif
import Combine
import SwiftUI
@preconcurrency import AVFoundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct Home {
    @ObservableState
    struct State: Equatable {
        var CancelEventId = UUID()
        var accountSwitchRequest = false
        @Presents var alert: AlertState<Action>?
        var appId: String?
        var canRequestReview = false
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        var isInAppBrowserKeystoneOn = false
        var isRateEducationEnabled = false
        var isRateTooltipEnabled = false
        var migratingDatabase = true
        var moreRequest = false
        var payRequest = false
        var poolBalancesRequest = false
        var smartBannerState = SmartBanner.State.initial
        var walletConfig: WalletConfig
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var transactionListState: TransactionList.State
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        var walletBalancesState: WalletBalances.State

        var isSmartWidgetOpen: Bool {
            smartBannerState.isOpen
        }

        var isKeystoneAccountActive: Bool {
            selectedWalletAccount?.vendor == .keystone
        }
        
        var isKeystoneConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .keystone {
                    return true
                }
            }
            
            return false
        }

        var inAppBrowserURLKeystone: String {
            "https://keyst.one/shop/products/keystone-3-pro?discount=Zodl"
        }

        init(
            canRequestReview: Bool = false,
            migratingDatabase: Bool = true,
            transactionListState: TransactionList.State,
            walletBalancesState: WalletBalances.State,
            walletConfig: WalletConfig
        ) {
            self.canRequestReview = canRequestReview
            self.migratingDatabase = migratingDatabase
            self.transactionListState = transactionListState
            self.walletConfig = walletConfig
            self.walletBalancesState = walletBalancesState
        }
    }

    enum Action: BindableAction, Equatable {
        case accountSwitchTapped
        case addKeystoneHWWalletTapped
        case alert(PresentationAction<Action>)
        case binding(BindingAction<Home.State>)
        case buyTapped
        case currencyConversionCloseTapped
        case currencyConversionSetupTapped
        /// The migration smart banner was tapped — Root opens `MigrationCoordFlow`.
        case migrationTapped
        case foundTransactions
        case keystoneBannerTapped
        case moreTapped
        case moreInMoreTapped
        case onAppear
        case onDisappear
        case payTapped
        case payWithNearTapped
        case poolBalancesDismissTapped
        case presentKeystoneWeb
        case rateTooltipTapped
        case receiveScreenRequested
        case receiveTapped
        case resolveReviewRequest
        case retrySync
        case reviewRequestFinished
        case scanTapped
        case seeAllTransactionsTapped
        case sendTapped
        case settingsTapped
        case showSynchronizerErrorAlert(ZcashError)
        case smartBanner(SmartBanner.Action)
        case swapWithNearTapped
        case synchronizerStateChanged(RedactableSynchronizerState)
        case syncFailed(ZcashError)
        case torSetupTapped(Bool)
        case updatePrivateUA(UnifiedAddress?)
        case updateTransactionList([TransactionState])
        case transactionList(TransactionList.Action)
        case walletAccountTapped(WalletAccount)
        case walletBalances(WalletBalances.Action)
        
        // more actions
        case flexaTapped
    }
    
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.reviewRequest) var reviewRequest
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.swapAndPay) var swapAndPay
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }
    
    var body: some Reducer<State, Action> {
        BindingReducer()

        Scope(state: \.transactionListState, action: \.transactionList) {
            TransactionList()
        }

        Scope(state: \.walletBalancesState, action: \.walletBalances) {
            WalletBalances()
        }

        Scope(state: \.smartBannerState, action: \.smartBanner) {
            SmartBanner()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.appId = PartnerKeys.cbProjectId
                state.walletBalancesState.migratingDatabase = state.migratingDatabase
                state.migratingDatabase = false
                state.isRateEducationEnabled = userStoredPreferences.exchangeRate() == nil
                return .merge(
                    .publisher {
                        // Filter BEFORE throttling: throttling the raw stream with `latest: true`
                        // lets an unrelated event in the same window replace `foundTransactions`
                        // as "latest" and silently drop the refresh trigger.
                        sdkSynchronizer.eventStream()
                            .compactMap {
                                if case SynchronizerEvent.foundTransactions = $0 {
                                    return Home.Action.foundTransactions
                                }
                                return nil
                            }
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                    }
                    .cancellable(id: state.CancelEventId, cancelInFlight: true),
                    .send(.smartBanner(.onAppear)),
                    .send(.transactionList(.onAppear)),
                    .send(.walletBalances(.onAppear))
                )
                
            case .onDisappear:
                // __LD2 TESTED
                return .merge(
                    .cancel(id: state.CancelEventId),
                    .send(.smartBanner(.onDisappear)),
                    .send(.walletBalances(.onDisappear))
                )

            case .receiveScreenRequested:
                let isKeystone = state.selectedWalletAccount?.vendor == .keystone
                if let uuid = state.selectedWalletAccount?.id {
                    return .run { send in
                        let privateUA = try? await sdkSynchronizer.getCustomUnifiedAddress(uuid, isKeystone ? [.orchard] : [.sapling, .orchard])
                        await send(.updatePrivateUA(privateUA))
                        await send(.receiveTapped)
                    }
                }
                return .send(.receiveTapped)

            case .updatePrivateUA(let privateUA):
                state.$selectedWalletAccount.withLock { $0?.privateUA = privateUA }
                return .none

            case .receiveTapped:
                return .none

            case .sendTapped:
                return .none

            case .swapWithNearTapped:
                state.moreRequest = false
                return .none

            case .payWithNearTapped:
                state.moreRequest = false
                state.payRequest = false
                return .none

            case .scanTapped:
                return .none

            case .moreTapped:
                state.moreRequest = true
                return .none

            case .moreInMoreTapped:
                state.moreRequest = false
                return .send(.settingsTapped)

            case .buyTapped:
                return .none
                
            case .payTapped:
                state.payRequest = true
                return .none

            case .resolveReviewRequest:
                if reviewRequest.canRequestReview() {
                    state.canRequestReview = true
                    return .run { _ in
                        reviewRequest.reviewRequested()
                    }
                }
                return .none
                
            case .reviewRequestFinished:
                state.canRequestReview = false
                return .none

            case .seeAllTransactionsTapped:
                return .none
                
            case .updateTransactionList:
                return .none
                
            case .synchronizerStateChanged(let latestState):
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)
                switch snapshot.syncStatus {
                case .error(let error):
                    return .send(.showSynchronizerErrorAlert(error.toZcashError()))

                case .upToDate:
                    return .run { _ in
                        reviewRequest.syncFinished()
                    }

                default:
                    return .none
                }

            case .foundTransactions:
                return .run { _ in
                    reviewRequest.foundTransactions()
                }
                
            case .transactionList:
                return .none
                
            case .retrySync:
                return .run { send in
                    do {
                        try await sdkSynchronizer.start(true)
                    } catch {
                        await send(.syncFailed(error.toZcashError()))
                    }
                }

            case .currencyConversionCloseTapped:
                state.isRateEducationEnabled = false
                let existingCurrency = userStoredPreferences.exchangeRate()?.currency ?? .usd
                try? userStoredPreferences.setExchangeRate(
                    UserPreferencesStorage.ExchangeRate(manual: true, automatic: false, currency: existingCurrency)
                )
                return .none

            case .rateTooltipTapped:
                state.isRateTooltipEnabled = false
                return .none

            case .showSynchronizerErrorAlert:
                return .none
                
            case .syncFailed:
                return .none

            case .walletBalances(.exchangeRateRefreshTapped):
                if state.isRateTooltipEnabled {
                    state.isRateTooltipEnabled = false
                    return .none
                }
                state.isRateTooltipEnabled = state.walletBalancesState.isExchangeRateStale
                return .none

            case .walletBalances(.balanceTapped):
                state.poolBalancesRequest = true
                return .none

            case .poolBalancesDismissTapped:
                state.poolBalancesRequest = false
                return .none

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none
                
            case .settingsTapped:
                return .none
                
            case .binding:
                return .none
                
            case .migrationTapped:
                // Root consumes this to open `MigrationCoordFlow` (same shape as
                // `.currencyConversionSetupTapped` below).
                return .none

            case .currencyConversionSetupTapped:
                return .none

            case .torSetupTapped:
                return .none

                // Accounts
                
            case .accountSwitchTapped:
                state.accountSwitchRequest.toggle()
                return .none

            case .addKeystoneHWWalletTapped:
                state.accountSwitchRequest = false
                state.moreRequest = false
                return .none

            case .keystoneBannerTapped:
                state.accountSwitchRequest = false
                return .run { send in
#if os(macOS)
                    // [B4-11] Only needs to outlast the account-switch card's CLOSE animation —
                    // the macOS sheet host (MacSplitView) has no presentation conflict with the
                    // closing overlay, so this is purely visual pacing. Field: 1 s felt long.
                    try? await mainQueue.sleep(for: .seconds(0.35))
#else
                    try? await mainQueue.sleep(for: .seconds(1))
#endif
                    await send(.presentKeystoneWeb)
                }

            case .presentKeystoneWeb:
                // [B4-11] In-app on both platforms. The old macOS failure was (very likely) NOT the
                // present-after-MacCard trap: the sheet host lived on HomeView, which is absent from
                // the macOS view tree — the flag flipped with nobody listening. macOS now hosts the
                // sheet in MacSplitView (like the account-switch card). If the trap does still bite,
                // fall back to NSWorkspace.shared.open (external browser) here.
                state.isInAppBrowserKeystoneOn = true
                return .none

            case .walletAccountTapped:
                state.accountSwitchRequest = false
                return .none

                // Smart Banner

            case .smartBanner(.currencyConversionScreenRequested):
                return .send(.currencyConversionSetupTapped)

            case .smartBanner(.migrationScreenRequested):
                return .send(.migrationTapped)

            case .smartBanner(.torSetupScreenRequested):
                return .send(.torSetupTapped(false))

            case .smartBanner(.torSettingsRequested):
                return .send(.torSetupTapped(true))

                // More actions

            case .flexaTapped:
                return .none

            case .walletBalances:
                return .none
                
            case .smartBanner:
                return .none
            }
        }
    }
}
