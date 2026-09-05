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
        /// MOB-1853: the `.syncStalled` event channel's own cancel id -- a dedicated `.publisher`
        /// branch in the same `.observeTransactions` `.merge`, kept separate from `CancelEventId`'s
        /// transaction-event channel so the two can never silently drop each other's event under a
        /// shared "latest wins" throttle window (see `RootTransactions.swift`). Cancelled everywhere
        /// `CancelEventId` is cancelled at `.didEnterBackground`.
        var CancelSyncStalledEventId = UUID()
        var CancelId = UUID()
        var CancelResyncStateId = UUID()
        var CancelStateId = UUID()
        var CancelTransactionsStateId = UUID()
        /// The `.fetchTransactionsForTheSelectedAccount` fetch effect's own cancel id. An account
        /// switch (`RootCoordinator.swift`'s `accountSwitchedEffect`) explicitly `.cancel`s this id
        /// before sending a fresh fetch for the newly-selected account, so a fetch still running for
        /// the account just left can't land after the switch. This id is deliberately NOT combined
        /// with `cancelInFlight` on the fetch effect itself: during a sync,
        /// `sdkSynchronizer.eventStream()` is throttled to one event per 0.2s and every
        /// `foundTransactions`/`minedTransaction` re-dispatches the same action, so on a wallet
        /// where `getAllTransactions` takes longer than that 0.2s interval, `cancelInFlight` would
        /// cancel every one of those fetches before any could complete, starving
        /// `.fetchedTransactions` for the whole sync. The `.fetchedTransactions` provenance guard is
        /// what actually keeps a stale or wrong-account payload from corrupting `state.transactions`.
        var CancelTransactionsFetchId = UUID()
        var CancelPendingTxPollId = UUID()
        var CancelBatteryStateId = UUID()
        var SynchronizerCancelId = UUID()
        var WalletConfigCancelId = UUID()
        var DidFinishLaunchingId = UUID()
        var CancelFlexaId = UUID()
        var shieldingProcessorCancelId = UUID()
        var automaticServerRefreshCancelId = UUID()
        var staleWalletHealedAlertCancelId = UUID()
        var migrationSyncGateCancelId = UUID()
        /// MOB-1466: the foreground migration TICK LOOP's cancel id — one recurring 30s wake-up,
        /// started/restarted at `.initializationSuccessfullyDone`/`.appDelegate(.willEnterForeground)`
        /// (`cancelInFlight: true`, so a fresh foreground always resets the countdown to zero) and
        /// cancelled at `.appDelegate(.didEnterBackground)`. See `migrationTickLoopEffect(state:)`.
        var migrationTickCancelId = UUID()
        /// MOB-1466: the blocked-edge stop's attribution-probe cancel id — cancelled on the gate's
        /// false edge, since the probe's work is moot once sync is no longer blocked. See
        /// `.migrationSyncGateChanged`'s stop half.
        var migrationGateStopProbeCancelId = UUID()
        /// Audit 2026-08-03 (#7): the one-shot delayed `.retryStart` a failed `start()` schedules —
        /// cancelled at background, re-armed (the one-shot latch below resets) each foreground.
        var startFailureRetryCancelId = UUID()
        /// MOB-1859: the background `PrivateUAStash.refill` dispatched from
        /// `.initialization(.loadedWalletAccounts)` for accounts whose rotation stash is still
        /// nil after merging in the previous in-memory accounts. A newer load's refill supersedes
        /// whichever one is still running for a now-stale accounts list.
        var privateUAStashRefillCancelId = UUID()
        /// One retry per foreground: a `start()` that keeps failing must not self-retry in a loop —
        /// the second failure waits for the next external trigger (foreground, gate emission).
        var didScheduleStartFailureRetry = false
        /// MOB-1466: how many `.migrationTick` wake-ups THIS loop instance has seen — effect-adjacent
        /// bookkeeping for the heartbeat log line (`.migrationTick`'s handler), not itself read by any
        /// decision. Deliberately never reset except by a fresh `Root.State` — an occasional
        /// heartbeat drifting relative to a JUST-restarted countdown is harmless; the log line only
        /// ever claims "the loop is alive", never a precise wall-clock cadence.
        var migrationTickCount = 0
        /// The last value `.migrationSyncGateChanged` saw, for dedupe — a genuine transition is what
        /// triggers a migration reconcile.
        var lastMigrationSyncGateBlocked = false
        /// Set when a start was refused by the migration privacy gate (`.migrationGateDeferredSyncStart`,
        /// sent from both `start()` call sites' refusal handling), so the gate's clearing edge knows to
        /// replay that deferred start. This is what makes the buffer-shape refusal — nothing due to
        /// broadcast, so `migrationStoppedSyncForBroadcast` never gets set either — resume in the SAME
        /// session instead of waiting for the next foreground.
        var syncDeferredByMigrationGate = false
        /// Edge detector for the sync-completion hooks below — reconcile and the send-gate re-key
        /// run ONCE per completed sync, not on every tick while already at the tip.
        var wasSyncUpToDateForMigration = false

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
        /// In-memory, per-session latch set once the Ironwood announcement gate has "resolved"
        /// this session — either the screen was presented, or the keychain flag was already
        /// found `true` (acknowledged on a previous session). Its purpose is twofold: it keeps
        /// the keychain read (`walletStorage.exportIronwoodAnnouncementFlag`) to at most once
        /// per session on the already-acknowledged path, and it keeps the announcement from
        /// presenting more than once per session. Deliberately NOT persisted: a user who
        /// force-quits while the announcement is on screen without tapping Continue (so the
        /// keychain flag was never written) should see it again next session, not have it
        /// suppressed by a stale "resolved" flag surviving the relaunch.
        var ironwoodAnnouncementResolved = false
        /// Single-flight latch for `.initialization(.initializeSDK)`. The SDK reports an
        /// unprepared status until `prepare` fully returns, so `willEnterForeground` (and any
        /// other re-entry into the initialization chain) would otherwise dispatch a second
        /// concurrent `prepareWith`. Initialization must never run concurrently ([#1943]):
        /// the first prepare wins and re-entries are dropped until the in-flight effect
        /// signals completion on every terminal path.
        var isInitializingSDK = false
        var isLockedInKeychainUnavailableState = false
        var isRestoringWallet = false
        /// MOB-1854: single-flight latch for `.initialization(.retryStart)` — `start()` has no
        /// cancellation points, so a re-entrant retryStart is dropped (and logged) rather than
        /// cancelling the in-flight pipeline. Reset at `.didEnterBackground` so a pipeline whose
        /// finishing `send` was dropped by cancellation can never wedge the next foreground.
        var isRetryStartInFlight = false
        var isStaleWalletHealedAlertPending = false
        /// MOB-1853: true from the stall hook's own reaction (`gaveUp || attempt >= 2`, see
        /// `Root.Action.syncStalled`'s handler) until the next `.synchronizerStateChanged` reports
        /// either `.upToDate` or `.syncing` progress past `lastKnownSyncProgress` -- i.e. the engine
        /// visibly moving again. While true, `isSynchronizerIdleForSwitch` treats a `.syncing`
        /// status as idle too, since a stalled sync has nothing left for an automatic switch to
        /// interrupt. Reset at `.didEnterBackground`, same as `lastKnownSyncStatus`.
        var isSyncStalledSinceLastProgress = false
        /// MOB-1856: single-flight coalescing latch for `.fetchTransactionsForTheSelectedAccount`.
        /// During catch-up sync this fetch is re-dispatched on every throttled synchronizer event
        /// (`.observeTransactions` -- see `RootTransactions.swift`), and on a long transaction
        /// history `getAllTransactions` can easily take longer than one throttle window, so without
        /// this latch concurrent full-history fetches piled up. While `true`, a fresh dispatch sets
        /// `isTransactionsFetchDirty` and returns immediately instead of starting another fetch; the
        /// in-flight fetch's own completion (`.fetchedTransactions`/`.transactionsFetchFailed`)
        /// clears this flag and, if dirty, sends exactly one follow-up fetch. Also reset by
        /// `accountSwitchedEffect` (`RootCoordinator.swift`), whose `.cancel` drops any pending
        /// completion for the fetch it just cancelled -- see that reset's own comment for why.
        var isTransactionsFetchInFlight = false
        /// Set by `.fetchTransactionsForTheSelectedAccount` when a dispatch arrives while
        /// `isTransactionsFetchInFlight` is already `true`. Cleared by the in-flight fetch's own
        /// completion, which folds every dispatch coalesced during its run into exactly one
        /// follow-up fetch for whichever account is selected at that point.
        var isTransactionsFetchDirty = false
        @Shared(.appStorage(.lastAuthenticationTimestamp)) var lastAuthenticationTimestamp: Int = 0
        /// The most recent `.syncing` progress value seen via `.synchronizerStateChanged`, kept
        /// solely so that handler can detect a NEW tick's progress advancing past this one and
        /// clear `isSyncStalledSinceLastProgress`. Not reset at `.didEnterBackground` -- the first
        /// `.syncing` tick after a foreground restart is compared against this stale pre-background
        /// value BEFORE it gets overwritten with the fresh one. That comparison can spuriously
        /// "clear" a stall that this session never armed, but it is harmless:
        /// `isSyncStalledSinceLastProgress` is already `false` from that same `.didEnterBackground`
        /// reset, so there is nothing left for it to (no-op) clear.
        var lastKnownSyncProgress: Float?
        /// The last sync status `.synchronizerStateChanged` reported, read by
        /// `isSynchronizerIdleForSwitch`. `nil` (nothing observed yet this session, or just reset at
        /// `.didEnterBackground`) deliberately does NOT count as idle -- an automatic switch must
        /// never run against an unknown sync state. A later task (transaction-list guards) reads
        /// this too, hence a plain optional here rather than something private to the switch gate.
        var lastKnownSyncStatus: SyncStatus?
        var maxResetZashiAppAttempts = ResetZashiConstants.maxResetZashiAppAttempts
        var maxResetZashiSDKAttempts = ResetZashiConstants.maxResetZashiSDKAttempts
        var messageToBeShared = ""
        var messageShareBinding: String?
        var notEnoughFreeSpaceState: NotEnoughFreeSpace.State
        var onboardingState: RestoreWalletCoordFlow.State
        var osStatusErrorState: OSStatusError.State
        var path: Path? = nil
        var pendingServerCandidate: PendingServerCandidate?
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
        @Shared(.inMemory(.unminedMigrationPendingValue)) var unminedMigrationPendingValue: Zatoshi = .zero
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
        // Full catalog (MOB-1472) — resolves historical/exotic swap assets when
        // enriching swap metadata in the background; not the curated offering.
        @Shared(.inMemory(.swapAssetsCatalog)) var swapAssets: IdentifiedArrayOf<SwapAsset> = []

        var addKeystoneHWWalletCoordFlowState = AddKeystoneHWWalletCoordFlow.State.initial
        var currencyConversionSetupState = CurrencyConversionSetup.State.initial
        var ironwoodAnnouncementState = IronwoodAnnouncement.State.initial
        var receiveState = Receive.State.initial
        var requestZecCoordFlowState = RequestZecCoordFlow.State.initial
        var scanCoordFlowState = ScanCoordFlow.State.initial
        var migrationCoordFlowState = MigrationCoordFlow.State.initial
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

        /// True while the user is inside a flow that can contain a payment or vote.
        /// This is computed from live navigation state so a deferred candidate is
        /// reconsidered as soon as the user leaves the flow.
        var isSensitiveFlowActive: Bool {
            if signWithKeystoneCoordFlowBinding { return true }
            guard let path else { return false }
            switch path {
            case .settings:
                // Voting is presented inside Settings and has no Root path of its own.
                return true
            case .migrationCoordFlow, .sendCoordFlow, .scanCoordFlow,
                 .swapAndPayCoordFlow, .transactionsCoordFlow:
                return true
            case .addKeystoneHWWalletCoordFlow, .currencyConversionSetup, .receive,
                 .requestZecCoordFlow, .serverSwitch, .torSetup, .walletBackup:
                return false
            }
        }

        /// True once the synchronizer has told us enough to believe an automatic switch (which
        /// tears down and rebuilds the synchronizer) will not interrupt an active sync: either the
        /// last known status carries no progress a switch could lose (`.upToDate`, `.stopped`,
        /// `.unprepared`, `.error`), or the sync has stalled since its last observed progress. `nil`
        /// -- nothing observed yet, or just cleared at `.didEnterBackground` -- is deliberately NOT
        /// idle.
        var isSynchronizerIdleForSwitch: Bool {
            if isSyncStalledSinceLastProgress { return true }
            guard let lastKnownSyncStatus else { return false }
            switch lastKnownSyncStatus {
            case .upToDate, .stopped, .unprepared, .error: return true
            case .syncing: return false
            }
        }

        /// The local-snapshot read is completed before a candidate reaches this gate. Also
        /// requires the synchronizer to be idle (`isSynchronizerIdleForSwitch`) -- a switch tears
        /// down and rebuilds the synchronizer, so it must never land while a sync is actively
        /// making progress.
        var canApplyAutoServerSwitch: Bool {
            bgTask == nil && !isServerSetupVisible && !isSensitiveFlowActive && isSynchronizerIdleForSwitch
        }

        /// Gate for taking the screen over with the one-time Ironwood announcement.
        ///
        /// `path == nil` alone already excludes every `Path` case — send, scan, swap, settings
        /// (and voting, which lives under it since it has no `Path` case of its own),
        /// transactions, receive, request-ZEC, currency conversion, Tor setup, server switch,
        /// wallet backup, and the Keystone add flow — so the remaining terms only need to cover
        /// the presentation states that are NOT `Path` cases: the Keystone signing popover, the
        /// Server Setup full-screen cover, a background task in flight, and any alert already
        /// on screen.
        ///
        /// Home's own informational sheets (e.g. the smart banner) are deliberately NOT gated
        /// here: enumerating `Home.State`'s bindings would be brittle, and the cost of losing
        /// that race is purely cosmetic — the sheet unmounts along with Home and re-presents on
        /// return, since its binding lives in `homeState`, not here — whereas every term that IS
        /// gated above protects a place where losing the race could lose in-progress user work.
        var canPresentIronwoodAnnouncement: Bool {
            destinationState.destination == .home
                && path == nil
                && !signWithKeystoneCoordFlowBinding
                && !serverSetupViewBinding
                && bgTask == nil
                && alert == nil
                && splashAppeared
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
        /// The SDK's migration privacy gate flipped (or was re-pushed by the app-side feed). The
        /// clearing edge is what RESUMES a sync a migration broadcast stopped — see the handler.
        case migrationSyncGateChanged(Bool)
        /// A `start()` was refused by the migration privacy gate — arms
        /// `State.syncDeferredByMigrationGate` so the gate's clearing edge replays the start even
        /// when no broadcast ran in between (the buffer-shape refusal). Sent from both refusal
        /// handlers in RootInitialization before they run the broadcast session.
        case migrationGateDeferredSyncStart
        /// MOB-1466: one 30s wake-up of the foreground migration tick loop — see
        /// `migrationTickLoopEffect(state:)`. Sent by the loop itself; the handler is what actually
        /// calls `migrationManager.advance(.tick)` and interprets the result.
        case migrationTick
        /// The result of the `.migrationTick` handler's `advance(.tick)` call — a second action
        /// rather than folding the decision into the `.run` effect directly, because deciding
        /// whether to self-stop the loop (`.cancel(id:)`) or nudge the smart banner (`.send(...)`)
        /// requires returning an `Effect` from the REDUCER, which a `.run` closure's body cannot do
        /// on its own partway through.
        case migrationTickAdvanced(MigrationStepVerdict)
        /// MOB-1859: the result of one account's background rotation-stash refill, dispatched
        /// from `.initialization(.loadedWalletAccounts)` for whichever accounts still had no
        /// stash after merging in the previous in-memory accounts. A Root-owned action rather
        /// than `.home(.updateNextPrivateUA(...))` — Home's handler only ever updates
        /// `state.selectedWalletAccount`, so routing a multi-account refill through it would
        /// silently discard the result for every account except whichever one happens to be
        /// selected. The handler writes through `PrivateUAStash.write`, which keeps the
        /// `walletAccounts` array (the source of truth an account switch installs as the new
        /// selection, `WalletAccountsSheet`) in sync for every account, not only the selected one.
        case privateUAStashRefilled(UnifiedAddress?, AccountUUID)
        case synchronizerStateChanged(RedactableSynchronizerState)
        case transactionDetailsOpen(String)
        case updateStateAfterConfigUpdate(WalletConfig)
        case walletConfigLoaded(WalletConfig)
        case welcome(Welcome.Action)

        case addKeystoneHWWalletCoordFlow(AddKeystoneHWWalletCoordFlow.Action)
        case currencyConversionSetup(CurrencyConversionSetup.Action)
        case ironwoodAnnouncement(IronwoodAnnouncement.Action)
        case receive(Receive.Action)
        case requestZecCoordFlow(RequestZecCoordFlow.Action)
        case scanCoordFlow(ScanCoordFlow.Action)
        case sendAgainRequested(TransactionState)
        case migrationCoordFlow(MigrationCoordFlow.Action)
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
        case autoServerCandidateReady(LightWalletEndpoint, Date)

        // Transactions
        case observeTransactions
        case foundTransactions([ZcashTransaction.Overview])
        case minedTransaction(ZcashTransaction.Overview)
        /// MOB-1853: mapped from `SynchronizerEvent.syncStalled` (see `.observeTransactions`) --
        /// sent right before each recovery restart (`attempt`, 1-based) and once more when
        /// recovery gives up. The handler always logs it; only `gaveUp || attempt >= 2` unblocks
        /// an automatic server switch, since attempt 1 is the SDK's own cheap same-server
        /// reconnect and must get its chance first.
        case syncStalled(attempt: Int, gaveUp: Bool)
        case fetchTransactionsForTheSelectedAccount
        case fetchedTransactions(AccountUUID, IdentifiedArrayOf<TransactionState>)
        /// MOB-1855: sent from `.fetchTransactionsForTheSelectedAccount`'s `catch` when
        /// `getAllTransactions` throws, carrying the account the failed fetch was for. The handler
        /// applies the same provenance guard as `.fetchedTransactions` above -- a failure for an
        /// account the user has since switched away from must change nothing, or it would clear the
        /// NEWLY selected account's `isInvalidated` flags and re-arm the poller using the PREVIOUS
        /// account's leftover `state.transactions`, marking the new account "loaded" while the old
        /// rows are still what is on screen. For the current account, the list keeps its previous
        /// contents either way, but a failed fetch must still clear any list still showing its
        /// loading placeholder and re-arm the reconciliation poller from the KEPT rows -- see
        /// `RootTransactions.swift`.
        case transactionsFetchFailed(accountUUID: AccountUUID)
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
    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.databaseFiles) var databaseFiles
    @Dependency(\.deeplink) var deeplink
    @Dependency(\.date) var date
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.diskSpaceChecker) var diskSpaceChecker
    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.flexaHandler) var flexaHandler
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.migrationTickInterval) var migrationTickInterval
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
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    #if VOTING_ENABLED
    @Dependency(\.votingMetadata) var votingMetadata
    #endif
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
        
        Scope(state: \.migrationCoordFlowState, action: \.migrationCoordFlow) {
            MigrationCoordFlow()
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

        Scope(state: \.ironwoodAnnouncementState, action: \.ironwoodAnnouncement) {
            IronwoodAnnouncement()
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
    /// `canApplyAutoServerSwitch` (path, bindings, bgTask, settings path, and — via
    /// `isSynchronizerIdleForSwitch` — `lastKnownSyncStatus` / `isSyncStalledSinceLastProgress`)
    /// — keep ALL composed reducers inside `combinedCore`; never add a sibling reducer here in `body`.
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
                return .send(.autoServerCandidateReady(pending.endpoint, pending.benchmarkedAt))
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
                // screen (a manual Save owns that window). Benchmark the servers and read the
                // durable local balances concurrently. A winner is not eligible until that read
                // completes, so the UI has a concrete snapshot before networking is rebuilt.
                guard state.bgTask == nil, !state.isServerSetupVisible else { return .none }
                return .run { send in
                    async let candidate = autoServerSelection.findBestServer()
                    async let localBalances = try? sdkSynchronizer.getLocalAccountBalances()
                    let (best, snapshot) = await (candidate, localBalances)

                    guard let best else { return }
                    guard snapshot != nil else {
                        LoggerProxy.event("[AutoServerSelection] Candidate dropped: local balance snapshot unavailable")
                        return
                    }
                    await send(.autoServerCandidateReady(best, date.now()))
                }
                .cancellable(id: state.automaticServerRefreshCancelId, cancelInFlight: true)

            case .autoServerCandidateReady(let candidate, let benchmarkedAt):
                guard state.canApplyAutoServerSwitch else {
                    state.pendingServerCandidate = State.PendingServerCandidate(
                        endpoint: candidate,
                        benchmarkedAt: benchmarkedAt
                    )
                    let hardGates = "bgTask: \(state.bgTask != nil), serverSetup: \(state.isServerSetupVisible)"
                    let gates = "\(hardGates), sensitiveFlow: \(state.isSensitiveFlowActive), idle: \(state.isSynchronizerIdleForSwitch)"
                    let status = String(describing: state.lastKnownSyncStatus)
                    LoggerProxy.event("[AutoServerSelection] Candidate deferred (\(gates), lastKnownSyncStatus: \(status))")
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
    enum WalletDatabaseHealError: Error {
        case wipeUnavailable
        case viewOnlyDatabase
        case reprepareFailed(underlying: Error)
    }

    /// After a `prepare`, verifies the opened wallet DB actually belongs to `seedBytes`.
    /// If not (stale DB from another wallet, e.g. restored device backup), clears this
    /// device's previous-wallet scoped state, wipes the SDK database, and re-prepares so
    /// the SDK creates this seed's account. Returns `true` when a heal (clear + wipe +
    /// re-prepare) happened.
    ///
    /// - Parameters:
    ///   - knownStale: `true` when the caller already knows the on-disk database predates
    ///     this seed (the SDK's `prepare()` reported `.seedNotRelevant` during a
    ///     seed-requiring migration). When `true`, the heal runs unconditionally and
    ///     neither `isSeedRelevant` nor `hasSeedDerivedAccount` is probed.
    ///   - isSeedRelevant: probes whether `seedBytes` is relevant to any derived account
    ///     already in the database. Only consulted when `knownStale` is `false`.
    ///   - hasSeedDerivedAccount: reports whether the database has at least one
    ///     seed-derived account, as opposed to being populated exclusively by
    ///     imported/view-only accounts, which cannot be recovered from any seed. Only
    ///     consulted on the probe path, once the current seed has been found irrelevant.
    ///   - clearDeviceScopedState: clears this device's previous-wallet scoped state
    ///     (voting configuration/history, Flexa session, cached preferences, …) before the
    ///     database itself is wiped.
    /// - Throws: `WalletDatabaseHealError.viewOnlyDatabase` when every account in the
    ///   database is imported/view-only; `WalletDatabaseHealError.reprepareFailed` when
    ///   `wipe()` succeeds but `reprepare()` throws (the database is already gone at that
    ///   point); any other error thrown by `isSeedRelevant`, `hasSeedDerivedAccount`, or
    ///   `wipe` is rethrown as-is.
    static func reconcileWalletDatabaseWithSeed(
        knownStale: Bool,
        seedBytes: [UInt8],
        isSeedRelevant: ([UInt8]) async throws -> Bool,
        hasSeedDerivedAccount: () async throws -> Bool,
        clearDeviceScopedState: () async -> Void,
        wipe: () async throws -> Void,
        reprepare: () async throws -> Void
    ) async throws -> Bool {
        if !knownStale {
            let seedIsRelevant = try await isSeedRelevant(seedBytes)
            guard !seedIsRelevant else { return false }

            guard try await hasSeedDerivedAccount() else {
                throw WalletDatabaseHealError.viewOnlyDatabase
            }
        }

        await clearDeviceScopedState()
        try await wipe()

        do {
            try await reprepare()
        } catch {
            throw WalletDatabaseHealError.reprepareFailed(underlying: error)
        }

        return true
    }

    /// Clears device/global-scoped wallet state that must never leak from one wallet into
    /// the next on the same device — voting configuration and history, the Flexa session,
    /// cached preferences, and locally-cached read-transaction state. Shared by the full
    /// `resetZashi` flow (`.resetZashiSDKSucceeded`) and by `reconcileWalletDatabaseWithSeed`,
    /// so a healed stale database (e.g. from a restored device backup) starts out just as
    /// clean as an explicit reset.
    ///
    /// Synchronous on purpose: every call site is a plain (non-`.run`) `Reduce` case, and
    /// none of the underlying operations are actually asynchronous.
    static func clearDeviceScopedWalletState(
        userDefaults: UserDefaultsClient,
        flexaHandler: FlexaHandlerClient,
        userStoredPreferences: UserPreferencesStorageClient,
        readTransactionsStorage: ReadTransactionsStorageClient
    ) {
        userDefaults.remove(Constants.udIsRestoringWallet)
        userDefaults.remove(Constants.udIsResyncingWallet)
        userDefaults.remove(Constants.udLeavesScreenOpen)
        #if VOTING_ENABLED
        userDefaults.remove(.hasSeenHowToVote)
        userDefaults.remove(.hasSeenHowToVoteKeystone)
        // Drop the user-supplied voting chain override and the saved
        // custom-chain list. Without this wipe, the next wallet on
        // this device would silently resolve voting through whatever
        // third-party host the previous owner had pointed at.
        userDefaults.remove(.votingConfigOverrideURL)
        userDefaults.remove(.votingCustomChains)
        // Delete the voting SQLite DB so per-round share delegation
        // history, vote records, and stored TX hashes from the
        // previous wallet don't leak across the reset boundary. The
        // file is recreated empty on the next voting flow entry.
        if let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first {
            let votingDbURL = documents.appendingPathComponent("voting.sqlite3")
            try? FileManager.default.removeItem(at: votingDbURL)
            // Preserved copies of the previous wallet's voting database are
            // the same wallet-scoped material, and must not cross the reset
            // boundary either.
            VotingDatabaseSnapshot.reset()
        }
        // Belt-and-suspenders: voting drafts and vote records live in
        // the encrypted per-account `votingMetadata` file now, which
        // resetAccount() below removes. This sweep catches any stale
        // plaintext entries from the previous UserDefaults-based
        // storage that hung around on internal dev devices.
        let standardDefaults = UserDefaults.standard
        for key in standardDefaults.dictionaryRepresentation().keys
            where key.hasPrefix("voting.voteRecord.") || key.hasPrefix("voting.draftVotes.") {
            standardDefaults.removeObject(forKey: key)
        }
        #endif
        flexaHandler.signOut()
        userStoredPreferences.removeAll()
        try? readTransactionsStorage.resetZashi()
    }

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

    /// The stale-wallet-heal notice (`AlertState.staleWalletDatabaseHealed()`) is deferred until
    /// the root destination settles on `.home`: presenting it immediately at heal time gets it
    /// auto-dismissed by the very destination switch that follows (SwiftUI tears down the
    /// presenting view branch before the alert has a chance to be seen). Three call sites can
    /// first satisfy "flag pending AND destination == `.home`" — the
    /// `.destination(.updateDestination)` hook, the synchronous `.phraseDisplay(.finishedTapped)` /
    /// `.onboarding(.newWalletSuccessfulyCreated)` transition, and `.staleWalletDatabaseHealed`
    /// itself when the heal completes while already on `.home` — so this effect is shared between
    /// all of them, keeping the wait-then-present logic in exactly one place.
    ///
    /// `cancelId` must be a dedicated ID (`state.staleWalletHealedAlertCancelId`) — never a
    /// shared/general-purpose one — so `cancelInFlight` only ever supersedes an earlier deferred
    /// present of this same notice, never an unrelated in-flight effect. Cancellation alone does
    /// not cover every misfire path (leaving `.home` while this is in flight doesn't cancel it,
    /// since only entering `.home` reschedules on this ID); `.presentStaleWalletHealedAlert`
    /// re-checks the destination at delivery time as the authoritative guard against presenting
    /// over the wrong screen.
    func presentStaleWalletHealedAlertEffect(cancelId: UUID) -> Effect<Root.Action> {
        .run { send in
            try await mainQueue.sleep(for: .seconds(0.5))
            await send(.initialization(.presentStaleWalletHealedAlert))
        }
        .cancellable(id: cancelId, cancelInFlight: true)
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

    static func staleWalletDatabaseHealed() -> AlertState {
        AlertState {
            TextState(String(localizable: .rootInitializationAlertStaleWalletDatabaseHealedTitle))
        } message: {
            TextState(String(localizable: .rootInitializationAlertStaleWalletDatabaseHealedMessage))
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
    
    static func shieldFundsNothingToShield() -> AlertState {
        AlertState {
            TextState(String(localizable: .shieldFundsNothingToShieldTitle))
        } message: {
            TextState(String(localizable: .shieldFundsNothingToShieldMessage))
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
