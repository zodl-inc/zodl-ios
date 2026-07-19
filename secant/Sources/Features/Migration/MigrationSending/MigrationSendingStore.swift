//
//  MigrationSendingStore.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). Shown while
//  migration transfers broadcast — one for immediate/manual/plan-first sends, or a sequential batch
//  for "send now" — then flips to a success state once every transfer in `totalCount` has been
//  executed. `onAppear` runs `executeNextPendingMigrationTransfer` strictly in sequence, recording a
//  broadcast and scheduling the next background window after each success; a failure/`nil` result
//  stops the sequence and presents the failure sheet, and `retryTapped` re-runs only the failed step
//  (MOB-1466). The `closeTapped` / `viewTransactionTapped` delegates are consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  This same screen is reused for the "Migrate anyway" dust lane (MOB-1487): `isDustLane` routes
//  execution through the dedicated dust sweep instead of the next scheduled transfer. MOB-1494
//  (round 4) unified the on-screen copy on the "migrated" wording for every lane (the canvas
//  dropped the "sent" variant), so the flag no longer affects any strings — execution only.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationSending {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case sending
            case success
        }

        var phase = Phase.sending
        /// Failure sheet presented over the sending phase.
        var isFailurePresented = false
        /// The most recently broadcast transfer's tx id (wires up View Transaction).
        var txId = ""
        /// How many transfers this screen instance is responsible for: 1 for immediate/manual/
        /// plan-first sends, N for a sequential "send now" batch. Coordinator-configured.
        var totalCount = 1
        /// How many of `totalCount` have been successfully broadcast so far.
        var sentCount = 0
        /// Submission options for `executeNextPendingMigrationTransfer`, injected by the coordinator.
        var networkPrivacyOptions = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
        /// When true, this instance is the "Migrate anyway" dust lane (MOB-1487): `onAppear`
        /// executes the dedicated dust sweep instead of the next scheduled transfer.
        /// Coordinator-configured; defaults to false so existing lanes are unaffected. Execution
        /// only — the on-screen copy is identical in every lane (MOB-1494).
        var isDustLane = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(
            phase: Phase = .sending,
            isFailurePresented: Bool = false,
            txId: String = "",
            totalCount: Int = 1,
            sentCount: Int = 0,
            networkPrivacyOptions: MigrationNetworkPrivacyOptions = MigrationNetworkPrivacyOptions(
                useTor: false,
                submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
            ),
            isDustLane: Bool = false
        ) {
            self.phase = phase
            self.isFailurePresented = isFailurePresented
            self.txId = txId
            self.totalCount = totalCount
            self.sentCount = sentCount
            self.networkPrivacyOptions = networkPrivacyOptions
            self.isDustLane = isDustLane
        }
    }

    enum Action: BindableAction, Equatable {
        /// All `totalCount` transfers have been successfully broadcast.
        case allTransfersSent
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        case closeTapped
        case delegate(Delegate)
        case onAppear
        /// Failure sheet: dismiss, then re-run the failed step.
        case retryTapped
        /// `executeNextPendingMigrationTransfer` result for the current step; `nil` on a stub/no-op.
        case transferResult(MigrationTransferResult?)
        case viewTransactionTapped

        enum Delegate: Equatable {
            case closed
            case viewTransaction
        }
    }

    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .allTransfersSent:
                state.phase = .success
                return .none

            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .delegate:
                return .none

            case .onAppear:
                return executeNextTransfer(account: state.selectedWalletAccount, options: state.networkPrivacyOptions, isDustLane: state.isDustLane)

            case .retryTapped:
                state.isFailurePresented = false
                return executeNextTransfer(account: state.selectedWalletAccount, options: state.networkPrivacyOptions, isDustLane: state.isDustLane)

            case .transferResult(let result):
                switch result {
                case .success(let txId):
                    state.txId = txId
                    state.sentCount += 1

                    let nextEffect: Effect<Action> = state.sentCount >= state.totalCount
                        ? .send(.allTransfersSent)
                        : executeNextTransfer(
                            account: state.selectedWalletAccount,
                            options: state.networkPrivacyOptions,
                            isDustLane: state.isDustLane
                        )

                    // scheduleNextWindow() is async (MOB-1467) — concatenated ahead of the
                    // follow-up effect so it still runs to completion before the next transfer
                    // kicks off (or before .allTransfersSent), matching the previous synchronous
                    // call-then-continue ordering. MOB-1496: `reconcile()` also runs here so
                    // `migrationManager.stateEvents` picks up the just-completed transfer promptly
                    // (a store completing a migration op is one of `reconcile()`'s two triggers).
                    // MOB-1496 (W2): `recordTransferBroadcast` persists the sent record the SDK
                    // itself no longer retains — runs before `reconcile()` so the freshly
                    // reconciled state is observed alongside an already-updated schedule.
                    return .concatenate(
                        .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                            await migrationManager.recordTransferBroadcast(accountUUID, MigrationTransferResult.success(txId: txId))
                        },
                        .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() },
                        .run { [migrationManager] _ in await migrationManager.reconcile() },
                        nextEffect
                    )

                case .networkError, .invalidNote, .expired, nil:
                    state.isFailurePresented = true
                    return .none
                }

            case .viewTransactionTapped:
                return .send(.delegate(.viewTransaction))
            }
        }
    }

    /// The dust lane ("Migrate anyway", MOB-1487) executes the dedicated dust sweep — never
    /// `executeNextPendingMigrationTransfer`, which is the scheduled-transfer path a background
    /// poll also drives and which must not move unconsented dust.
    ///
    /// MOB-1496: `migrateMigrationDust` needs the account's USK to sign — Keystone accounts have no
    /// PCZT-based dust-sweep lane yet (the SDK's composite has no PCZT variant), so they short-
    /// circuit to `nil` (surfaces as the ordinary failure sheet) rather than attempting a USK
    /// derivation that would misbehave for a hardware-wallet account. `executeNextPendingMigrationTransfer`
    /// needs no signing (it broadcasts an already-signed pending transfer), so it stays account-only
    /// for both vendors. `ZcashError.migrationRecordFailedAfterBroadcast` means the broadcast DID
    /// land and only recording failed (the engine self-heals later) — routed to a success-like
    /// result so the UX doesn't offer a needless retry or imply failure for something that worked;
    /// `txId` is a placeholder (the error carries no payload to recover the real one from).
    private func executeNextTransfer(account: WalletAccount?, options: MigrationNetworkPrivacyOptions, isDustLane: Bool) -> Effect<Action> {
        guard let account else {
            return .run { send in await send(.transferResult(nil)) }
        }

        return .run { send in
            do {
                let result: MigrationTransferResult?
                if isDustLane {
                    guard account.vendor != WalletAccount.Vendor.keystone, let zip32AccountIndex = account.zip32AccountIndex else {
                        await send(.transferResult(nil))
                        return
                    }
                    let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                        zip32AccountIndex: zip32AccountIndex,
                        walletStorage: walletStorage,
                        mnemonic: mnemonic,
                        derivationTool: derivationTool,
                        networkType: zcashSDKEnvironment.network().networkType
                    )
                    await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                    result = try await sdkSynchronizer.migrateMigrationDust(account.id, usk, options)
                } else {
                    await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                    result = try await sdkSynchronizer.executeNextPendingMigrationTransfer(account.id, options)
                }
                await send(.transferResult(result))
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                await send(.transferResult(MigrationTransferResult.success(txId: "")))
            } catch {
                await send(.transferResult(nil))
            }
        }
    }
}
