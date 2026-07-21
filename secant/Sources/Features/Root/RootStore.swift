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
            case migrationCoordFlow
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

        struct PendingServerCandidate {
            let endpoint: LightWalletEndpoint
            let benchmarkedAt: Date

            func isExpired(now: Date) -> Bool {
                now.timeIntervalSince(benchmarkedAt) >= AutoServerSelectionConstants.pendingCandidateTTL
            }
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
        var automaticServerRefreshCancelId = UUID()
        /// MOB-1496 (W2): the migration gate-flip reconcile trigger's own subscription
        /// (`sdkSynchronizer.migrationSyncBlockedStream()`), started together with `CancelStateId`'s
        /// `stateStream()` subscription in `.registerForSynchronizersUpdate` (both `.merge`d from
        /// the same action) — but not stopped alongside it. This id relies solely on its own
        /// `cancelInFlight: true` to supersede the previous subscription when
        /// `.registerForSynchronizersUpdate` re-runs; unlike `CancelStateId`, it has no explicit
        /// `.cancel(id:)` teardown anywhere (e.g. on background entry, only
        /// `CancelStateId`/`CancelTransactionsStateId` are cancelled explicitly).
        var migrationSyncGateCancelId = UUID()
        /// MOB-1496 (R8-T4, #11): the migration BG session tree's own cancel id — separate from
        /// `bgTask`'s implicit lifetime, since the tree's `MigrationBGSessionHandle` is tracked via
        /// `activeMigrationBackgroundSessionHandle` below, not `bgTask` (which stays reserved for the
        /// plain sync BG task and the sync-only hand-off, per `MigrationBGSessionHandle`'s doc).
        var migrationBackgroundSessionCancelId = UUID()

        @Shared(.inMemory(.addressBookContacts)) var addressBookContacts: AddressBookContacts = .empty
        @Presents var alert: AlertState<Action>?
        var appInitializationState: InitializationState = .uninitialized
        var appStartState: AppStartState = .unknown
        var areMetadataPreserved = true
        var bgTask: BGProcessingTask?
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion? = nil
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
        /// Set by `.migrationNotificationTapped` when it arrives before the app has reached Home
        /// (`appInitializationState != .initialized`) — mirrors `RootDestination`'s
        /// `isAtDeeplinkWarningScreen` gating: the routing itself is deferred rather than dropped,
        /// and fires from `checkBackupPhraseValidation`'s existing "did we just reach Home"
        /// checkpoint once initialization completes. Cleared immediately after firing.
        var pendingMigrationDeepLink = false
        /// R8-T5 (S4): the ACCOUNT a stashed `.migrationNotificationTapped` tap carried (`nil` for a
        /// legacy/no-account payload) — paired with `pendingMigrationDeepLink` above so the deferred
        /// replay from `checkBackupPhraseValidation` can switch accounts exactly like the immediate-
        /// routing path does. Only meaningful while `pendingMigrationDeepLink` is `true`; cleared
        /// alongside it.
        var pendingMigrationDeepLinkAccountUUID: String? = nil
        /// MOB-1496 (R8-T4, #7): set by `.migrationBackgroundSession` when it arrives before the app
        /// has reached Home (`appInitializationState != .initialized`) — a cold launch racing this
        /// dispatch would otherwise evaluate `migrationBackgroundSessionEffect`'s early-return checks
        /// (`isIronwoodActivated()`, `walletAccounts`) against unhydrated state and misread them as
        /// "nothing to do," consuming the BG request without re-arming. Mirrors
        /// `pendingMigrationDeepLink` exactly: replayed from the SAME `checkBackupPhraseValidation`
        /// checkpoint once initialization completes, then cleared.
        var pendingMigrationBackgroundSession: MigrationBGSessionHandle?
        /// MOB-1496 (R8-T4, #11): the migration BG session tree's own handle, stored for the duration
        /// of that tree's `.cancellable(id: migrationBackgroundSessionCancelId)` effect so
        /// `.migrationBackgroundTaskExpired` can complete it directly — `bgTask` stays `nil` for this
        /// plan (only the sync-only hand-off populates it; see `MigrationBGSessionHandle`'s doc).
        /// Cleared by whichever of normal completion (`.migrationBackgroundSessionCompleted`) or
        /// expiration reaches it first — the other then finds `nil` and no-ops, so the two completion
        /// paths can never double-complete the same `BGProcessingTask`.
        var activeMigrationBackgroundSessionHandle: MigrationBGSessionHandle?
        var pendingServerCandidate: PendingServerCandidate?
        var phraseDisplayState: RecoveryPhraseDisplay.State
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var serverSetupState: ServerSetup.State
        var serverSetupViewBinding = false
        /// MOB-1497 (T6): the "Couldn't Connect to Tor" sheet, presented over Home on the next
        /// foreground after a BACKGROUND migration broadcast failed on a Tor-class route (the
        /// per-account `migrationManager.isPendingBackgroundTorPrompt` latch armed by
        /// `RootInitialization.executeBroadcastAction`). Hosted as a `zashiSheet` in `RootView`,
        /// mirroring the `serverSetupViewBinding` cover.
        var isTorFailurePromptPresented = false
        var torFailurePromptState = MigrationTorFailureSheet.State()
        /// MOB-1497 (T6): non-persisted once-per-foreground latch — set when the prompt is offered on
        /// a foreground, reset on background entry (see `RootInitialization`'s `.willEnterForeground`/
        /// `.didEnterBackground` hooks). Keeps a swipe-dismissed prompt from re-appearing until the
        /// next foreground; a FAILED in-sheet retry deliberately bypasses it (re-presents at once).
        var didOfferTorFailurePromptThisForeground = false
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
        /// MOB-1496 (W2): tracks whether the last-observed `synchronizerStateChanged` tick was
        /// `.upToDate`, so the sync-completion migration-reconcile trigger can detect the EDGE (a
        /// fresh transition into up-to-date) instead of firing on every tick while already synced.
        var wasSyncUpToDateForMigration = false
        /// MOB-1496 (W2): last-pushed `sdkSynchronizer.isMigrationSyncBlocked()` value, compared
        /// against each `migrationSyncGateChanged` tick so the gate-flip migration-reconcile
        /// trigger only fires on an actual change.
        var lastMigrationSyncGateBlocked = false
        /// MOB-1496 (W3): set when `.retryStart` finds `sdkSynchronizer.isMigrationSyncBlocked()`
        /// true (proactively, before calling `start`) or catches `ZcashError.migrationSyncBlocked`
        /// (reactively, from a start that raced the gate) — both silent, no alert. Cleared by the
        /// `.migrationSyncGateChanged(false)` handler, which then replays `.retryStart` so the
        /// normal start chain resumes identically to an ungated launch.
        var syncDeferredByMigrationGate = false
        var welcomeState: Welcome.State
        @Shared(.inMemory(.zashiWalletAccount)) var zashiWalletAccount: WalletAccount? = nil

        // Auto-update swaps
        var autoUpdateCandidate: TransactionState? = nil
        var autoUpdateLatestAttemptedTimestamp: TimeInterval = 0
        var autoUpdateRefreshScheduled = false
        var autoUpdateSwapCandidates: IdentifiedArrayOf<TransactionState> = []
        // Full catalog (MOB-1472) — resolves historical/exotic swap assets when
        // enriching swap metadata in the background; not the curated offering.
        @Shared(.inMemory(.swapAssetsCatalog)) var swapAssets: IdentifiedArrayOf<SwapAsset> = []

        var addKeystoneHWWalletCoordFlowState = AddKeystoneHWWalletCoordFlow.State.initial
        var currencyConversionSetupState = CurrencyConversionSetup.State.initial
        var migrationCoordFlowState = MigrationCoordFlow.State.initial
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

        /// True while Server Setup is presented via any of its three entry points — the
        /// disconnect-alert full-screen cover (`serverSetupViewBinding`), the smart-banner
        /// navigation (`path == .serverSwitch`), or Settings → Choose Server (`chooseServerSetup`).
        var isServerSetupVisible: Bool {
            serverSetupViewBinding
                || path == .serverSwitch
                || settingsState.path.contains { if case .chooseServerSetup = $0 { return true } else { return false } }
        }

        /// True while the user is inside a UI flow that may contain an in-progress payment
        /// or voting sequence. Read live at decision time — never stored anywhere. The
        /// switch is exhaustive on purpose: a new `Path` case must be classified here
        /// before the project compiles.
        var isSensitiveFlowActive: Bool {
            if signWithKeystoneCoordFlowBinding { return true }
            guard let path else { return false }
            switch path {
            // The voting flow has no `Path` case of its own — it is presented from inside Settings
            // (`SettingsStore`'s `@Presents var votingCoordFlow`), so `path` stays `.settings` for its
            // whole duration. Its broadcasts (submitVoteCommitment / submitDelegation / delegateShares /
            // getTreeState) must not be interrupted by an automatic server switch, so `.settings` is
            // classified sensitive to cover them. Do NOT declassify `.settings` while voting lives under
            // it; if voting ever gets its own `Path` case, move the sensitivity there.
            case .settings:
                return true
            case .migrationCoordFlow, .sendCoordFlow, .scanCoordFlow, .swapAndPayCoordFlow, .transactionsCoordFlow:
                return true
            case .addKeystoneHWWalletCoordFlow, .currencyConversionSetup, .receive,
                 .requestZecCoordFlow, .serverSwitch, .torSetup, .walletBackup:
                return false
            }
        }

        /// Gate for applying an automatic server switch.
        var canApplyAutoServerSwitch: Bool {
            bgTask == nil && !isServerSetupVisible && !isSensitiveFlowActive
        }

        init(
            appInitializationState: InitializationState = .uninitialized,
            appStartState: AppStartState = .unknown,
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
        case alert(PresentationAction<Action>)
        case batteryStateChanged
        case binding(BindingAction<Root.State>)
        case cancelAllRunningEffects
        case deeplinkWarning(DeeplinkWarning.Action)
        case destination(DestinationAction)
        case exportLogs(ExportLogs.Action)
        case flexaOnTransactionRequest(FlexaTransaction?)
        case flexaOpenRequest
        case flexaTransactionFailed(String)
        case home(Home.Action)
        case initialization(InitializationAction)
        /// MOB-1496 (W2): `sdkSynchronizer.migrationSyncBlockedStream()` ticked (paired with an
        /// initial `isMigrationSyncBlocked()` read — see `.registerForSynchronizersUpdate`) — a
        /// genuine change from `state.lastMigrationSyncGateBlocked` reconciles migration state.
        case migrationSyncGateChanged(Bool)
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
        case migrationCoordFlow(MigrationCoordFlow.Action)
        /// MOB-1497 (T6): foreground gate check — dispatched from `.willEnterForeground` — that
        /// presents the "Couldn't Connect to Tor" sheet iff Home is fully visible and the selected
        /// account's background Tor-failure latch is armed.
        case checkMigrationTorFailurePrompt
        case torFailurePrompt(MigrationTorFailureSheet.Action)
        /// MOB-1497 (T6): the sheet's presentation binding setter — `false` on swipe-dismiss (latch
        /// stays armed), `true` when a failed in-sheet retry re-presents.
        case torFailurePromptPresentationChanged(Bool)
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
        case refreshAutomaticServer
        case autoServerCandidateReady(LightWalletEndpoint)

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
    @Dependency(\.date) var date
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.diskSpaceChecker) var diskSpaceChecker
    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.flexaHandler) var flexaHandler
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.shieldingProcessor) var shieldingProcessor
    @Dependency(\.swapAndPay) var swapAndPay
    @Dependency(\.autoServerSelection) var autoServerSelection
    @Dependency(\.uriParser) var uriParser
    @Dependency(\.userDefaults) var userDefaults
    @Dependency(\.userMetadataProvider) var userMetadataProvider
    @Dependency(\.userNotifications) var userNotifications
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.votingMetadata) var votingMetadata
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

        Scope(state: \.migrationCoordFlowState, action: \.migrationCoordFlow) {
            MigrationCoordFlow()
        }

        Scope(state: \.torFailurePromptState, action: \.torFailurePrompt) {
            MigrationTorFailureSheet()
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

        transactionsReduce()
        
        addressBookReduce()
        
        userMetadataReduce()

        coordinatorReduce()
        
        shieldingProcessorReduce()
        
        torInitCheckReduce()
        
        swapsReduce()
        
        checkFundsReduce()
    }
    
    /// The `onChange` wrapper must observe every reducer that can mutate an input of
    /// `canApplyAutoServerSwitch` (path, bindings, bgTask, settings path) — keep ALL
    /// composed reducers inside `combinedCore`; never add a sibling reducer here in `body`.
    var body: some Reducer<State, Action> {
        combinedCore
            .onChange(of: \.canApplyAutoServerSwitch) { _, state in
                guard state.canApplyAutoServerSwitch, let pending = state.pendingServerCandidate else { return .none }
                state.pendingServerCandidate = nil
                if pending.isExpired(now: date.now()) {
                    LoggerProxy.event("[AutoServerSelection] Deferred candidate expired, dropped")
                    return .none
                }
                LoggerProxy.event("[AutoServerSelection] Applying deferred candidate after flow exit")
                return .send(.autoServerCandidateReady(pending.endpoint))
            }
    }

    @ReducerBuilder<State, Action>
    private var combinedCore: some Reducer<State, Action> {
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

            case .refreshAutomaticServer:
                // Skip during a background task, and while the user is on the Server Setup
                // screen (a manual Save owns that window). The benchmark itself still runs
                // while a sensitive flow is on screen — it is read-only, and a candidate
                // should be ready to apply the moment the user leaves the flow; the apply
                // decision is gated in .autoServerCandidateReady. Correctness against a
                // concurrent manual switch is guaranteed by TransactionGuard regardless:
                // the manual Save uses switchWaiting (waits, then wins) while applySwitch
                // uses switchIfIdle (skips if busy).
                guard state.bgTask == nil, !state.isServerSetupVisible else { return .none }
                return .run { send in
                    if let best = await autoServerSelection.findBestServer() {
                        await send(.autoServerCandidateReady(best))
                    }
                }
                .cancellable(id: state.automaticServerRefreshCancelId, cancelInFlight: true)

            case .autoServerCandidateReady(let candidate):
                guard state.canApplyAutoServerSwitch else {
                    state.pendingServerCandidate = State.PendingServerCandidate(
                        endpoint: candidate,
                        benchmarkedAt: date.now()
                    )
                    let hardGates = "bgTask: \(state.bgTask != nil), serverSetup: \(state.isServerSetupVisible)"
                    let gates = "\(hardGates), sensitiveFlow: \(state.isSensitiveFlowActive)"
                    LoggerProxy.event("[AutoServerSelection] Candidate deferred (\(gates))")
                    return .none
                }
                state.pendingServerCandidate = nil
                return .run { _ in
                    _ = await autoServerSelection.applySwitch(candidate)
                }

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
