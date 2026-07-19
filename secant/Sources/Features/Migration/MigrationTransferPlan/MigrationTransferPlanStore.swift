//
//  MigrationTransferPlanStore.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). One-time review of the migration schedule before signing: a timeline of
//  transfer rows, each showing its amount, status, and ETA. A fresh entry proposes its own schedule
//  on `onAppear`; a recovery/reschedule variant instead has its schedule injected by the coordinator
//  (`injectedSchedule`) and must not re-propose. `confirmTapped` signs and stores whichever schedule
//  is active, unless `requiresSigning == false` (the rescheduled variant, whose transfers are
//  already signed), in which case it's a plain acknowledgment (MOB-1466). Chaining the
//  `confirmTapped` delegate into the rest of the flow is `MigrationCoordFlow`'s job.
//
//  MOB-1468 (Keystone): a Keystone-vendor account with `requiresSigning == true` (fresh + re-created
//  plans) forks `confirmTapped` — instead of signing+storing locally, it proposes the schedule's
//  PCZTs (`proposeMigrationPCZTs(schedule)`) and delegates `.keystoneSignRequested(pczts)` for the
//  coordinator to route through `MigrationKeystoneSign` + `Scan` in ONE batched session. The software
//  path and the rescheduled `requiresSigning == false` variant (never re-signs) are unchanged.
//
//  MOB-1478 (W4): note splitting runs silently under this screen's commit, right before signing —
//  `.confirmTapped`/`.retryTapped` share one effect: iff `isNoteSplitNeeded()`, `prepareNoteSplit` +
//  `submitNoteSplit` first (mirrors `MigrationNoteSplitStore`'s old explainer-confirm sequence 1:1);
//  a split failure presents the same Cancel/Retry failure sheet `MigrationNoteSplit` uses (this
//  screen had none before) instead of proceeding to sign+store. The Keystone fork's batch
//  (`requestKeystoneSignature`) now proposes the note-split PCZT first too, when needed, so the WHOLE
//  batch (split + all N transfers) signs in the same QR ceremony — `storeSignedMigrationTransactions`
//  stores the whole `[MigrationSignedTransferPczt]` array atomically, so the no-partial-storage
//  invariant holds unchanged (MOB-1496: see `requestKeystoneSignature`'s doc for the note-split
//  PCZT's sentinel-id wrapping, needed since it's typed differently — raw `Data` — from the
//  schedule's own PCZTs). `MigrationNoteSplit` itself no longer requests Keystone signing
//  (re-entry-only now).
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationTransferPlan {
    @ObservableState
    struct State: Equatable {
        enum Variant: Equatable {
            case scheduled
            case manual
            case recreated
        }

        var variant = Variant.scheduled
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        var totalDurationHours = 0
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion?
        /// Coordinator-injected schedule for recovery/reschedule variants — when set, `onAppear`
        /// populates rows from it directly instead of calling `proposeMigrationTransfers()`.
        var injectedSchedule: MigrationSchedule?
        /// The schedule currently backing `rows` (either `injectedSchedule` or a freshly proposed
        /// one) — what `confirmTapped` signs and stores.
        var schedule: MigrationSchedule?
        /// `false` for the rescheduled variant only (MOB-1466): its transfers are already signed at
        /// the original plan commit, so `confirmTapped` is a plain acknowledgment — `false` skips
        /// `signAndStoreMigrationSchedule` and delegates `.confirmed` directly. The re-created
        /// (recovery) variant signs a fresh schedule, so it keeps the default `true`.
        var requiresSigning = true
        /// MOB-1478 (W4): failure sheet for the silent note-split step, presented over this screen
        /// instead of proceeding to sign+store — mirrors `MigrationNoteSplit.State.isFailurePresented`.
        var isFailurePresented = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(
            variant: Variant = .scheduled,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int = 0,
            requiresSigning: Bool = true
        ) {
            self.variant = variant
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.requiresSigning = requiresSigning
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Signs and stores the active schedule (silently splitting first, when needed).
        case confirmTapped
        case delegate(Delegate)
        /// MOB-1478 (W4): the silent split step failed — presents the failure sheet instead of
        /// proceeding to sign+store.
        case noteSplitFailed
        case onAppear
        /// Failure sheet: dismiss, then re-attempt `confirmTapped`'s whole effect from scratch.
        case retryTapped
        /// `signAndStoreMigrationSchedule` completed.
        case scheduleSigned
        /// `proposeMigrationTransfers()` result — populates rows/duration for a fresh entry.
        case transfersProposed(MigrationSchedule)

        enum Delegate: Equatable {
            case confirmed
            /// MOB-1468 (Keystone): the schedule's PCZTs (ALL N transfers, plus the note-split PCZT
            /// first when needed — MOB-1478 W4) were proposed and need QR signing in ONE batched
            /// session — the shared shape across the Keystone signing sources so the coordinator can
            /// treat them symmetrically. MOB-1496: the note-split PCZT (raw `Data`) rides along
            /// wrapped under a `"note-split"` sentinel id — see `requestKeystoneSignature`'s doc.
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

            case .confirmTapped, .retryTapped:
                state.isFailurePresented = false

                guard state.requiresSigning else {
                    // Rescheduled variant: transfers are already signed — this is acknowledgment.
                    return .send(.delegate(.confirmed))
                }

                let schedule = state.schedule ?? MigrationSchedule(transfers: [], estimatedDurationHours: 0)
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
                            let options = await migrationManager.migrationNetworkOptions(account.id)
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
                if let injectedSchedule = state.injectedSchedule {
                    apply(injectedSchedule, to: &state)
                    return .none
                }

                // Coordinator-hydrated rows (the rescheduled variant — no schedule object exists
                // for it) must not be overwritten by a fresh proposal.
                if !state.rows.isEmpty {
                    return .none
                }

                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }

                // [MOB-1496] W6 wires the residual choice — `includeResidual` hardcoded `false`
                // pending that. This screen is only ever reached for `.privateScheduled` mode (the
                // coordinator routes `.immediate` through `MigrationReviewTransfer` instead), so
                // `proposeMigrationTransfers` (not `proposeImmediateMigration`) is always correct
                // here.
                return .run { send in
                    let schedule = (try? await sdkSynchronizer.proposeMigrationTransfers(accountUUID, false))
                        ?? MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                    await send(.transfersProposed(schedule))
                }

            case .scheduleSigned:
                return .send(.delegate(.confirmed))

            case .transfersProposed(let schedule):
                apply(schedule, to: &state)
                return .none
            }
        }
    }

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes ALL of the schedule's PCZTs — prefixed with
    /// the note-split PCZT when needed (MOB-1478 W4), so the whole batch signs in one QR ceremony —
    /// and hands them to the coordinator for that ONE batched QR-signing session.
    ///
    /// MOB-1496: the real SDK types the note-split PCZT (`proposeNoteSplitPCZT -> Data`) and the
    /// schedule's transfer PCZTs (`proposeMigrationPCZTs -> [MigrationUnsignedTransferPczt]`)
    /// differently — unlike the pre-real-SDK stub, where both were the same opaque `Pczt` blob and
    /// could be concatenated directly. The note-split PCZT is wrapped under a `"note-split"`
    /// sentinel id so it can still ride in the same typed batch/QR ceremony; on the signed side,
    /// the WHOLE batch (including that entry) is stored via one `storeSignedMigrationTransactions`
    /// call (`MigrationCoordFlowCoordinator`'s `.scan(.foundPCZTBatch)`/`.simulateSignature`
    /// handlers) — the engine does not yet special-case the sentinel entry back onto the dedicated
    /// `storeSignedNoteSplitPCZT` path. Known gap, called out in the task report; the software path
    /// above (which DOES route the split through `submitNoteSplit` correctly) is unaffected.
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

    /// Populates `rows`/`totalDurationHours`/`schedule` from a `MigrationSchedule`, whether it was
    /// freshly proposed or injected by the coordinator. The first transfer is `.active` (ready now);
    /// the rest are `.pending`. `hoursFromNow` comes from `estimateTimestamp` where the SDK can
    /// resolve a height to a timestamp; unresolved (incl. the inert stub) defaults to `0`.
    private func apply(_ schedule: MigrationSchedule, to state: inout State) {
        state.rows = IdentifiedArrayOf(
            uniqueElements: schedule.transfers.enumerated().map { index, transfer in
                MigrationTransferRow(
                    id: transfer.id,
                    index: index,
                    amount: transfer.amount,
                    status: index == 0 ? .active : .pending,
                    hoursFromNow: hoursFromNow(forHeightReadyAt: transfer.nextExecutableAfterHeight)
                )
            }
        )
        state.totalDurationHours = schedule.estimatedDurationHours
        state.schedule = schedule
    }

    private func hoursFromNow(forHeightReadyAt height: BlockHeight) -> Int {
        guard let readyTimestamp = sdkSynchronizer.estimateTimestamp(height) else { return 0 }

        let seconds = Date(timeIntervalSince1970: readyTimestamp).timeIntervalSinceNow
        return max(0, Int(seconds / 3_600))
    }
}
