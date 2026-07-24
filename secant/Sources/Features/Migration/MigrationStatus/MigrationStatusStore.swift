//
//  MigrationStatusStore.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). `onAppear` loads rows/summary
//  via `migrationTransfers()`/`migrationSummary()` and subscribes `migrationManager.stateEvents(_:)`
//  to refresh rows live (MOB-1466).
//  When this screen is a flow re-entry root (`isFlowRoot`), its back control closes the flow
//  (`.done`) instead of popping — every other delegate is consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1478 (W7): rows can now carry sub-hour sent recency (`sentMinutesAgo`) and a broadcasting
//  flag (`isBroadcasting`) — both just ride along through `statusLoaded`/`migrationStateChanged`
//  unchanged; the View derives their captions. `.rescheduleConfirmed(first:last:)` is a new
//  presentation reached via the public `rescheduleCompleted` action, landing on this same screen
//  instead of flipping `isRescheduling` back to `.resume`. The reschedule effect itself (SDK
//  reschedule + background-window scheduling) still runs in `MigrationCoordFlowCoordinator`, which
//  today pushes a fresh `TransferPlan` screen on completion instead — wiring it to send
//  `rescheduleCompleted` here is a later phase.
//
//  R8-T6 (V8 fix): the Send-now CTA no longer consults `manager.sendGate()` — the 600s app-side
//  sync<->send privacy gate re-arms on EVERY sync completion, and the SDK re-emits a syncing-
//  >upToDate edge every ~10-30s while foregrounded, so the gate was almost never `.allowed` in
//  normal use (chicken-and-egg: sync only stops AFTER a "Send now" tap). `isSendNowDisabled` is now
//  computed straight off `rows` — an `.overdue` row is the SAME "there's a stalled transfer" signal
//  `reentryRoute`/`statusResumeState` already use to route to this screen's `.resume` presentation
//  in the first place, so due-ness alone (not the gate) governs the CTA. The gate is still
//  enforced — just later, inside `MigrationSendingStore`'s Send-now lane, which shows a
//  silence-window wait (stop sync -> countdown -> broadcast) instead of leaving the CTA disabled.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationStatus {
    @ObservableState
    struct State: Equatable {
        enum Presentation: Equatable {
            case progress
            case resume
            /// Post-reschedule confirmation (MOB-1478 W7): entered via `rescheduleCompleted` instead
            /// of flipping back to `.resume`. `first`/`last` are the stalled-range transfer numbers
            /// ("Transfers {first}-{last}") captured from `.resume`'s `stalledNumber`/`rows.count` at
            /// the moment of transition.
            case rescheduleConfirmed(first: Int, last: Int)
        }

        var presentation = Presentation.progress
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        /// The schedule's total remaining-duration estimate. `nil` when not derivable — a W1
        /// fallback re-entry with no persisted schedule yet (MOB-1513) — never a placeholder `0`;
        /// the `.progress` description omits its duration clause when this is `nil` (see
        /// `MigrationStatusView.description`).
        var totalDurationHours: Int?
        /// Resume header: "Transfer {n} of {m} …".
        var stalledNumber = 0
        var stalledHoursAgo = 0
        /// Visual-only: skeleton captions + disabled spinner button on the resume presentation.
        var isRescheduling = false
        /// True when this screen is the coordinator's re-entry root (both presentations) — its back
        /// control then closes the flow instead of popping.
        var isFlowRoot = false
        /// MOB-1497 (R7 final review, Important-1 — spec §G): true iff the selected account's most
        /// recent broadcast failure was a mid-run Tor hold — carries the Tor-specific line on the
        /// `.resume` presentation (see `MigrationStatusView.torHoldNote`). Loaded both via
        /// `.statusLoaded` (live, re-derived on every load/state-change tick) and the coordinator's
        /// re-entry hydration (`MigrationCoordFlowCoordinator.statusResumeState`/
        /// `statusProgressState`). (Rebased onto R8-T6: `isSendNowDisabled` is COMPUTED off `rows`
        /// now, so this is the one stored per-load flag left here.)
        var isTorHoldActive = false
        /// MOB-1496 (W3): the SDK's post-broadcast privacy buffer
        /// (`sdkSynchronizer.migrationPrivacySyncBufferDuration()`), rounded to whole minutes —
        /// threads the resume footer's "…about %1$lld mins…" copy (`migrationStatusWindowMissedNote`)
        /// off the SDK's real value instead of a hardcoded "10". `0` until `statusLoaded` arrives.
        var syncPrivacyBufferMinutes = 0
        var cancelStateStreamId = UUID()
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var remainingCount: Int {
            rows.filter { $0.status != .sent }.count
        }

        /// R8-T6 (V8 fix): due-ness alone governs the Send-now CTA now — an `.overdue` row is the
        /// SAME signal `reentryRoute`'s `hasOverdue` check already uses to route to this screen's
        /// `.resume` presentation, so this stays consistent with "why am I even seeing this button"
        /// without a separate gate consult (see this file's header doc for the full V8 writeup).
        /// Computed off `rows` (same idiom as `remainingCount` above) rather than stored, so it
        /// can never go stale between a `statusLoaded`/`migrationStateChanged` refresh and a read.
        var isSendNowDisabled: Bool {
            !rows.contains { $0.status == MigrationTransferRow.Status.overdue }
        }

        /// MOB-1513 (A2): mirrors `MigrationTransferPlan.State.splitRow` for this post-commit
        /// screen — but COMPLETED (`.sent`) rather than merely ready, since by the time any
        /// Status/Resume/reschedule-confirmed presentation is reachable the note-split has
        /// definitely already broadcast (a precondition of scheduling any transfer at all — see
        /// `MigrationTransferTimeline`'s header doc for the shared-component side of this fix).
        /// `nil` before any rows have loaded. Computed off `rows` (not stored) so it can never
        /// drift from whatever `rows` currently holds — including the coordinator's own re-entry
        /// hydration (`statusResumeState`/`statusProgressState`), which constructs `rows` directly
        /// without going through `.statusLoaded` — and so it doesn't force every
        /// `.statusLoaded`/`.rescheduleCompleted` call site (and every existing exhaustive
        /// `TestStore` assertion) to separately track a parallel stored field.
        var splitRow: MigrationTransferRow? {
            guard !rows.isEmpty else { return nil }
            // MOB-1513: `rows` can now be a W1-fallback derivation (no committed schedule — every
            // row's `amount` is `nil` on that path) — the sum stays honest: `nil` (unknown total)
            // if ANY row's amount is, rather than silently treating an unknown row as zero.
            let totalAmount: Zatoshi? = rows.contains { $0.amount == nil }
                ? nil
                : rows.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }
            return MigrationTransferRow(
                id: "split-balance",
                index: -1,
                amount: totalAmount,
                status: .sent,
                hoursFromNow: 0,
                kind: .splitBalance
            )
        }

        init(
            presentation: Presentation = .progress,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int? = nil,
            stalledNumber: Int = 0,
            stalledHoursAgo: Int = 0,
            isRescheduling: Bool = false,
            isFlowRoot: Bool = false
        ) {
            self.presentation = presentation
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.stalledNumber = stalledNumber
            self.stalledHoursAgo = stalledHoursAgo
            self.isRescheduling = isRescheduling
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        /// Flow-root back control: closes the flow instead of popping.
        case closeTapped
        /// Progress CTA and the X close.
        case gotItTapped
        case delegate(Delegate)
        /// `migrationManager.stateEvents(_:)` ticked — reloads rows/summary.
        case migrationStateChanged
        case onAppear
        /// Public: the coordinator's reschedule effect (SDK reschedule + first-window scheduling)
        /// finished — lands on `.rescheduleConfirmed` with the refreshed rows/duration instead of
        /// flipping `isRescheduling` back to `.resume`. The coordinator doesn't send this yet (it
        /// still pushes a fresh `TransferPlan` screen on completion) — wiring it up is a later phase;
        /// this action is the store-side surface for it (MOB-1478 W7).
        case rescheduleCompleted(rows: [MigrationTransferRow], totalDurationHours: Int?)
        case rescheduleTapped
        case sendNowTapped
        /// `migrationTransfers()` + `migrationSummary()` + `sdkSynchronizer
        /// .migrationPrivacySyncBufferDuration()` + `manager.isMigrationTorHoldActive()` result.
        /// R8-T6: no longer carries a gate reading — `isSendNowDisabled` is derived from `rows`
        /// itself (see `State.isSendNowDisabled`'s doc).
        case statusLoaded(
            rows: [MigrationTransferRow],
            totalDurationHours: Int?,
            syncPrivacyBufferMinutes: Int,
            isTorHoldActive: Bool
        )

        enum Delegate: Equatable {
            case done
            case reschedule
            case sendNow
        }
    }

    @Dependency(\.migrationManager) var migrationManager
    // MOB-1496 (W3): `migrationPrivacySyncBufferDuration()` for the resume footer's minutes copy —
    // hydrated here (the store already reads dependencies) rather than adding a dependency to the
    // View.
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.done))

            case .gotItTapped:
                return .send(.delegate(.done))

            case .delegate:
                return .none

            case .migrationStateChanged:
                return loadStatus(accountUUID: state.selectedWalletAccount?.id)

            case .onAppear:
                let accountUUID = state.selectedWalletAccount?.id
                return .merge(
                    loadStatus(accountUUID: accountUUID),
                    .publisher {
                        migrationManager.stateEvents(accountUUID)
                            .map { _ in Action.migrationStateChanged }
                    }
                    .cancellable(id: state.cancelStateStreamId, cancelInFlight: true)
                )

            case .rescheduleCompleted(let rows, let totalDurationHours):
                state.presentation = .rescheduleConfirmed(first: state.stalledNumber, last: state.rows.count)
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.isRescheduling = false
                return .none

            case .rescheduleTapped:
                state.isRescheduling = true
                return .send(.delegate(.reschedule))

            case .sendNowTapped:
                return .send(.delegate(.sendNow))

            case .statusLoaded(let rows, let totalDurationHours, let syncPrivacyBufferMinutes, let isTorHoldActive):
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.syncPrivacyBufferMinutes = syncPrivacyBufferMinutes
                state.isTorHoldActive = isTorHoldActive
                return .none
            }
        }
    }

    private func loadStatus(accountUUID: AccountUUID?) -> Effect<Action> {
        .run { send in
            let rows = await migrationManager.migrationTransfers(accountUUID)
            let summary = await migrationManager.migrationSummary(accountUUID)
            let syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
                from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
            )
            let isTorHoldActive = migrationManager.isMigrationTorHoldActive(accountUUID)
            await send(
                .statusLoaded(
                    rows: rows,
                    totalDurationHours: summary.estimatedDurationHours,
                    syncPrivacyBufferMinutes: syncPrivacyBufferMinutes,
                    isTorHoldActive: isTorHoldActive
                )
            )
        }
    }
}

extension MigrationStatus {
    /// MOB-1496 (W3 review fix C): shared formula for `State.syncPrivacyBufferMinutes` — this
    /// store's own `loadStatus()` and `MigrationCoordFlowCoordinator`'s re-entry hydration
    /// (`statusResumeState`/`statusProgressState`) both compute it from the SDK's raw
    /// `migrationPrivacySyncBufferDuration()`; extracted to one spot so the two can't drift.
    static func syncPrivacyBufferMinutes(from duration: TimeInterval) -> Int {
        Int((duration / 60).rounded())
    }
}
