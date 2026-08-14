import SwiftUI
import Combine
import ComposableArchitecture
#if canImport(MessageUI)
import MessageUI
#endif
// `WalletAccount` comes from the pinned SDK, which does not declare it `Sendable`; every other
// store that holds one imports it this way.
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
            case restartMigration
            case resyncWallet
            case torSetup
        }

        var isEnoughFreeSpaceMode = true
        /// MOB-1466: whether a migration is IN PROGRESS — the only state a restart means anything
        /// in. The row is hidden otherwise: "Restart Migration" on a wallet with no plan is a door
        /// onto a screen that can only report zeros, and the engine call behind it has nothing to
        /// cancel.
        ///
        /// Lukas, 2026-08-07: "this option is visible in the advanced settings only if some
        /// migration is in progress." He was right to doubt the first cut — it asked whether a run
        /// EXISTED (`totalTransfers > 0`), which stays true forever after a run FINISHES. A
        /// completed migration would have kept offering to restart itself.
        var isMigrationInProgress = false
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

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
        case debugResetIronwoodAnnouncementTapped
        /// MOB-1466: the one-shot read that decides whether the Restart Migration row exists.
        case migrationRunPresence(Bool)
        case onAppear
        case operationAccessCheck(State.Operation)
        case operationAccessGranted(State.Operation)
    }

    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .debugResetIronwoodAnnouncementTapped:
                // Debug-only row, compiled out of the App Store build (see AdvancedSettingsView).
                // Clears the Ironwood-announcement keychain flag so the one-time announcement
                // screen can be retriggered for testing. That flag deliberately survives app
                // deletion and wallet reset, so without this affordance the screen could never be
                // seen again on a device that already acknowledged it. This only writes the
                // keychain — Root separately observes this same action to clear its in-memory
                // "already shown this session" latch, without which the reset wouldn't take
                // effect until the next app launch. No biometric gate: this destroys nothing.
                try? walletStorage.importIronwoodAnnouncementFlag(false)
                return .none

            case .onAppear:
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    let snapshot = await migrationManager.migrationViewSnapshot(accountUUID)
                    // IN PROGRESS = the run has transfers AND unfinished ones. Both halves matter:
                    // no transfers is "no run", and every transfer done is a run that has nothing
                    // left to cancel. Read off the same published snapshot the banner, the timeline
                    // and the pool header all render from, so the row can never disagree with them.
                    let hasUnfinishedWork = snapshot.totalTransfers > 0
                        && snapshot.doneTransfers < snapshot.totalTransfers
                    await send(.migrationRunPresence(hasUnfinishedWork))
                }

            case .migrationRunPresence(let isInProgress):
                state.isMigrationInProgress = isInProgress
                return .none

            case .operationAccessCheck(let operation):
                switch operation {
                // No biometric gate on the restart: its own confirmation sheet IS the gate, and
                // the flow spends nothing — it cancels a plan (already-broadcast transfers stay
                // migrated on-chain). Double-gating it would be the only place in the app where a
                // confirm sheet sits behind Face ID.
                case .chooseServer, .torSetup, .restartMigration:
                    return .send(.operationAccessGranted(operation))
                case .recoveryPhrase, .exportPrivateData, .exportTaxFile, .resetZashi, .disconnectHWWallet, .resyncWallet:
                    return .run { send in
                        if await localAuthentication.authenticate(for: .settings) {
                            await send(.operationAccessGranted(operation))
                        }
                    }
                }
                
            case .operationAccessGranted:
                return .none
            }
        }
    }
}
