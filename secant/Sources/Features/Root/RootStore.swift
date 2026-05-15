import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import Foundation
import BackgroundTasks
import Flexa

@Reducer
struct Root {
    enum ResetZashiConstants {
        static let maxResetZashiAppAttempts = 3
        static let maxResetZashiSDKAttempts = 3
    }

    @ObservableState
    struct State {
        enum Path {
            case addKeystoneHWWalletCoordFlow
            case currencyConversionSetup
            case receive
            case requestZecCoordFlow
            case scanCoordFlow
            case sendCoordFlow
            case serverSwitch
            case settings
            case swapAndPayCoordFlow
            case torSetup
            case transactionsCoordFlow
            case walletBackup
        }
        
        var CancelEventId = UUID()
        var CancelId = UUID()
        var CancelResyncStateId = UUID()
        var CancelStateId = UUID()
        var CancelTransactionsStateId = UUID()
        var CancelBatteryStateId = UUID()
        var SynchronizerCancelId = UUID()
        var WalletConfigCancelId = UUID()
        var DidFinishLaunchingId = UUID()
        var CancelFlexaId = UUID()
        var shieldingProcessorCancelId = UUID()

        @Shared(.inMemory(.addressBookContacts)) var addressBookContacts: AddressBookContacts = .empty
        @Presents var alert: AlertState<Action>?
        var appInitializationState: InitializationState = .uninitialized
        var appStartState: AppStartState = .unknown
        var areMetadataPreserved = true
        var bgTask: BGProcessingTask?
        @Presents var confirmationDialog: ConfirmationDialogState<Action.ConfirmationDialog>?
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion? = nil
        var debugState: DebugState
        var deeplinkWarningState: DeeplinkWarning.State = .initial
        var destinationState: DestinationState
        var exportLogsState: ExportLogs.State
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        var homeState: Home.State = .initial
        var isLockedInKeychainUnavailableState = false
        var isRestoringWallet = false
        @Shared(.appStorage(.lastAuthenticationTimestamp)) var lastAuthenticationTimestamp: Int = 0
        var maxResetZashiAppAttempts = ResetZashiConstants.maxResetZashiAppAttempts
        var maxResetZashiSDKAttempts = ResetZashiConstants.maxResetZashiSDKAttempts
        var messageToBeShared = ""
        var messageShareBinding: String?
        var notEnoughFreeSpaceState: NotEnoughFreeSpace.State
        var onboardingState: RestoreWalletCoordFlow.State
        var osStatusErrorState: OSStatusError.State
        var path: Path? = nil
        var phraseDisplayState: RecoveryPhraseDisplay.State
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var serverSetupState: ServerSetup.State
        var serverSetupViewBinding = false
        var signWithKeystoneCoordFlowBinding = false
        var splashAppeared = false
        var supportData: SupportData?
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        @Shared(.inMemory(.transactionMemos)) var transactionMemos: [String: [String]] = [:]
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        var walletConfig: WalletConfig
        @Shared(.inMemory(.walletStatus)) var walletStatus: WalletStatus = .none
        var wasRestoringWhenDisconnected = false
        var welcomeState: Welcome.State
        @Shared(.inMemory(.zashiWalletAccount)) var zashiWalletAccount: WalletAccount? = nil

        // Auto-update swaps
        var autoUpdateCandidate: TransactionState? = nil
        var autoUpdateLatestAttemptedTimestamp: TimeInterval = 0
        var autoUpdateRefreshScheduled = false
        var autoUpdateSwapCandidates: IdentifiedArrayOf<TransactionState> = []
        @Shared(.inMemory(.swapAssets)) var swapAssets: IdentifiedArrayOf<SwapAsset> = []

        var addKeystoneHWWalletCoordFlowState = AddKeystoneHWWalletCoordFlow.State.initial
        var currencyConversionSetupState = CurrencyConversionSetup.State.initial
        var receiveState = Receive.State.initial
        var requestZecCoordFlowState = RequestZecCoordFlow.State.initial
        var scanCoordFlowState = ScanCoordFlow.State.initial
        var sendCoordFlowState = SendCoordFlow.State.initial
        var settingsState = Settings.State.initial
        var signWithKeystoneCoordFlowState = SignWithKeystoneCoordFlow.State.initial
        var swapAndPayCoordFlowState = SwapAndPayCoordFlow.State.initial
        var transactionsCoordFlowState = TransactionsCoordFlow.State.initial
        var walletBackupCoordFlowState = WalletBackupCoordFlow.State.initial
        var torSetupState = TorSetup.State.initial

        init(
            appInitializationState: InitializationState = .uninitialized,
            appStartState: AppStartState = .unknown,
            debugState: DebugState,
            destinationState: DestinationState,
            exportLogsState: ExportLogs.State,
            isLockedInKeychainUnavailableState: Bool = false,
            isRestoringWallet: Bool = false,
            notEnoughFreeSpaceState: NotEnoughFreeSpace.State = .initial,
            onboardingState: RestoreWalletCoordFlow.State,
            osStatusErrorState: OSStatusError.State = .initial,
            phraseDisplayState: RecoveryPhraseDisplay.State,
            serverSetupState: ServerSetup.State = .initial,
            walletConfig: WalletConfig,
            welcomeState: Welcome.State
        ) {
            self.appInitializationState = appInitializationState
            self.appStartState = appStartState
            self.debugState = debugState
            self.destinationState = destinationState
            self.exportLogsState = exportLogsState
            self.isLockedInKeychainUnavailableState = isLockedInKeychainUnavailableState
            self.isRestoringWallet = isRestoringWallet
            self.onboardingState = onboardingState
            self.osStatusErrorState = osStatusErrorState
            self.notEnoughFreeSpaceState = notEnoughFreeSpaceState
            self.phraseDisplayState = phraseDisplayState
            self.serverSetupState = serverSetupState
            self.walletConfig = walletConfig
            self.welcomeState = welcomeState
        }
    }

    enum Action: BindableAction {
        enum ConfirmationDialog: Equatable {
            case fullRescan
            case quickRescan
        }

        case alert(PresentationAction<Action>)
        case batteryStateChanged
        case binding(BindingAction<Root.State>)
        case cancelAllRunningEffects
        case confirmationDialog(PresentationAction<ConfirmationDialog>)
        case debug(DebugAction)
        case deeplinkWarning(DeeplinkWarning.Action)
        case destination(DestinationAction)
        case exportLogs(ExportLogs.Action)
        case flexaOnTransactionRequest(FlexaTransaction?)
        case flexaOpenRequest
        case flexaTransactionFailed(String)
        case home(Home.Action)
        case initialization(InitializationAction)
        case notEnoughFreeSpace(NotEnoughFreeSpace.Action)
        case resetZashiFinishProcessing
        case resetZashiKeychainFailed(OSStatus)
        case resetZashiKeychainFailedWithCorruptedData(String)
        case resetZashiKeychainRequest
        case resetZashiSDKFailed
        case resetZashiSDKSucceeded
        case onboarding(RestoreWalletCoordFlow.Action)
        case osStatusError(OSStatusError.Action)
        case phraseDisplay(RecoveryPhraseDisplay.Action)
        case serverSetup(ServerSetup.Action)
        case serverSetupBindingUpdated(Bool)
        case splashFinished
        case splashRemovalRequested
        case synchronizerStateChanged(RedactableSynchronizerState)
        case transactionDetailsOpen(String)
        case updateStateAfterConfigUpdate(WalletConfig)
        case walletConfigLoaded(WalletConfig)
        case welcome(Welcome.Action)

        case addKeystoneHWWalletCoordFlow(AddKeystoneHWWalletCoordFlow.Action)
        case currencyConversionSetup(CurrencyConversionSetup.Action)
        case receive(Receive.Action)
        case requestZecCoordFlow(RequestZecCoordFlow.Action)
        case scanCoordFlow(ScanCoordFlow.Action)
        case sendAgainRequested(TransactionState)
        case sendCoordFlow(SendCoordFlow.Action)
        case settings(Settings.Action)
        case signWithKeystoneCoordFlow(SignWithKeystoneCoordFlow.Action)
        case signWithKeystoneRequested
        case swapAndPayCoordFlow(SwapAndPayCoordFlow.Action)
        case transactionsCoordFlow(TransactionsCoordFlow.Action)
        case walletBackupCoordFlow(WalletBackupCoordFlow.Action)
        case torSetup(TorSetup.Action)
        case backToHomeFromServerSwitchTapped

        // Transactions
        case observeTransactions
        case foundTransactions([ZcashTransaction.Overview])
        case minedTransaction(ZcashTransaction.Overview)
        case fetchTransactionsForTheSelectedAccount
        case fetchedTransactions(IdentifiedArrayOf<TransactionState>)
        case noChangeInTransactions
        
        // Address Book
        case loadContacts
        case contactsLoaded(AddressBookContacts)
        
        // UserMetadata
        case loadUserMetadata
        case resolveMetadataEncryptionKeys
        
        // Shielding
        case observeShieldingProcessor
        case reportShieldingFailure
        case shareFinished
        case shieldingProcessorStateChanged(ShieldingProcessorClient.State)

        // Tor
        case observeTorInit
        case torInitFailed
        case torDisableTapped
        case torDontDisableTapped

        // Swap API Acccess
        case loadSwapAPIAccess
        
        // Auto-update Swaps
        case attemptToCheckSwapStatus(Bool)
        case autoUpdateCandidatesSwapDetails(SwapDetails)
        case compareAndUpdateMetadataOfSwap(SwapDetails)
        
        // Check funds
        case checkFundsFailed(String)
        case checkFundsFoundSomething
        case checkFundsNothingFound
        case checkFundsTorRequired
        
        // Resync
        case rewindDone(ZcashError?)
    }

    @Dependency(\.addressBook) var addressBook
    @Dependency(\.audioServices) var audioServices
    @Dependency(\.autolockHandler) var autolockHandler
    @Dependency(\.databaseFiles) var databaseFiles
    @Dependency(\.deeplink) var deeplink
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.diskSpaceChecker) var diskSpaceChecker
    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.flexaHandler) var flexaHandler
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.shieldingProcessor) var shieldingProcessor
    @Dependency(\.swapAndPay) var swapAndPay
    @Dependency(\.uriParser) var uriParser
    @Dependency(\.userDefaults) var userDefaults
    @Dependency(\.userMetadataProvider) var userMetadataProvider
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletConfigProvider) var walletConfigProvider
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.readTransactionsStorage) var readTransactionsStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }
    
    @ReducerBuilder<State, Action>
    var core: some Reducer<State, Action> {
        BindingReducer()
        
        Scope(state: \.deeplinkWarningState, action: \.deeplinkWarning) {
            DeeplinkWarning()
        }

        Scope(state: \.serverSetupState, action: \.serverSetup) {
            ServerSetup()
        }

        Scope(state: \.homeState, action: \.home) {
            Home()
        }

        Scope(state: \.exportLogsState, action: \.exportLogs) {
            ExportLogs()
        }

        Scope(state: \.notEnoughFreeSpaceState, action: \.notEnoughFreeSpace) {
            NotEnoughFreeSpace()
        }

        Scope(state: \.onboardingState, action: \.onboarding) {
            RestoreWalletCoordFlow()
        }

        Scope(state: \.welcomeState, action: \.welcome) {
            Welcome()
        }

        Scope(state: \.phraseDisplayState, action: \.phraseDisplay) {
            RecoveryPhraseDisplay()
        }

        Scope(state: \.osStatusErrorState, action: \.osStatusError) {
            OSStatusError()
        }

        Scope(state: \.settingsState, action: \.settings) {
            Settings()
        }

        Scope(state: \.receiveState, action: \.receive) {
            Receive()
        }
        
        Scope(state: \.requestZecCoordFlowState, action: \.requestZecCoordFlow) {
            RequestZecCoordFlow()
        }
        
        Scope(state: \.sendCoordFlowState, action: \.sendCoordFlow) {
            SendCoordFlow()
        }
        
        Scope(state: \.scanCoordFlowState, action: \.scanCoordFlow) {
            ScanCoordFlow()
        }
        
        Scope(state: \.addKeystoneHWWalletCoordFlowState, action: \.addKeystoneHWWalletCoordFlow) {
            AddKeystoneHWWalletCoordFlow()
        }

        Scope(state: \.transactionsCoordFlowState, action: \.transactionsCoordFlow) {
            TransactionsCoordFlow()
        }
        
        Scope(state: \.walletBackupCoordFlowState, action: \.walletBackupCoordFlow) {
            WalletBackupCoordFlow()
        }

        Scope(state: \.currencyConversionSetupState, action: \.currencyConversionSetup) {
            CurrencyConversionSetup()
        }

        Scope(state: \.signWithKeystoneCoordFlowState, action: \.signWithKeystoneCoordFlow) {
            SignWithKeystoneCoordFlow()
        }

        Scope(state: \.torSetupState, action: \.torSetup) {
            TorSetup()
        }

        Scope(state: \.swapAndPayCoordFlowState, action: \.swapAndPayCoordFlow) {
            SwapAndPayCoordFlow()
        }

        initializationReduce()

        destinationReduce()
        
        debugReduce()
        
        transactionsReduce()
        
        addressBookReduce()
        
        userMetadataReduce()

        coordinatorReduce()
        
        shieldingProcessorReduce()
        
        torInitCheckReduce()
        
        swapsReduce()
        
        checkFundsReduce()
    }
    
    var body: some Reducer<State, Action> {
        self.core

        Reduce { state, action in
            switch action {
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .serverSetup:
                return .none
                
            case .serverSetupBindingUpdated(let newValue):
                state.serverSetupViewBinding = newValue
                return .none
                
            case .batteryStateChanged:
                let leavesScreenOpen = userDefaults.objectForKey(Constants.udLeavesScreenOpen) as? Bool ?? false
                let autolockShouldBeEnabled = state.walletStatus.isNotReadyForFullySyncedOperation && leavesScreenOpen
                return .run { _ in await autolockHandler.value(autolockShouldBeEnabled) }

            case .cancelAllRunningEffects:
                return .concatenate(
                    .cancel(id: state.CancelId),
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelTransactionsStateId),
                    .cancel(id: state.CancelBatteryStateId),
                    .cancel(id: state.SynchronizerCancelId),
                    .cancel(id: state.WalletConfigCancelId),
                    .cancel(id: state.DidFinishLaunchingId)
                )

            case .onboarding(.newWalletSuccessfulyCreated):
                return .send(.initialization(.initializeSDK(.newWallet)))

            default: return .none
            }
        }
    }
}

extension Root {
    static func walletInitializationState(
        databaseFiles: DatabaseFilesClient,
        walletStorage: WalletStorageClient,
        zcashNetwork: ZcashNetwork
    ) -> InitializationState {
        var keysPresent = false
        do {
            keysPresent = try walletStorage.areKeysPresent()
            let databaseFilesPresent = databaseFiles.areDbFilesPresentFor(zcashNetwork)
            
            switch (keysPresent, databaseFilesPresent) {
            case (false, false):
                return .uninitialized
            case (false, true):
                return .keysMissing
            case (true, false):
                return .filesMissing
            case (true, true):
                return .initialized
            }
        } catch WalletStorage.WalletStorageError.uninitializedWallet {
            if databaseFiles.areDbFilesPresentFor(zcashNetwork) {
                return .keysMissing
            }
        } catch WalletStorage.KeychainError.unknown(let osStatus) {
            return .osStatus(osStatus)
        } catch {
            return .failed
        }
        
        return .uninitialized
    }
}

// MARK: Alerts

extension AlertState where Action == Root.Action {
    static func cantLoadSeedPhrase() -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertFailedTitle))
        } message: {
            TextState(String(localizable: .rootInitializationAlertCantLoadSeedPhraseMessage))
        }
    }
    
    static func cantStartSync(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootDebugAlertRewindCantStartSyncTitle))
        } message: {
            TextState(String(localizable: .rootDebugAlertRewindCantStartSyncMessage(error.detailedMessage)))
        }
    }
    
    static func cantStoreThatUserPassedPhraseBackupTest(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertFailedTitle))
        } message: {
            TextState(
                String(localizable: .rootInitializationAlertCantStoreThatUserPassedPhraseBackupTestMessage(error.detailedMessage))
            )
        }
    }
    
    static func failedToProcessDeeplink(_ url: URL, _ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootDestinationAlertFailedToProcessDeeplinkTitle))
        } message: {
            TextState(String(localizable: .rootDestinationAlertFailedToProcessDeeplinkMessage("\(url)", error.message, "\(error.code.rawValue)")))
        }
    }
    
    static func initializationFailed(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertSdkInitFailedTitle))
        } message: {
            TextState(String(localizable: .rootInitializationAlertErrorMessage(error.detailedMessage)))
        }
    }
    
    static func rewindFailed(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootDebugAlertRewindFailedTitle))
        } message: {
            TextState(String(localizable: .rootDebugAlertRewindFailedMessage(error.detailedMessage)))
        }
    }
    
    static func walletStateFailed(_ walletState: InitializationState) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertFailedTitle))
        } actions: {
            ButtonState(role: .destructive, action: .initialization(.resetZashi)) {
                TextState(String(localizable: .settingsDeleteZashi))
            }
            ButtonState(role: .cancel, action: .alert(.dismiss)) {
                TextState(String(localizable: .generalOk))
            }
        } message: {
            TextState(String(localizable: .rootInitializationAlertWalletStateFailedMessage(String(describing: walletState))))
        }
    }
    
    static func wipeFailed(_ osStatus: OSStatus) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertWipeFailedTitle))
        } message: {
            TextState("OSStatus: \(osStatus), \(String(localizable: .rootInitializationAlertWipeFailedMessage))")
        }
    }
    
    static func wipeKeychainFailed(_ errMsg: String) -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertWipeFailedTitle))
        } message: {
            TextState("Keychain failed: \(errMsg)")
        }
    }
    
    static func wipeRequest() -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertWipeTitle))
        } actions: {
            ButtonState(role: .destructive, action: .initialization(.resetZashi)) {
                TextState(String(localizable: .generalYes))
            }
            ButtonState(role: .cancel, action: .initialization(.resetZashiRequestCanceled)) {
                TextState(String(localizable: .generalNo))
            }
        } message: {
            TextState(String(localizable: .rootInitializationAlertWipeMessage))
        }
    }

    static func differentSeed() -> AlertState {
        AlertState {
            TextState(String(localizable: .generalAlertWarning))
        } actions: {
            ButtonState(role: .cancel, action: .alert(.dismiss)) {
                TextState(String(localizable: .rootSeedPhraseDifferentSeedTryAgain))
            }
            ButtonState(role: .destructive, action: .initialization(.resetZashi)) {
                TextState(String(localizable: .generalAlertContinue))
            }
        } message: {
            TextState(String(localizable: .rootSeedPhraseDifferentSeedMessage))
        }
    }
    
    static func existingWallet() -> AlertState {
        AlertState {
            TextState(String(localizable: .generalAlertWarning))
        } actions: {
            ButtonState(role: .cancel, action: .initialization(.restoreExistingWallet)) {
                TextState(String(localizable: .rootExistingWalletRestore))
            }
            ButtonState(role: .destructive, action: .initialization(.resetZashi)) {
                TextState(String(localizable: .generalAlertContinue))
            }
        } message: {
            TextState(String(localizable: .rootExistingWalletMessage))
        }
    }
    
    static func serviceUnavailable() -> AlertState {
        AlertState {
            TextState(String(localizable: .generalAlertCaution))
        } actions: {
            ButtonState(action: .alert(.dismiss)) {
                TextState(String(localizable: .generalAlertIgnore))
            }
            ButtonState(action: .destination(.serverSwitch)) {
                TextState(String(localizable: .rootServiceUnavailableSwitchServer))
            }
        } message: {
            TextState(String(localizable: .rootServiceUnavailableMessage))
        }
    }
    
    static func shieldFundsFailure(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .shieldFundsErrorTitle))
        } actions: {
            ButtonState(action: .alert(.dismiss)) {
                TextState(String(localizable: .generalOk))
            }
            ButtonState(action: .reportShieldingFailure) {
                TextState(String(localizable: .sendReport))
            }
        } message: {
            TextState(String(localizable: .shieldFundsErrorFailureMessage(error.detailedMessage)))
        }
    }
    
    static func shieldFundsGrpc() -> AlertState {
        AlertState {
            TextState(String(localizable: .shieldFundsErrorTitle))
        } message: {
            TextState(String(localizable: .shieldFundsErrorGprcMessage))
        }
    }
    
    static func torInitFailedRequest() -> AlertState {
        AlertState {
            TextState(String(localizable: .torSetupAlertTitle))
        } actions: {
            ButtonState(action: .torDisableTapped) {
                TextState(String(localizable: .torSetupAlertDisable))
            }
            ButtonState(action: .torDontDisableTapped) {
                TextState(String(localizable: .torSetupAlertDontDisable))
            }
        } message: {
            TextState(String(localizable: .torSetupAlertMsg))
        }
    }
}
     
extension ConfirmationDialogState where Action == Root.Action.ConfirmationDialog {
    static func rescanRequest() -> ConfirmationDialogState {
        ConfirmationDialogState {
            TextState(String(localizable: .rootDebugDialogRescanTitle))
        } actions: {
            ButtonState(role: .destructive, action: .quickRescan) {
                TextState(String(localizable: .rootDebugDialogRescanOptionQuick))
            }
            ButtonState(role: .destructive, action: .fullRescan) {
                TextState(String(localizable: .rootDebugDialogRescanOptionFull))
            }
            ButtonState(role: .cancel) {
                TextState(String(localizable: .generalCancel))
            }
        } message: {
            TextState(String(localizable: .rootDebugDialogRescanMessage))
        }
    }

}
