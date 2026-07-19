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
//  `proposeImmediateMigration()` for Amount/Fee), it proposes that schedule's PCZT
//  (`proposeMigrationPCZTs(schedule)`) and delegates `.keystoneSignRequested(pczts)` for the
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
            /// symmetrically. MOB-1496: see `requestKeystoneSignature`'s doc for the note-split
            /// sentinel-id wrapping.
            case keystoneSignRequested([MigrationUnsignedTransferPczt])
        }
    }

    @Dependency(\.derivationTool) var derivationTool
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
                guard let account = state.selectedWalletAccount else { return .none }

                guard account.vendor != WalletAccount.Vendor.keystone else {
                    return requestKeystoneSignature(for: schedule, account: account)
                }

                guard let zip32AccountIndex = account.zip32AccountIndex else { return .none }

                return .run { send in
                    do {
                        let needsNoteSplit = try await sdkSynchronizer.isNoteSplitNeeded(account.id)
                        let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                            zip32AccountIndex: zip32AccountIndex,
                            walletStorage: walletStorage,
                            mnemonic: mnemonic,
                            derivationTool: derivationTool,
                            networkType: zcashSDKEnvironment.network().networkType
                        )
                        if needsNoteSplit {
                            let proposal = try await sdkSynchronizer.prepareNoteSplit(account.id)
                            let options = migrationManager.networkPrivacyOptions()
                            // [MOB-1496] W3 review fix A: this silent note-split broadcast was
                            // missed by the original stop-before-broadcast sweep (which only
                            // covered MigrationSendingStore/MigrationNoteSplitStore) — same shared
                            // helper, same rationale (the SDK's during-sync throw is advisory).
                            await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                            let splitResult = try await sdkSynchronizer.submitNoteSplit(account.id, proposal, usk, options)
                            guard case MigrationTransferResult.success = splitResult else {
                                await send(.noteSplitFailed)
                                return
                            }
                        }
                        try await sdkSynchronizer.signAndStoreMigrationSchedule(account.id, schedule, usk)
                        // [MOB-1496] W2: persist the just-committed schedule (the SDK keeps no
                        // proposal list post-commit) and reconcile so `stateEvents` picks up the
                        // fresh state promptly (a store completing a migration op is one of
                        // `reconcile()`'s two triggers).
                        await migrationManager.recordCommittedSchedule(account.id, schedule)
                        await migrationManager.reconcile()
                        await send(.scheduleSigned)
                    } catch {
                        await send(.noteSplitFailed)
                    }
                }

            case .delegate:
                return .none

            case .noteSplitFailed:
                state.isFailurePresented = true
                return .none

            case .onAppear:
                guard case .immediate = state.mode else { return .none }
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }

                return .run { send in
                    let schedule = (try? await sdkSynchronizer.proposeImmediateMigration(accountUUID))
                        ?? MigrationSchedule(transfers: [], estimatedDurationHours: 0)
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
    /// prefixed with the note-split PCZT when needed (MOB-1478 W4) — and hands the batch to the
    /// coordinator for QR signing. MOB-1496: see `MigrationTransferPlanStore`'s twin method for why
    /// the note-split PCZT rides under a `"note-split"` sentinel id (typed-payload mismatch between
    /// `proposeNoteSplitPCZT -> Data` and `proposeMigrationPCZTs -> [MigrationUnsignedTransferPczt]`)
    /// — same known gap: the signed side stores the whole batch through
    /// `storeSignedMigrationTransactions` rather than routing the split entry through the dedicated
    /// `storeSignedNoteSplitPCZT` path.
    private func requestKeystoneSignature(for schedule: MigrationSchedule, account: WalletAccount) -> Effect<Action> {
        .run { send in
            let needsNoteSplit = (try? await sdkSynchronizer.isNoteSplitNeeded(account.id)) ?? false
            var pczts: [MigrationUnsignedTransferPczt] = []
            if needsNoteSplit, let splitPczt = try? await sdkSynchronizer.proposeNoteSplitPCZT(account.id) {
                pczts.append(MigrationUnsignedTransferPczt(id: "note-split", pczt: splitPczt))
            }
            if let schedulePczts = try? await sdkSynchronizer.proposeMigrationPCZTs(account.id, schedule) {
                pczts.append(contentsOf: schedulePczts)
            }
            await send(.delegate(.keystoneSignRequested(pczts)))
        }
    }
}
