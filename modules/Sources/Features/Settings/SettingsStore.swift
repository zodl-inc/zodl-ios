import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import AppVersion
import Generated
import Models
import LocalAuthenticationHandler
import AudioServices
import WalletStorage
import SDKSynchronizer

import About
import AddKeystoneHWWallet
import AddressBook
import CurrencyConversionSetup
import DeleteWallet
import ExportTransactionHistory
import PrivateDataConsent
import RecoveryPhraseDisplay
import Scan
import ServerSetup
import SendFeedback
import WhatsNew
import TorSetup

@Reducer
public struct Settings {
    @Reducer
    public enum Path {
        case about(About)
        case accountHWWalletSelection(AddKeystoneHWWallet)
        case addKeystoneHWWallet(AddKeystoneHWWallet)
        case addressBook(AddressBook)
        case addressBookContact(AddressBook)
        case advancedSettings(AdvancedSettings)
        case chooseServerSetup(ServerSetup)
        case currencyConversionSetup(CurrencyConversionSetup)
        case exportPrivateData(PrivateDataConsent)
        case exportTransactionHistory(ExportTransactionHistory)
        case recoveryPhrase(RecoveryPhraseDisplay)
        case resetZashi(DeleteWallet)
        case scan(Scan)
        case sendUsFeedback(SendFeedback)
        case torSetup(TorSetup)
        case whatsNew(WhatsNew)
    }
    
    @ObservableState
    public struct State {
        public var addressToRecoverFunds = ""
        public var appVersion = ""
        public var appBuild = ""
        @Shared(.inMemory(.featureFlags)) public var featureFlags: FeatureFlags = .initial
        public var isEnoughFreeSpaceMode = true
        public var isInEnhanceTransactionMode = false
        public var isInRecoverFundsMode = false
        public var isTorOn = false
        public var path = StackState<Path.State>()
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var txidToEnhance = ""
        @Shared(.inMemory(.walletAccounts)) public var walletAccounts: [WalletAccount] = []

        public var isKeystoneConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .keystone {
                    return true
                }
            }
            
            return false
        }

        public var isKeystoneAccount: Bool {
            selectedWalletAccount?.vendor == .keystone
        }
        
        public init() { }
    }

    public enum Action: BindableAction {
        case aboutTapped
        case addressBookAccessCheck
        case addressBookTapped
        case advancedSettingsTapped
        case backToHomeTapped
        case binding(BindingAction<Settings.State>)
        case checkFundsForAddress(String)
        case currencyConversionTapped
        case enableEnhanceTransactionMode
        case enableRecoverFundsMode
        case fetchDataForTxid(String)
        case onAppear
        case path(StackActionOf<Path>)
        case payWithFlexaTapped
        case sendUsFeedbackTapped
        case whatsNewTapped
    }

    @Dependency(\.appVersion) var appVersion
    @Dependency(\.audioServices) var audioServices
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        coordinatorReduce()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
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

            case .aboutTapped:
                return .none
                
            case .addressBookAccessCheck:
                return .run { send in
                    if await localAuthentication.authenticate() {
                        await send(.addressBookTapped)
                    }
                }

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
    }
}
