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
//  MOB-1478 (W4): immediate mode's `confirmTapped`/`retryTapped` silently split first when needed —
//  same `isNoteSplitNeeded()` -> `prepareNoteSplit`/`submitNoteSplit` sequence as `MigrationTransfer
//  Plan`, a split failure presents the same Cancel/Retry failure sheet `MigrationNoteSplit` uses
//  (this screen had none before), and the Keystone fork's proposed PCZT batch carries the note-split
//  PCZT first too, when needed. The manual-step path never forks (never re-signs, never splits) —
//  unchanged.
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
        /// MOB-1478 (W4): failure sheet for the silent note-split step (immediate mode only),
        /// presented instead of proceeding to sign+store — mirrors `MigrationNoteSplit.State
        /// .isFailurePresented`.
        var isFailurePresented = false
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

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Flow-root back control (manual step only): closes the flow instead of popping.
        case closeTapped
        /// Immediate mode silently splits (when needed) then signs+stores the schedule before
        /// delegating; manual step delegates directly.
        case confirmTapped
        case delegate(Delegate)
        /// MOB-1478 (W4): immediate mode's silent split step failed — presents the failure sheet
        /// instead of proceeding to sign+store.
        case noteSplitFailed
        /// Immediate mode only: proposes a single-transfer schedule for Amount/Fee display.
        case onAppear
        /// Failure sheet: dismiss, then re-attempt `confirmTapped`'s whole effect from scratch.
        case retryTapped
        /// `signAndStoreMigrationSchedule` completed (immediate mode only).
        case scheduleSigned
        /// `proposeMigrationTransfers()` result (immediate mode only).
        case transferProposed(MigrationSchedule)

        enum Delegate: Equatable {
            case closed
            case confirmed
            /// MOB-1468 (Keystone): the immediate-mode schedule's PCZT was proposed and needs QR
            /// signing — prefixed with the note-split PCZT first when needed (MOB-1478 W4) — a
            /// single-element (or two-element, split included) array batched into ONE QR ceremony,
            /// the shared shape across the Keystone signing sources so the coordinator can treat them
            /// symmetrically.
            case keystoneSignRequested([Pczt])
        }
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .confirmTapped, .retryTapped:
                state.isFailurePresented = false

                guard case .immediate = state.mode, let schedule = state.schedule else {
                    // Manual step: the transfer was already signed at plan commit — delegate directly.
                    return .send(.delegate(.confirmed))
                }

                let needsNoteSplit = sdkSynchronizer.isNoteSplitNeeded()

                guard state.selectedWalletAccount?.vendor == .keystone else {
                    return .run { send in
                        if needsNoteSplit {
                            let proposal = await sdkSynchronizer.prepareNoteSplit()
                            let splitResult = await sdkSynchronizer.submitNoteSplit(proposal)
                            guard case .success = splitResult else {
                                await send(.noteSplitFailed)
                                return
                            }
                        }
                        await sdkSynchronizer.signAndStoreMigrationSchedule(schedule)
                        await send(.scheduleSigned)
                    }
                }
                return requestKeystoneSignature(for: schedule, includeNoteSplit: needsNoteSplit)

            case .delegate:
                return .none

            case .noteSplitFailed:
                state.isFailurePresented = true
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

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes the immediate-mode schedule's PCZT —
    /// prefixed with the note-split PCZT when `includeNoteSplit` (MOB-1478 W4) — and hands the batch
    /// to the coordinator for QR signing.
    private func requestKeystoneSignature(for schedule: MigrationSchedule, includeNoteSplit: Bool) -> Effect<Action> {
        .run { send in
            var pczts: [Pczt] = []
            if includeNoteSplit {
                pczts.append(await sdkSynchronizer.proposeNoteSplitPCZT())
            }
            pczts.append(contentsOf: await sdkSynchronizer.proposeMigrationPCZTs(schedule))
            await send(.delegate(.keystoneSignRequested(pczts)))
        }
    }
}
