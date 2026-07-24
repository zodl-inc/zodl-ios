import SwiftUI
import ComposableArchitecture
import MessageUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct AdvancedSettings {
    @ObservableState
    struct State: Equatable {
        enum Operation: Equatable {
            case chooseServer
            case disconnectHWWallet
            case exportPrivateData
            case exportTaxFile
            case recoveryPhrase
            case resetZashi
            case resyncWallet
            case torSetup
        }

        #if DEBUG
        /// MOB-1513: QA-only fast-reschedule result — `rescheduled(count:)` covers both the
        /// N > 0 and the N == 0 ("nothing to reschedule") outcomes, `failed` covers a thrown SDK
        /// error and the defensive no-selected-account guard alike.
        enum DebugMigrationRescheduleOutcome: Equatable {
            case rescheduled(count: Int)
            case failed(String)
        }

        /// MOB-1513: QA-only manual-delivery result. `.networkError`/`.invalidNote`/`.expired`
        /// (a due transfer that was attempted and failed, as opposed to nothing being due at all)
        /// are folded into `failed` too — see `AdvancedSettings`'s reducer doc for why.
        enum DebugMigrationDeliverOutcome: Equatable {
            case delivered(txId: String)
            case nothingDue
            case failed(String)
        }
        #endif

        var isEnoughFreeSpaceMode = true
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        #if DEBUG
        @Presents var alert: AlertState<Action>?
        #endif

        var isKeystoneConnected: Bool {
            for account in walletAccounts {
                if account.vendor == .keystone {
                    return true
                }
            }

            return false
        }

        init() { }
    }

    enum Action: Equatable {
        case operationAccessCheck(State.Operation)
        case operationAccessGranted(State.Operation)
        #if DEBUG
        case alert(PresentationAction<Action>)
        case debugMigrationRescheduleTapped
        case debugMigrationRescheduleFinished(State.DebugMigrationRescheduleOutcome)
        case debugMigrationDeliverTapped
        case debugMigrationDeliverFinished(State.DebugMigrationDeliverOutcome)
        #endif
    }

    @Dependency(\.localAuthentication) var localAuthentication
    #if DEBUG
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    #endif

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .operationAccessCheck(let operation):
                switch operation {
                case .chooseServer, .torSetup:
                    return .send(.operationAccessGranted(operation))
                case .recoveryPhrase, .exportPrivateData, .exportTaxFile, .resetZashi, .disconnectHWWallet, .resyncWallet:
                    return .run { send in
                        if await localAuthentication.authenticate() {
                            await send(.operationAccessGranted(operation))
                        }
                    }
                }

            case .operationAccessGranted:
                return .none

            #if DEBUG
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .debugMigrationRescheduleTapped:
                guard let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.debugMigrationRescheduleFinished(.failed(Self.noAccountSelectedMessage)))
                }
                return .run { [sdkSynchronizer, migrationManager, migrationBGScheduler] send in
                    do {
                        let count = try await sdkSynchronizer.debugRescheduleMigrationTransfers(accountUUID)
                        await migrationManager.reconcile()
                        await migrationBGScheduler.scheduleFirstWindow()
                        await send(.debugMigrationRescheduleFinished(.rescheduled(count: count)))
                    } catch {
                        await send(.debugMigrationRescheduleFinished(.failed(error.toZcashError().localizedDescription)))
                    }
                }

            case .debugMigrationRescheduleFinished(let outcome):
                state.alert = AlertState.debugMigrationRescheduleResult(outcome)
                return .none

            case .debugMigrationDeliverTapped:
                guard let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.debugMigrationDeliverFinished(.failed(Self.noAccountSelectedMessage)))
                }
                return .run { [sdkSynchronizer, migrationManager] send in
                    let options = await migrationManager.migrationNetworkOptions(accountUUID)
                    // MOB-1513: no manual sync-resume call here on purpose — see this reducer's
                    // doc above `debugMigrationDeliverTapped` for the finding.
                    await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                    do {
                        let result = try await sdkSynchronizer.executeNextPendingMigrationTransfer(accountUUID, options)
                        switch result {
                        case .success(let txId):
                            await send(.debugMigrationDeliverFinished(.delivered(txId: txId)))
                        case nil:
                            await send(.debugMigrationDeliverFinished(.nothingDue))
                        case .some(let failure):
                            // `.networkError`/`.invalidNote`/`.expired`: a due transfer was attempted
                            // and failed — describe the UNWRAPPED value so the alert shows a plain
                            // "networkError(retryable: true)" rather than
                            // "Optional(ZcashLightClientKit.MigrationTransferResult.networkError(...))".
                            await send(.debugMigrationDeliverFinished(.failed(String(describing: failure))))
                        }
                    } catch {
                        await send(.debugMigrationDeliverFinished(.failed(error.toZcashError().localizedDescription)))
                    }
                }

            case .debugMigrationDeliverFinished(let outcome):
                state.alert = AlertState.debugMigrationDeliverResult(outcome)
                return .none
            #endif
            }
        }
    }

    #if DEBUG
    private static let noAccountSelectedMessage = "No wallet account selected"
    #endif
}

// MARK: - Debug Alerts (MOB-1513)

#if DEBUG
extension AlertState where Action == AdvancedSettings.Action {
    static func debugMigrationRescheduleResult(_ outcome: AdvancedSettings.State.DebugMigrationRescheduleOutcome) -> AlertState {
        let message: String
        switch outcome {
        case .rescheduled(let count) where count > 0:
            message = String(localizable: .debugMigrationRescheduleSuccessMessage(count))
        case .rescheduled:
            message = String(localizable: .debugMigrationRescheduleZeroMessage)
        case .failed(let errorMessage):
            message = String(localizable: .debugMigrationRescheduleErrorMessage(errorMessage))
        }
        return AlertState {
            TextState(String(localizable: .debugMigrationRescheduleAlertTitle))
        } message: {
            TextState(message)
        }
    }

    static func debugMigrationDeliverResult(_ outcome: AdvancedSettings.State.DebugMigrationDeliverOutcome) -> AlertState {
        let message: String
        switch outcome {
        case .delivered(let txId):
            message = String(localizable: .debugMigrationDeliverSuccessMessage(txId.truncateMiddle))
        case .nothingDue:
            message = String(localizable: .debugMigrationDeliverNothingDueMessage)
        case .failed(let errorMessage):
            message = String(localizable: .debugMigrationDeliverErrorMessage(errorMessage))
        }
        return AlertState {
            TextState(String(localizable: .debugMigrationDeliverAlertTitle))
        } message: {
            TextState(message)
        }
    }
}
#endif
