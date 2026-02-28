//
//  SmartBannerStore.swift
//  modules
//
//  Created by Lukáš Korba on 03.04.2025.
//

import Foundation
import ComposableArchitecture
import ZcashLightClientKit

import Generated
import SDKSynchronizer
import Utils
import Models
import WalletStorage
import UserPreferencesStorage
import UIComponents
import NetworkMonitor
import ZcashSDKEnvironment
import SupportDataGenerator
import MessageUI
import ShieldingProcessor

@Reducer
public struct SmartBanner {
    enum Constants: Equatable {
        static let easeInOutDuration = 0.85
        static let remindMe2days: TimeInterval = 86_400 * 2
        static let remindMe2weeks: TimeInterval = 86_400 * 14
        static let remindMeMonth: TimeInterval = 86_400 * 30
        static let smartBannerSyncingThreshold = 0.98
    }
    
    @ObservableState
    public struct State: Equatable {
        public enum PriorityContent: Int {
            case priority1 = 0 // disconnected
            case priority2 // syncing error
            case priority3 // restoring
            case priority4 // syncing
            case priority5 // updating balance
            case priority6 // wallet backup
            case priority7 // shielding
            case priority75 // tor
            case priority8 // currency conversion
            case priority9 // auto-shielding

            public func next() -> PriorityContent {
                PriorityContent.init(rawValue: self.rawValue - 1) ?? .priority9
            }
        }
        
        public var CancelNetworkMonitorId = UUID()
        public var CancelStateStreamId = UUID()
        public var CancelShieldingProcessorId = UUID()

        public var isScanProgressComplete = false
        public var delay = 1.5
        public var isOpen = false
        public var isShielding = false
        public var isShieldingAcknowledged = false
        public var isShieldingAcknowledgedAtKeychain = false
        public var isSmartBannerSheetPresented = false
        public var isSyncTimedOutSheetPresented = false
        public var isSyncTimedOutAutoAppeareDisabled = false
        public var isWalletBackupAcknowledged = false
        public var isWalletBackupAcknowledgedAtKeychain = false
        public var lastKnownErrorMessage = ""
        public var lastKnownSyncPercentage = -1.0
        public var messageToBeShared: String?
        public var priorityContent: PriorityContent? = nil
        public var priorityContentRequested: PriorityContent? = nil
        public var remindMeShieldedPhaseCounter = 0
        public var remindMeWalletBackupPhaseCounter = 0
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var spendableBalance = Zatoshi(0)
        public var supportData: SupportData?
        public var synchronizerStatusSnapshot: SyncStatusSnapshot = .snapshotFor(state: .unprepared)
        public var tokenName = "ZEC"
        @Shared(.inMemory(.transactions)) public var transactions: IdentifiedArrayOf<TransactionState> = []
        public var transparentBalance = Zatoshi(0)
        @Shared(.inMemory(.walletStatus)) public var walletStatus: WalletStatus = .none

        public var areFundsSpendable: Bool {
            isScanProgressComplete && spendableBalance.amount > 0
        }

        public var feeStr: String {
            Zatoshi(100_000).decimalString()
        }

        public var syncingPercentage: Double {
            lastKnownSyncPercentage >= 0 ? lastKnownSyncPercentage * 0.999 : 0
        }
        
        public var remindMeShieldedText: String {
            remindMeShieldedPhaseCounter == 0
            ? L10n.SmartBanner.Help.remindMePhase1
            : remindMeShieldedPhaseCounter == 1
            ? L10n.SmartBanner.Help.remindMePhase2
            : L10n.SmartBanner.Help.remindMePhase3
        }

        public var remindMeWalletBackupText: String {
            remindMeWalletBackupPhaseCounter == 0
            ? L10n.SmartBanner.Help.remindMePhase1
            : remindMeWalletBackupPhaseCounter == 1
            ? L10n.SmartBanner.Help.remindMePhase2
            : L10n.SmartBanner.Help.remindMePhase3
        }
        
        public init() { }
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<SmartBanner.State>)
        case closeAndCleanupBanner
        case closeBanner(Bool)
        case closeSheetTapped
        case onAppear
        case onDisappear
        case evaluatePriority1
        case evaluatePriority2
        case evaluatePriority3
        case evaluatePriority4
        case evaluatePriority5
        case evaluatePriority6
        case evaluatePriority7
        case evaluatePriority75
        case evaluatePriority8
        case evaluatePriority9
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
        case serverSwitchRequested
        case shieldFundsTapped
        case torSettingsRequested
        case torSetupScreenRequested
        case torSetupTapped
        case walletBackupTapped
    }

    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.networkMonitor) var networkMonitor
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.shieldingProcessor) var shieldingProcessor
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.tokenName = zcashSDKEnvironment.tokenName
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
                state.remindMeShieldedPhaseCounter = 0
                return .run { send in
                    await send(.closeBanner(true), animation: .easeInOut(duration: Constants.easeInOutDuration))
                    try? await mainQueue.sleep(for: .seconds(1))
                    await send(.evaluatePriority1)
                }

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
                if MFMailComposeViewController.canSendMail() {
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
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)
                
                if let account = state.selectedWalletAccount, let accountBalance = latestState.data.accountsBalances[account.id] {
                    state.spendableBalance = accountBalance.saplingBalance.spendableValue + accountBalance.orchardBalance.spendableValue
                }
                
                if snapshot.syncStatus != state.synchronizerStatusSnapshot.syncStatus {
                    state.synchronizerStatusSnapshot = snapshot
                    
                    var isSyncing = false
                    if case let .syncing(syncProgress, isScanProgressComplete) = snapshot.syncStatus {
                        state.lastKnownSyncPercentage = Double(syncProgress)
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
                        if state.priorityContent == .priority3 || state.priorityContent == .priority4 {
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
                            if accountBalance.unshielded > zcashSDKEnvironment.shieldingThreshold {
                                return .send(.transparentBalanceUpdated(accountBalance.unshielded))
                            } else {
                                return .merge(
                                    .send(.closeAndCleanupBanner),
                                    .send(.closeSheetTapped)
                                )
                            }
                        } else if state.transparentBalance < zcashSDKEnvironment.shieldingThreshold && accountBalance.unshielded > zcashSDKEnvironment.shieldingThreshold {
                            return .merge(
                                .send(.transparentBalanceUpdated(accountBalance.unshielded)),
                                .send(.triggerPriority(.priority7))
                            )
                        }
                    }
                    
                    // return of restoring/syncing
                    if isSyncing && state.priorityContent == nil {
                        if state.walletStatus == .restoring {
                            return .send(.triggerPriority(.priority3))
                        } else if state.lastKnownSyncPercentage >= 0 && state.lastKnownSyncPercentage < Constants.smartBannerSyncingThreshold {
                            return .send(.triggerPriority(.priority4))
                        }
                    }
                }

                return .none

                // disconnected
            case .evaluatePriority1:
                return .send(.evaluatePriority2)

                // syncing error
            case .evaluatePriority2:
                return .send(.evaluatePriority3)

                // restoring
            case .evaluatePriority3:
                if state.walletStatus == .restoring {
                    return .send(.triggerPriority(.priority3))
                }
                return .send(.evaluatePriority4)

                // syncing
            case .evaluatePriority4:
                if state.walletStatus != .restoring && state.lastKnownSyncPercentage >= 0 && state.lastKnownSyncPercentage < Constants.smartBannerSyncingThreshold {
                    return .send(.triggerPriority(.priority4))
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
                       accountBalance.unshielded >= zcashSDKEnvironment.shieldingThreshold {
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
                        let orchard = accountBalance.orchardBalance.total().amount
                        let sapling = accountBalance.saplingBalance.total().amount
                        let unshielded = accountBalance.unshielded.amount
                        
                        if orchard + sapling + unshielded == 0 {
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
                if let priorityContent = state.priorityContent, priorityContentRequested.rawValue >= priorityContent.rawValue {
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
}

extension SmartBanner.State {
    var isSyncTimedOut: Bool {
        lastKnownErrorMessage.lowercased().contains("504 gateway timeout")
        || lastKnownErrorMessage.lowercased().contains("tor error: tor: operation timed out at exit")
    }
}
