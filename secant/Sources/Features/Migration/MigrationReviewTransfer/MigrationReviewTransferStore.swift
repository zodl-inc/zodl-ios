//
//  MigrationReviewTransferStore.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5" 2729:8544,
//  equivalent to frame 2712:7779 which fails to render via MCP). Final confirmation before a
//  migration transfer is sent — either the single immediate transfer, or one step of a scheduled
//  plan. Immediate mode proposes its own single-transfer schedule on `onAppear` (for Amount/Fee) and
//  signs+stores it on confirm before delegating; manual step has its data injected by the
//  coordinator (no propose) and confirm delegates directly — the transfer was already signed at plan
//  commit. When the manual-step variant is a flow re-entry root (`isFlowRoot`), its back control
//  closes the flow via a new `.closed` delegate instead of popping — reusing `.confirmed` for a
//  back-tap would incorrectly signal the transfer was confirmed (MOB-1466). Both delegates are
//  consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1468 (Keystone): a Keystone-vendor account in immediate mode forks `confirmTapped` — instead
//  of signing+storing `state.schedule` locally (the same schedule `onAppear` proposed via
//  `proposeMigrationTransfers()` for Amount/Fee), it proposes that schedule's PCZT
//  (`proposeMigrationPCZTs(schedule)`) and delegates `.keystoneSignRequested([pczt])` for the
//  coordinator to route through `MigrationKeystoneSign` + `Scan`. The manual-step path (transfers
//  already signed at plan commit) is unchanged — `signAndStoreMigrationSchedule` never runs there.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationReviewTransfer {
    @ObservableState
    struct State: Equatable {
        enum Mode: Equatable {
            case immediate
            case manualStep(number: Int, total: Int)
        }

        /// Standard ZIP-317 marginal fee shown throughout the app (`Zatoshi(100_000)` precedent —
        /// migration schedules don't carry a fee field of their own).
        fileprivate static let standardFee = Zatoshi(100_000)

        var mode = Mode.immediate
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero
        /// Immediate mode: the single-transfer schedule proposed on `onAppear`, signed+stored on
        /// confirm. `nil` in manual-step mode (nothing to propose or sign here).
        var schedule: MigrationSchedule?
        /// True when the manual-step variant is the coordinator's re-entry root — its back control
        /// then closes the flow instead of popping.
        var isFlowRoot = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(
            mode: Mode = .immediate,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            isFlowRoot: Bool = false
        ) {
            self.mode = mode
            self.amount = amount
            self.fee = fee
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        /// Flow-root back control (manual step only): closes the flow instead of popping.
        case closeTapped
        /// Immediate mode signs+stores the schedule then delegates; manual step delegates directly.
        case confirmTapped
        case delegate(Delegate)
        /// Immediate mode only: proposes a single-transfer schedule for Amount/Fee display.
        case onAppear
        /// `signAndStoreMigrationSchedule` completed (immediate mode only).
        case scheduleSigned
        /// `proposeMigrationTransfers()` result (immediate mode only).
        case transferProposed(MigrationSchedule)

        enum Delegate: Equatable {
            case closed
            case confirmed
            /// MOB-1468 (Keystone): the immediate-mode schedule's PCZT was proposed and needs QR
            /// signing — a single-element array (batched-session-of-1), the shared shape across all
            /// three Keystone signing sources so the coordinator can treat them symmetrically.
            case keystoneSignRequested([Pczt])
        }
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.closed))

            case .confirmTapped:
                guard case .immediate = state.mode, let schedule = state.schedule else {
                    // Manual step: the transfer was already signed at plan commit — delegate directly.
                    return .send(.delegate(.confirmed))
                }

                guard state.selectedWalletAccount?.vendor == .keystone else {
                    return .run { send in
                        await sdkSynchronizer.signAndStoreMigrationSchedule(schedule)
                        await send(.scheduleSigned)
                    }
                }
                return requestKeystoneSignature(for: schedule)

            case .delegate:
                return .none

            case .onAppear:
                guard case .immediate = state.mode else { return .none }

                return .run { send in
                    let schedule = await sdkSynchronizer.proposeMigrationTransfers()
                    await send(.transferProposed(schedule))
                }

            case .scheduleSigned:
                return .send(.delegate(.confirmed))

            case .transferProposed(let schedule):
                state.schedule = schedule
                state.amount = schedule.transfers.first?.amount ?? Zatoshi.zero
                state.fee = State.standardFee
                return .none
            }
        }
    }

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes the immediate-mode schedule's PCZT and
    /// hands it to the coordinator for QR signing.
    private func requestKeystoneSignature(for schedule: MigrationSchedule) -> Effect<Action> {
        .run { send in
            let pczts = await sdkSynchronizer.proposeMigrationPCZTs(schedule)
            await send(.delegate(.keystoneSignRequested(pczts)))
        }
    }
}
