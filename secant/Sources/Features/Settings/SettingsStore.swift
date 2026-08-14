import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct Settings {
    @Reducer
    enum Path {
        case about(About)
        case accountHWWalletSelection(AddKeystoneHWWallet)
        case addKeystoneHWWallet(AddKeystoneHWWallet)
        case addressBook(AddressBook)
        case addressBookContact(AddressBook)
        case advancedSettings(AdvancedSettings)
        case chooseServerSetup(ServerSetup)
        case disconnectHWWallet(DisconnectHWWallet)
        case currencyConversionSetup(CurrencyConversionSetup)
        case exportPrivateData(PrivateDataConsent)
        case exportTransactionHistory(ExportTransactionHistory)
        case migrationRestart(MigrationRestart)
        case recoveryPhrase(RecoveryPhraseDisplay)
        case resetZashi(DeleteWallet)
        case resyncEstimateBirthdaysDate(WalletBirthday)
        case resyncEstimatedBirthday(WalletBirthday)
        case resyncRestoreInfo(RestoreInfo)
        case resyncWallet(ResyncWallet)
        case resyncWalletBirthday(WalletBirthday)
        case scan(Scan)
        case sendUsFeedback(SendFeedback)
        case torSetup(TorSetup)
        case whatsNew(WhatsNew)
    }
    
    @ObservableState
    struct State {
        var addressToRecoverFunds = ""
        var appVersion = ""
        var appBuild = ""
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        var isEnoughFreeSpaceMode = true
        var isInEnhanceTransactionMode = false
        var isInRecoverFundsMode = false
        var isResyncHelpSheetPresented = false
        var isTorOn = false
        var path = StackState<Path.State>()
        #if VOTING_ENABLED
        /// fullScreenCover for the new voting CoordFlow. Isolating its
        /// NavigationStack via fullScreenCover avoids SwiftUI's
        /// `AnyNavigationPath.Error.comparisonTypeMismatch` that fires when
        /// two NavigationStacks are nested.
        @Presents var votingCoordFlow: VotingCoordFlow.State?
        #endif
        var resyncBirthday: BlockHeight? = nil
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var txidToEnhance = ""
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        var isKeystoneConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .keystone {
                    return true
                }
            }
            
            return false
        }

        var isKeystoneAccount: Bool {
            selectedWalletAccount?.vendor == .keystone
        }
        
        init() { }
    }

    enum Action: BindableAction {
        case aboutTapped
        case addressBookAccessCheck
        case addressBookTapped
        case advancedSettingsTapped
        case backToHomeTapped
        case binding(BindingAction<Settings.State>)
        case checkFundsForAddress(String)
        case closeResyncHelpSheetTapped
        #if VOTING_ENABLED
        case coinholderPollingTapped
        case votingCoordFlow(PresentationAction<VotingCoordFlow.Action>)
        #endif
        case currencyConversionTapped
        case enableEnhanceTransactionMode
        case enableRecoverFundsMode
        case fetchDataForTxid(String)
        case onAppear
        case path(StackActionOf<Path>)
        case payWithFlexaTapped
        case resyncFinished
        case sendUsFeedbackTapped
        case whatsNewTapped
    }

    @Dependency(\.appVersion) var appVersion
    @Dependency(\.audioServices) var audioServices
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        coordinatorReduce()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.appVersion = appVersion.appVersion()
                state.appBuild = appVersion.appBuild()
                state.path.removeAll()
                if let torOnFlag = walletStorage.exportTorSetupFlag() {
                    state.isTorOn = torOnFlag
                }
                return .none
            
            case .backToHomeTapped:
                return .none
                
            case .binding:
                return .none

            case .closeResyncHelpSheetTapped:
                state.isResyncHelpSheetPresented = false
                return .none

            case .aboutTapped:
                return .none
                
            case .addressBookAccessCheck:
                return .run { send in
                    if await localAuthentication.authenticate(for: .addressBook) {
                        await send(.addressBookTapped)
                    }
                }

            #if VOTING_ENABLED
            case .coinholderPollingTapped:
                // Handled in coordinatorReduce; no-op here so the body's
                // exhaustive switch over the Action enum still compiles.
                return .none
            case .votingCoordFlow:
                // Presentation actions for the voting flow are routed
                // through .ifLet at the body level + the coordinator's
                // dismiss handler.
                return .none
            #endif

            case .currencyConversionTapped:
                return .none

            case .addressBookTapped:
                return .none

            case .advancedSettingsTapped:
                return .none

            case .sendUsFeedbackTapped:
                return .none

            case .whatsNewTapped:
                return .none
                
            case .path:
                return .none
                
            case .checkFundsForAddress:
                state.isInRecoverFundsMode = false
                return .none
                
            case .enableRecoverFundsMode:
                state.addressToRecoverFunds = ""
                state.isInRecoverFundsMode = true
                return .none

            case .payWithFlexaTapped:
                return .none

            case .resyncFinished:
                return .none

            case .enableEnhanceTransactionMode:
                state.txidToEnhance = ""
                state.isInEnhanceTransactionMode = true
                return .none

            case .fetchDataForTxid(let txId):
                state.isInEnhanceTransactionMode = false
                return .run { send in
                    try? await sdkSynchronizer.enhanceTransactionBy(txId)
                }
            }
        }
        .forEach(\.path, action: \.path)
        #if VOTING_ENABLED
        .ifLet(\.$votingCoordFlow, action: \.votingCoordFlow) {
            VotingCoordFlow()
        }
        #endif
    }
}
