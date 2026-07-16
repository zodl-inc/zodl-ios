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
//  This same screen is reused, unchanged behaviorally, for the "Migrate anyway" dust lane
//  (MOB-1487): `usesMigratedCopy` swaps in the migrated-copy strings (subtitle/sent subtitle only —
//  titles and buttons stay the same) when the coordinator sets it; it defaults to false so the
//  existing lanes are unaffected.
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
        var networkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        /// When true, this instance is the "Migrate anyway" dust lane (MOB-1487): the view shows
        /// the migrated-copy strings and `onAppear` executes the dedicated dust sweep instead of
        /// the next scheduled transfer. Coordinator-configured; defaults to false so existing
        /// lanes are unaffected.
        var usesMigratedCopy = false

        init(
            phase: Phase = .sending,
            isFailurePresented: Bool = false,
            txId: String = "",
            totalCount: Int = 1,
            sentCount: Int = 0,
            networkPrivacyOptions: NetworkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            usesMigratedCopy: Bool = false
        ) {
            self.phase = phase
            self.isFailurePresented = isFailurePresented
            self.txId = txId
            self.totalCount = totalCount
            self.sentCount = sentCount
            self.networkPrivacyOptions = networkPrivacyOptions
            self.usesMigratedCopy = usesMigratedCopy
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
        case transferResult(TransferResult?)
        case viewTransactionTapped

        enum Delegate: Equatable {
            case closed
            case viewTransaction
        }
    }

    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

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
                return executeNextTransfer(options: state.networkPrivacyOptions, isDustLane: state.usesMigratedCopy)

            case .retryTapped:
                state.isFailurePresented = false
                return executeNextTransfer(options: state.networkPrivacyOptions, isDustLane: state.usesMigratedCopy)

            case .transferResult(let result):
                switch result {
                case .success(let txId):
                    state.txId = txId
                    state.sentCount += 1
                    // Synchronous, non-throwing dependency closure — no effect needed.
                    migrationManager.recordMigrationBroadcast()

                    let nextEffect: Effect<Action> = state.sentCount >= state.totalCount
                        ? .send(.allTransfersSent)
                        : executeNextTransfer(options: state.networkPrivacyOptions, isDustLane: state.usesMigratedCopy)

                    // scheduleNextWindow() is async (MOB-1467) — concatenated ahead of the
                    // follow-up effect so it still runs to completion before the next transfer
                    // kicks off (or before .allTransfersSent), matching the previous synchronous
                    // call-then-continue ordering.
                    return .concatenate(
                        .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() },
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
    private func executeNextTransfer(options: NetworkPrivacyOptions, isDustLane: Bool) -> Effect<Action> {
        .run { send in
            let result = isDustLane
                ? await sdkSynchronizer.migrateMigrationDust(options)
                : await sdkSynchronizer.executeNextPendingMigrationTransfer(options)
            await send(.transferResult(result))
        }
    }
}
