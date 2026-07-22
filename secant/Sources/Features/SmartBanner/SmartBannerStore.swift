//
//  SmartBannerStore.swift
//  modules
//
//  Created by Lukáš Korba on 03.04.2025.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

import MessageUI

@Reducer
struct SmartBanner {
    enum Constants: Equatable {
        static let easeInOutDuration = 0.85
        static let remindMe2days: TimeInterval = 86_400 * 2
        static let remindMe2weeks: TimeInterval = 86_400 * 14
        static let remindMeMonth: TimeInterval = 86_400 * 30
        static let smartBannerSyncingBlocksThreshold: BlockHeight = 3456
    }
    
    @ObservableState
    struct State: Equatable {
        enum PriorityContent: Int {
            case priority1 = 0 // disconnected
            case priority2 // syncing error
            case priority3 // restoring
            case priority4 // syncing
            case priority45 // resyncing
            case priority5 // updating balance
            case priority6 // wallet backup
            case priority7 // shielding
            case priority75 // tor
            case priority8 // currency conversion
            case priority9 // auto-shielding
            case priorityMigration = -1 // ironwood migration (MOB-1464; triggered — MOB-1466)

            func next() -> PriorityContent {
                // `priorityMigration` (-1) sits outside the walk-down chain — it is only ever
                // triggered explicitly, so walking below `priority1` wraps to `priority9` as before.
                guard rawValue > 0 else { return .priority9 }
                return PriorityContent(rawValue: rawValue - 1) ?? .priority9
            }

            /// Display rank — lower wins. `priorityMigration` slots between `priority2` (sync error)
            /// and `priority3` (restoring): operational alerts outrank migration; migration outranks the rest.
            var rank: Double { self == .priorityMigration ? 1.5 : Double(rawValue) }
        }
        
        var CancelNetworkMonitorId = UUID()
        var CancelStateStreamId = UUID()
        var CancelMigrationStateStreamId = UUID()
        var CancelShieldingProcessorId = UUID()

        var isScanProgressComplete = false
        var delay = 1.5
        var isOpen = false
        var isShielding = false
        var isShieldingAcknowledged = false
        var isShieldingAcknowledgedAtKeychain = false
        var isSmartBannerSheetPresented = false
        var isSyncTimedOutSheetPresented = false
        var isSyncTimedOutAutoAppeareDisabled = false
        var isWalletBackupAcknowledged = false
        var isWalletBackupAcknowledgedAtKeychain = false
        var lastKnownBlocksRemaining: BlockHeight = -1
        var lastKnownErrorMessage = ""
        var lastKnownSyncPercentage = -1.0
        // MOB-1483: latch for the Ironwood-activation flip check in `.synchronizerStateChanged` —
        // nil until the first observation, then tracks the last-seen `isIronwoodActivated()`.
        var lastObservedIronwoodActivation: Bool?
        var messageToBeShared: String?
        var migrationBannerVariant = MigrationBannerVariant.required
        var priorityContent: PriorityContent? = nil
        var priorityContentRequested: PriorityContent? = nil
        var remindMeShieldedPhaseCounter = 0
        var remindMeWalletBackupPhaseCounter = 0
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var spendableBalance = Zatoshi(0)
        var supportData: SupportData?
        var synchronizerStatusSnapshot: SyncStatusSnapshot = .snapshotFor(state: .unprepared)
        var tokenName = "ZEC"
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        var transparentBalance = Zatoshi(0)
        @Shared(.inMemory(.walletStatus)) var walletStatus: WalletStatus = .none

        var areFundsSpendable: Bool {
            isScanProgressComplete && spendableBalance.amount > 0
        }

        var feeStr: String {
            Zatoshi(100_000).decimalString()
        }

        var syncingPercentage: Double {
            lastKnownSyncPercentage >= 0 ? lastKnownSyncPercentage * 0.999 : 0
        }
        
        var remindMeShieldedText: String {
            remindMeShieldedPhaseCounter == 0
            ? String(localizable: .smartBannerHelpRemindMePhase1)
            : remindMeShieldedPhaseCounter == 1
            ? String(localizable: .smartBannerHelpRemindMePhase2)
            : String(localizable: .smartBannerHelpRemindMePhase3)
        }

        var remindMeWalletBackupText: String {
            remindMeWalletBackupPhaseCounter == 0
            ? String(localizable: .smartBannerHelpRemindMePhase1)
            : remindMeWalletBackupPhaseCounter == 1
            ? String(localizable: .smartBannerHelpRemindMePhase2)
            : String(localizable: .smartBannerHelpRemindMePhase3)
        }
        
        init() { }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<SmartBanner.State>)
        case closeAndCleanupBanner
        case closeBanner(Bool)
        case closeSheetTapped
        case onAppear
        case onDisappear
        case evaluatePriority1
        case evaluatePriority2
        case evaluatePriorityMigration
        case evaluatePriority3
        case evaluatePriority4
        case evaluatePriority45
        case evaluatePriority5
        case evaluatePriority6
        case evaluatePriority7
        case evaluatePriority75
        case evaluatePriority8
        case evaluatePriority9
        case migrationStateChanged(MigrationState)
        case migrationVariantLoaded(MigrationBannerVariant?)
        case migrationVariantUpdated(MigrationBannerVariant?)
        case reevaluateMigrationOnActivationFlip
        case networkMonitorChanged(Bool)
        case openBanner
        case openBannerRequest
        case remindMeLaterTapped(State.PriorityContent)
        case reportPrepared
        case reportTapped
        case sendSupportMailFinished
        case shareFinished
        case shieldingProcessorStateChanged(ShieldingProcessorClient.State)
        case smartBannerContentTapped
        case synchronizerStateChanged(RedactableSynchronizerState)
        case transparentBalanceUpdated(Zatoshi)
        case triggerPriority(State.PriorityContent)
        case walletAccountChanged

        // Action buttons
        case autoShieldingTapped
        case currencyConversionScreenRequested
        case currencyConversionTapped
        case migrationScreenRequested
        case serverSwitchRequested
        case shieldFundsTapped
        case torSettingsRequested
        case torSetupScreenRequested
        case torSetupTapped
        case walletBackupTapped
    }

    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.networkMonitor) var networkMonitor
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.shieldingProcessor) var shieldingProcessor
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.tokenName = zcashSDKEnvironment.tokenName()
                state.isWalletBackupAcknowledgedAtKeychain = walletStorage.exportWalletBackupAcknowledged()
                state.isWalletBackupAcknowledged = state.isWalletBackupAcknowledgedAtKeychain
                state.isShieldingAcknowledgedAtKeychain = walletStorage.exportShieldingAcknowledged()
                state.isShieldingAcknowledged = state.isShieldingAcknowledgedAtKeychain
                if !state.isSyncTimedOutAutoAppeareDisabled {
                    state.isSyncTimedOutSheetPresented = state.isSyncTimedOut
                    state.isSyncTimedOutAutoAppeareDisabled = state.isSyncTimedOutSheetPresented
                }
                return .merge(
                    .publisher {
                        networkMonitor.networkMonitorStream()
                            .map(Action.networkMonitorChanged)
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.CancelNetworkMonitorId, cancelInFlight: true),
                    .publisher {
                        sdkSynchronizer.stateStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .map { $0.redacted }
                            .map(Action.synchronizerStateChanged)
                    }
                    .cancellable(id: state.CancelStateStreamId, cancelInFlight: true),
                    migrationStateStreamEffect(
                        accountUUID: state.selectedWalletAccount?.id,
                        cancelID: state.CancelMigrationStateStreamId
                    ),
                    .publisher {
                        shieldingProcessor.observe()
                            .map(Action.shieldingProcessorStateChanged)
                    }
                    .cancellable(id: state.CancelShieldingProcessorId, cancelInFlight: true)
                )
                
            case .onDisappear:
                // __LD2 TESTED
                return .merge(
                    .cancel(id: state.CancelNetworkMonitorId),
                    .cancel(id: state.CancelStateStreamId),
                    .cancel(id: state.CancelMigrationStateStreamId),
                    .cancel(id: state.CancelShieldingProcessorId)
                )

            case .binding(\.isShieldingAcknowledged):
                try? walletStorage.importShieldingAcknowledged(state.isShieldingAcknowledged)
                return .none

            case .binding:
                return .none
                
            case .sendSupportMailFinished:
                state.supportData = nil
                return .none
                
            case .shieldingProcessorStateChanged(let shieldingProcessorState):
                if shieldingProcessorState == .succeeded {
                    state.transparentBalance = .zero
                }
                state.isShielding = shieldingProcessorState == .requested
                if (state.isOpen || state.isSmartBannerSheetPresented) && state.priorityContent == .priority7 {
                    var hideEverything = false
                    if case .proposal = shieldingProcessorState {
                        hideEverything = true
                    } else if shieldingProcessorState == .succeeded {
                        hideEverything = true
                    }
                    if hideEverything {
                        return .merge(
                            .send(.closeAndCleanupBanner),
                            .send(.closeSheetTapped)
                        )
                    }
                }
                return .none
                
            case .walletAccountChanged:
                // MOB-1496 (R8-T7 #12): the migration `stateEvents` subscription is keyed to the
                // account id captured at `.onAppear` — Home stays mounted across an account switch
                // (the switcher is a sheet, so `.onAppear` never re-fires), and this action was the
                // ONLY signal of that switch, yet it never re-pointed the subscription. The
                // still-subscribed OLD account's subject never emits again post-switch (`reconcile()`
                // pushes per-account subjects), so the banner silently stopped tracking migration
                // state for the newly selected account. Cancel-then-resubscribe, concatenated (not
                // merged) so the new subscription can't start racing the old one's teardown — a gap
                // here would risk losing the new subject's replayed seed value. `stateEvents` returns
                // a `CurrentValueSubject`-backed publisher, which DOES replay its current value to a
                // fresh subscriber, so the resubscribe alone delivers the new account's latest known
                // state without a separate manual refresh (unlike `.onAppear`'s own initial-load
                // reads just above, which have no such replay to lean on).
                state.remindMeShieldedPhaseCounter = 0
                let newMigrationAccountUUID = state.selectedWalletAccount?.id
                return .merge(
                    .concatenate(
                        .cancel(id: state.CancelMigrationStateStreamId),
                        migrationStateStreamEffect(accountUUID: newMigrationAccountUUID, cancelID: state.CancelMigrationStateStreamId)
                    ),
                    .run { send in
                        await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                        try? await mainQueue.sleep(for: .seconds(1))
                        await send(.evaluatePriority1)
                    }
                )

            case .reportTapped:
                state.isSyncTimedOutSheetPresented = false
                return .run { send in
                    await send(.closeSheetTapped)
                    try? await mainQueue.sleep(for: .seconds(1))
                    await send(.reportPrepared)
                }
                
            case .reportPrepared:
                var supportData = SupportDataGenerator.generate()
                supportData.message =
                """
                code: -2000
                \(state.lastKnownErrorMessage)
                
                \(supportData.message)
                """
                // TCA Store is @MainActor; reducer body always runs on main.
                if MainActor.assumeIsolated({ MFMailComposeViewController.canSendMail() }) {
                    state.supportData = supportData
                } else {
                    state.messageToBeShared = supportData.message
                }
                return .none
                
            case .shareFinished:
                state.messageToBeShared = nil
                return .none
                
            case .networkMonitorChanged(let isConnected):
                if state.priorityContent == .priority1 && isConnected {
                    return .run { send in
                        await send(.closeAndCleanupBanner)
                        try? await mainQueue.sleep(for: .seconds(2))
                        await send(.evaluatePriority2)
                    }
                } else if state.priorityContent != .priority1 && !isConnected {
                    return .send(.triggerPriority(.priority1))
                }
                return .none
                
            case .smartBannerContentTapped:
                if state.priorityContent == .priority7 {
                    state.isShieldingAcknowledgedAtKeychain = walletStorage.exportShieldingAcknowledged()
                    if state.isShieldingAcknowledgedAtKeychain {
                        return .none
                    }
                } else if state.priorityContent == .priority75 {
                    return .send(.torSetupScreenRequested)
                } else if state.priorityContent == .priority8 {
                    return .send(.currencyConversionScreenRequested)
                } else if state.priorityContent == .priorityMigration {
                    return .send(.migrationScreenRequested)
                } else if state.isSyncTimedOut {
                    state.isSyncTimedOutSheetPresented = true
                    return .none
                }
                state.isSmartBannerSheetPresented = true
                return .none
                
            case .closeSheetTapped:
                state.isSmartBannerSheetPresented = false
                return .none

            case .remindMeLaterTapped(let priority):
                if priority == .priority6 {
                    try? walletStorage.importWalletBackupAcknowledged(state.isWalletBackupAcknowledged)
                    state.isWalletBackupAcknowledgedAtKeychain = walletStorage.exportWalletBackupAcknowledged()
                }
                state.isSmartBannerSheetPresented = false
                state.priorityContentRequested = nil
                let now = Date().timeIntervalSince1970
                // wallet backup = priority6
                if priority == .priority6 {
                    if var walletBackupReminder = walletStorage.exportWalletBackupReminder() {
                        walletBackupReminder.occurence += 1
                        walletBackupReminder.timestamp = now
                        try? walletStorage.importWalletBackupReminder(walletBackupReminder)
                    } else {
                        let walletBackupReminder = ReminedMeTimestamp(timestamp: now, occurence: 1)
                        try? walletStorage.importWalletBackupReminder(walletBackupReminder)
                    }
                } else if priority == .priority7 {
                    // shielding = priority7
                    if let account = state.selectedWalletAccount {
                        if var shieldingReminder = walletStorage.exportShieldingReminder(account.vendor.name()) {
                            shieldingReminder.occurence += 1
                            shieldingReminder.timestamp = now
                            try? walletStorage.importShieldingReminder(shieldingReminder, account.vendor.name())
                        } else {
                            let shieldingReminder = ReminedMeTimestamp(timestamp: now, occurence: 1)
                            try? walletStorage.importShieldingReminder(shieldingReminder, account.vendor.name())
                        }
                    }
                }
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(1))
                    await send(.closeBanner(false), animation: .easeInOut(duration: Constants.easeInOutDuration))
                }
                
            case .synchronizerStateChanged(let latestState):
                // MOB-1483 (W4): computed as two independent effects and merged, rather than
                // folded into one flow — `syncStatusChangedEffect` below has many early-return
                // branches (sync status change handling), and any one of those firing on the same
                // tick as an activation flip must not silently swallow the flip's re-evaluation
                // (a cold-launch tick is exactly where both are likely to coincide: the priority
                // walk racing the first chain-tip fetch is the scenario `ironwoodActivationFlipEffect`
                // exists to correct).
                let activationFlipEffect = ironwoodActivationFlipEffect(state: &state)
                let syncStatusEffect = syncStatusChangedEffect(state: &state, latestState: latestState)
                return .merge(activationFlipEffect, syncStatusEffect)

            case .migrationStateChanged:
                // The stream only tells us migration state changed, not what it resolved to — the
                // manager owns the state->variant derivation (balances, persistence, transfer rows),
                // so recompute the same way the walk step does, via `migrationManager.bannerVariant`.
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    await send(.migrationVariantUpdated(migrationManager.bannerVariant(accountUUID)))
                }

            case .migrationVariantUpdated(let variant):
                if let variant {
                    state.migrationBannerVariant = variant
                    if state.priorityContent != .priorityMigration {
                        return .send(.triggerPriority(.priorityMigration))
                    }
                    // Already showing migration — content re-renders from the updated variant
                    // alone; re-triggering would just be rejected by the `openBannerRequest`
                    // rank guard anyway (equal rank), so skip the round trip.
                    return .none
                }
                if state.priorityContent == .priorityMigration {
                    // Send `.closeBanner(true)` directly rather than `.closeAndCleanupBanner` —
                    // the latter wraps its send in its own `.run`, which only schedules that
                    // nested effect rather than awaiting it, so a second `await send(...)` right
                    // after it would race the close instead of running after it settles (the same
                    // reason `.walletAccountChanged` above sends `.closeBanner(true)` directly).
                    return .run { send in
                        await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                        await send(.evaluatePriority1)
                    }
                }
                return .none

            case .reevaluateMigrationOnActivationFlip:
                // MOB-1483 (W4): identical fetch-and-route to `.migrationStateChanged` above —
                // reused rather than duplicated, so an activation-day crossing (or a reorg back
                // below the activation height) raises/lowers the banner through the same
                // variant-fetch + `.migrationVariantUpdated` path.
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    await send(.migrationVariantUpdated(migrationManager.bannerVariant(accountUUID)))
                }

                // disconnected
            case .evaluatePriority1:
                return .send(.evaluatePriority2)

                // syncing error
            case .evaluatePriority2:
                return .send(.evaluatePriorityMigration)

                // ironwood migration
            case .evaluatePriorityMigration:
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    await send(.migrationVariantLoaded(migrationManager.bannerVariant(accountUUID)))
                }

                // restoring
            case .evaluatePriority3:
                if state.walletStatus == .restoring {
                    return .send(.triggerPriority(.priority3))
                }
                return .send(.evaluatePriority4)

                // syncing
            case .evaluatePriority4:
                if state.walletStatus != .restoring && state.lastKnownBlocksRemaining >= Constants.smartBannerSyncingBlocksThreshold {
                    return .send(.triggerPriority(.priority4))
                }
                return .send(.evaluatePriority45)

                // resyncing
            case .evaluatePriority45:
                if state.walletStatus == .resyncing {
                    //return .send(.triggerPriority(.priority45))
                }
                return .send(.evaluatePriority5)

                // updating balance
            case .evaluatePriority5:
                return .send(.evaluatePriority6)

                // wallet backup
            case .evaluatePriority6:
                guard let account = state.selectedWalletAccount, account.vendor == .zcash else {
                    return .send(.evaluatePriority7)
                }
                guard !state.transactions.isEmpty else {
                    return .send(.evaluatePriority7)
                }
                if let storedWallet = try? walletStorage.exportWallet(), !storedWallet.hasUserPassedPhraseBackupTest {
                    if let walletBackupReminder = walletStorage.exportWalletBackupReminder() {
                        state.remindMeWalletBackupPhaseCounter = walletBackupReminder.occurence
                        let now = Date().timeIntervalSince1970

                        if (state.remindMeWalletBackupPhaseCounter == 1 && walletBackupReminder.timestamp + Constants.remindMe2days < now)
                            || (state.remindMeWalletBackupPhaseCounter == 2 && walletBackupReminder.timestamp + Constants.remindMe2weeks < now)
                            || (state.remindMeWalletBackupPhaseCounter > 2 && walletBackupReminder.timestamp + Constants.remindMeMonth < now) {
                            return .send(.triggerPriority(.priority6))
                        }
                    } else {
                        // phase 1
                        return .send(.triggerPriority(.priority6))
                    }
                }
                return .send(.evaluatePriority7)

                // shielding
            case .evaluatePriority7:
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                if let shieldedReminder = walletStorage.exportShieldingReminder(account.vendor.name()) {
                    state.remindMeShieldedPhaseCounter = shieldedReminder.occurence
                }
                return .run { [remindMeShieldedPhaseCounter = state.remindMeShieldedPhaseCounter] send in
                    if let accountBalance = try? await sdkSynchronizer.getAccountsBalances()[account.id],
                       accountBalance.unshielded >= zcashSDKEnvironment.shieldingThreshold() {
                        await send(.transparentBalanceUpdated(accountBalance.unshielded))
                        
                        if let shieldedReminder = walletStorage.exportShieldingReminder(account.vendor.name()) {
                            let now = Date().timeIntervalSince1970

                            if (remindMeShieldedPhaseCounter == 1 && shieldedReminder.timestamp + Constants.remindMe2days < now)
                                || (remindMeShieldedPhaseCounter == 2 && shieldedReminder.timestamp + Constants.remindMe2weeks < now)
                                || (remindMeShieldedPhaseCounter > 2 && shieldedReminder.timestamp + Constants.remindMeMonth < now) {
                                await send(.triggerPriority(.priority7))
                            }
                        } else {
                            // phase 1
                            await send(.triggerPriority(.priority7))
                        }
                    } else {
                        await send(.evaluatePriority75)
                    }
                }
                
                // tor
            case .evaluatePriority75:
                if walletStorage.exportTorSetupFlag() == nil {
                    return .send(.triggerPriority(.priority75))
                }
                return .send(.evaluatePriority8)

                // currency conversion
            case .evaluatePriority8:
                if let account = state.selectedWalletAccount {
                    if let accountBalance = sdkSynchronizer.latestState().accountsBalances[account.id] {
                        let shielded = accountBalance.shieldedTotal().amount
                        let unshielded = accountBalance.unshielded.amount

                        if shielded + unshielded == 0 {
                            return .send(.evaluatePriority9)
                        }
                    }
                }
                if userStoredPreferences.exchangeRate() == nil {
                    return .send(.triggerPriority(.priority8))
                }
                return .send(.evaluatePriority9)
                
                // auto-shielding
            case .evaluatePriority9:
                return .none

            case .migrationVariantLoaded(let variant):
                guard let variant else {
                    return .send(.evaluatePriority3)
                }
                state.migrationBannerVariant = variant
                return .send(.triggerPriority(.priorityMigration))

            case .triggerPriority(let priority):
                state.priorityContentRequested = priority
                return .send(.openBannerRequest)

            case .transparentBalanceUpdated(let balance):
                state.transparentBalance = balance
                return .none
                
            case .openBannerRequest:
                guard let priorityContentRequested = state.priorityContentRequested else {
                    return .none
                }
                if let priorityContent = state.priorityContent, priorityContentRequested.rank >= priorityContent.rank {
                    return .none
                }
                if state.isOpen {
                    return .run { send in
                        await send(.closeBanner(false), animation: .easeInOut(duration: Constants.easeInOutDuration))
                    }
                }
                state.priorityContent = priorityContentRequested
                return .run { [delay = state.delay] send in
                    try? await mainQueue.sleep(for: .seconds(delay))
                    await send(.openBanner, animation: .easeInOut(duration: Constants.easeInOutDuration))
                }
                
            case .closeBanner(let clean):
                state.isOpen = false
                if clean {
                    state.priorityContentRequested = nil
                    state.priorityContent = nil
                }
                return .send(.openBannerRequest)

            case .closeAndCleanupBanner:
                return .run { send in
                    await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                }

            case .openBanner:
                state.delay = 1.0
                state.isOpen = true
                return .none
                
                // MARK: - Actions
                
            case .autoShieldingTapped:
                return .none
                
            case .currencyConversionScreenRequested:
                return .none
                
            case .currencyConversionTapped:
                return .send(.smartBannerContentTapped)

            case .migrationScreenRequested:
                // No state change here — Root intercepts this leaf action to open
                // `MigrationCoordFlow` (MOB-1466 phase 5), the same shape as
                // `currencyConversionScreenRequested` / `torSetupScreenRequested` above.
                return .none

            case .torSetupScreenRequested:
                return .none
                
            case .torSettingsRequested:
                state.isSyncTimedOutSheetPresented = false
                return .none

            case .torSetupTapped:
                return .send(.smartBannerContentTapped)

            case .serverSwitchRequested:
                state.isSyncTimedOutSheetPresented = false
                return .none

            case .shieldFundsTapped:
                state.isSmartBannerSheetPresented = false
                shieldingProcessor.shieldFunds()
                return .send(.closeAndCleanupBanner)

            case .walletBackupTapped:
                state.isSmartBannerSheetPresented = false
                return .none
            }
        }
    }

    // MARK: - MOB-1496 (R8-T7 #12): migration stateEvents subscription

    /// The migration-trigger subscription effect, factored out so both `.onAppear` (first mount)
    /// and `.walletAccountChanged` (re-key after an account switch) build the IDENTICAL
    /// throttle/map pipeline over `migrationManager.stateEvents(accountUUID)` — the only thing that
    /// differs between the two call sites is which account id and which point in the store's
    /// lifecycle triggers it. Always registered under the SAME stable `cancelID`
    /// (`state.CancelMigrationStateStreamId`, fixed for the life of the store), so a fresh
    /// subscription here supersedes whatever the same id was previously bound to.
    private func migrationStateStreamEffect(accountUUID: AccountUUID?, cancelID: UUID) -> Effect<Action> {
        .publisher {
            migrationManager.stateEvents(accountUUID)
                .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                .map(Action.migrationStateChanged)
        }
        .cancellable(id: cancelID, cancelInFlight: true)
    }

    // MARK: - MOB-1483: Ironwood-activation flip (W4)

    /// Detects an Ironwood-activation flip on every synchronizer tick and, when one occurs,
    /// triggers a migration-variant re-evaluation through the existing raise/lower machinery
    /// (`.reevaluateMigrationOnActivationFlip` mirrors `.migrationStateChanged`). Returned as a
    /// separate effect from `syncStatusChangedEffect` and merged with it by the caller, so
    /// neither can silently drop the other regardless of which of that function's several
    /// early-return branches fires on the same tick.
    ///
    /// - First observation (`lastObservedIronwoodActivation == nil`): latches the current value.
    ///   If already activated, the priority walk earlier in this same cold launch may have
    ///   evaluated while the chain tip was still unknown (0) — re-evaluate once to close that race.
    /// - Latched flip (`activated != lastObservedIronwoodActivation`): activation-day crossing
    ///   raises the banner; a reorg back below the activation height lowers it again.
    /// Unchanged latch: `.none`, no further state write — the steady-state cost of this check is
    /// one cached-state read plus a comparison, every tick.
    private func ironwoodActivationFlipEffect(state: inout State) -> Effect<Action> {
        let activated = migrationManager.isIronwoodActivated()

        guard let latch = state.lastObservedIronwoodActivation else {
            state.lastObservedIronwoodActivation = activated
            return activated ? .send(.reevaluateMigrationOnActivationFlip) : .none
        }

        guard activated != latch else {
            return .none
        }
        state.lastObservedIronwoodActivation = activated
        return .send(.reevaluateMigrationOnActivationFlip)
    }

    /// The pre-MOB-1483 body of `.synchronizerStateChanged`, unchanged — extracted verbatim so it
    /// can be merged with `ironwoodActivationFlipEffect` above instead of racing it for the
    /// case's single return value.
    private func syncStatusChangedEffect(state: inout State, latestState: RedactableSynchronizerState) -> Effect<Action> {
        let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

        if let account = state.selectedWalletAccount, let accountBalance = latestState.data.accountsBalances[account.id] {
            state.spendableBalance = accountBalance.shieldedSpendableValue
        }

        if snapshot.syncStatus != state.synchronizerStatusSnapshot.syncStatus {
            state.synchronizerStatusSnapshot = snapshot

            var isSyncing = false
            if case let .syncing(syncProgress, isScanProgressComplete) = snapshot.syncStatus {
                state.lastKnownSyncPercentage = Double(syncProgress)
                state.lastKnownBlocksRemaining = max(
                    0,
                    latestState.data.latestBlockHeight - latestState.data.fullyScannedHeight
                )
                state.isScanProgressComplete = isScanProgressComplete
                isSyncing = true

                if state.priorityContent == .priority2 {
                    return .send(.closeAndCleanupBanner)
                }
            }

            // error syncing check
            switch snapshot.syncStatus {
            case .upToDate:
                state.isSyncTimedOutAutoAppeareDisabled = false
                // Reset the syncing block-count so a re-eval of priority 4 after sync
                // completes (account change, reconnect) doesn't see the last `.syncing`
                // sample (which can still be >= the show threshold if the SDK skipped
                // a final low-remainder update) and spuriously re-show the banner.
                state.lastKnownBlocksRemaining = -1
                if state.priorityContent == .priority3 || state.priorityContent == .priority45 || state.priorityContent == .priority4 {
                    return .send(.closeAndCleanupBanner)
                }
            case .error, .unprepared:
                if state.lastKnownErrorMessage != snapshot.message {
                    state.lastKnownErrorMessage = snapshot.message
                    return .send(.triggerPriority(.priority2))
                }
            default: break
            }

            if let account = state.selectedWalletAccount, let accountBalance = latestState.data.accountsBalances[account.id] {
                if state.priorityContent == .priority7 {
                    if accountBalance.unshielded > zcashSDKEnvironment.shieldingThreshold() {
                        return .send(.transparentBalanceUpdated(accountBalance.unshielded))
                    } else {
                        return .merge(
                            .send(.closeAndCleanupBanner),
                            .send(.closeSheetTapped)
                        )
                    }
                } else if state.transparentBalance < zcashSDKEnvironment.shieldingThreshold() && accountBalance.unshielded > zcashSDKEnvironment.shieldingThreshold() {
                    return .merge(
                        .send(.transparentBalanceUpdated(accountBalance.unshielded)),
                        .send(.triggerPriority(.priority7))
                    )
                }
            }

            // return of restoring/syncing
            // `rank` (not `rawValue`) so `priorityMigration`'s rank (1.5, between priority2
            // and priority3) correctly keeps this branch from replacing a showing migration
            // banner with priority3/priority4 — `rawValue` (-1) would give the same numeric
            // answer here today only by coincidence.
            let isSyncingHigherPriority = (state.priorityContent?.rank ?? 0) > State.PriorityContent.priority4.rank
            if isSyncing && (state.priorityContent == nil || isSyncingHigherPriority) {
                if state.walletStatus == .resyncing {
                    //return .send(.triggerPriority(.priority45))
                } else if state.walletStatus == .restoring {
                    return .send(.triggerPriority(.priority3))
                } else if state.lastKnownBlocksRemaining >= Constants.smartBannerSyncingBlocksThreshold {
                    return .send(.triggerPriority(.priority4))
                }
            }
        }

        return .none
    }
}

extension SmartBanner.State {
    var isSyncTimedOut: Bool {
        lastKnownErrorMessage.lowercased().contains("504 gateway timeout")
        || lastKnownErrorMessage.lowercased().contains("tor error: tor: operation timed out at exit")
    }
}
