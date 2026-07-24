//
//  MigrationTransferPlanView.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). `onAppear` loads a fresh proposal (or leaves an injected schedule alone)
//  via the store; `confirmTapped`'s delegate — `.confirmed` (software) or `.keystoneSignRequested`
//  (Keystone) — is consumed by `MigrationCoordFlowCoordinator` (MOB-1466 phase 3).
//
//  MOB-1478 (W4): `confirmTapped` now silently splits first when needed — a failure presents the
//  same Cancel/Retry bottom sheet `MigrationNoteSplit` uses (this screen had no failure path before).
//
//  MOB-1487: restyled to the Figma canvas "Final Designs" (frame 3508:11442 family) — the footer's
//  "Amounts are randomized" info row is removed (nothing sits between the list and Confirm in the
//  new mock); the timeline restyle itself (badge/connector/typography) lives in
//  `MigrationTransferTimeline`/`MigrationStepBadge`.
//
//  MOB-1494 (W6): `.sent` row captions gained minutes-level recency, mirroring
//  `MigrationStatusView`'s pattern (reusing its `migrationStatus.*` caption keys) — `row.sentMinutesAgo`
//  when set ("Sent N min ago"), else "Sent recently" for a same-hour sent row, else today's
//  hours-based caption. Variant-agnostic: any `.sent` row gets it, though only the `.recreated`
//  variant currently has any.
//
//  MOB-1497 (T4, Q3'26 canvas): the R13 broadcast-server disclosure footer (added in T2 for
//  provider users who reached this screen without seeing the Tor sheet's own disclosure line) is
//  retired per the new designs — the footer, its `disclosureFooter` builder, and the store's
//  `broadcastDisclosureHost` state are removed. Migration screens no longer name which server will
//  receive transfers.
//
//  MOB-1497 (T8, Q3'26 canvas, Figma 4207:7394): the MOB-1487 removal above turns out not to be
//  final — the Q3'26 canvas REINSTATES a footer between the list and Confirm, just with new copy
//  and a richer shape: `ZashiInfoCallout(style: .plain, ...)` ("Amounts randomized to reduce
//  linkability" / "...Confirm once — no per-transfer prompts.") replaces the old single-line
//  `migrationPlanRandomizedNote` row (whose key was already removed with it, so there's nothing to
//  orphan here).
//
//  MOB-1513 (C1, Figma 4207:7394): the footer T8 reinstated above is retired again — the same
//  frame, re-synced, now hides its Disclaimer layer in every Transfer Plan frame (scheduled/manual/
//  recreated alike), so nothing sits between the list and Confirm any more. `randomizedFooter` and
//  its call site are removed; the `migrationPlanRandomizedTitle`/`migrationPlanRandomizedBody`
//  string keys stay in the catalogue (removed separately, centrally).
//
//  MOB-1513 (A2): the shared timeline no longer relabels `store.rows`' own index 0 as "Split
//  Balance" — that let an ordinary crossing transfer masquerade as the split (wrong amount, its own
//  multi-hour ETA instead of "Ready now"), while the real note-split (broadcast at commit) had no
//  row of its own and real Transfer 1 was hidden. This screen now passes the store's synthesized
//  `splitRow` in separately, ahead of `rows` (unchanged: every real transfer, numbered 1..N with
//  its own real forward ETA). The `.recreated`-only hardcoded "Ready now" caption bypass below is
//  retired along with it — it only ever existed to paper over the same conflation for THAT variant;
//  every transfer row's caption is the real `forwardETA` now, on every variant.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationTransferPlanView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationTransferPlan>

    init(store: StoreOf<MigrationTransferPlan>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, store.round == nil ? 24 : 12)

                        // MOB-1511 (W2, Figma 4198:14325): the multi-round label — "Round N of M"
                        // once the engine estimate exists, "Round N" until then.
                        if let round = store.round {
                            Text(roundLabel(round: round, totalRounds: store.totalRounds))
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                .padding(.bottom, 24)
                        }

                        MigrationTransferTimeline(
                            rows: store.rows,
                            caption: caption(for:),
                            splitRow: store.splitRow
                        )
                    }
                    .padding(.vertical, 1)
                }

                // MOB-1513 (B4): disabled+spinner while the commit is in flight (the established
                // button-loading idiom — mirrors `SendConfirmationView`'s `isSending` button).
                if store.isConfirming {
                    ZashiButton(
                        String(localizable: .generalConfirm),
                        accessoryView:
                            ProgressView()
                            .progressViewStyle(
                                CircularProgressViewStyle(
                                    tint: Asset.Colors.secondary.color
                                )
                            )
                    ) { }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                    .disabled(store.isConfirming)
                } else {
                    ZashiButton(String(localizable: .generalConfirm)) {
                        store.send(.confirmTapped)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .zashiBack()
            .zashiSheet(isPresented: $store.isFailurePresented) {
                failureSheetContent
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Title + description

    private var title: String {
        switch store.variant {
        case .scheduled, .recreated:
            return String(localizable: .migrationPlanTitleConfirm)
        case .manual:
            return String(localizable: .migrationPlanTitleManual)
        }
    }

    private var description: String {
        let transferCount = store.rows.count

        switch store.variant {
        case .scheduled:
            return String(localizable: .migrationPlanDescScheduled(store.totalDurationHours))
        case .manual:
            return String(localizable: .migrationPlanDescManual(transferCount, store.totalDurationHours))
        case .recreated:
            return String(localizable: .migrationPlanDescRecreated(transferCount, store.totalDurationHours))
        }
    }

    // MARK: - Caption

    /// MOB-1511 (W2): "Round N of M" once the engine estimate exists, "Round N" until then.
    private func roundLabel(round: Int, totalRounds: Int?) -> String {
        if let totalRounds {
            return String(localizable: .migrationPlanRoundNOfM(round, totalRounds))
        }
        return String(localizable: .migrationPlanRoundN(round))
    }

    private func caption(for row: MigrationTransferRow) -> String {
        // MOB-1513 (A2): the split row always routes through the shared `MigrationETA.caption`
        // path below (its `minutesFromNow == 0` buckets to "Ready now") — never the `.recreated`
        // hardcoded bypass the `.active` case used to carry (see this file's header doc for why
        // that bypass is retired along with the row-0 relabel it existed to paper over).
        if row.kind == .splitBalance {
            return forwardETA(for: row)
        }
        switch row.status {
        case .sent:
            if let sentMinutesAgo = row.sentMinutesAgo {
                return String(localizable: .migrationStatusSentMinutesAgo(sentMinutesAgo))
            }
            return row.hoursFromNow == 0
                ? String(localizable: .migrationStatusSentRecently)
                : String(localizable: .migrationPlanSentAgo(row.hoursFromNow))
        default:
            return forwardETA(for: row)
        }
    }

    /// MOB-1513 (B3): the forward ETA, bucketed by the shared `MigrationETA` helper (Ready now / in
    /// ~N mins / in ~N hours) off the row's minute-precise `forwardETAMinutes` — replacing the old
    /// whole-hour `eta` that floored every future height to `0` and rendered the "~10 mins"
    /// (`migrationPlanEtaFirst`) fallback. Scheduled/fresh plans use the "in ~…" phrasing; recreated
    /// and manual plans keep the bare "~…" (frames differ — followed as drawn).
    private func forwardETA(for row: MigrationTransferRow) -> String {
        MigrationETA.caption(
            minutesFromNow: row.forwardETAMinutes,
            phrasing: store.variant == .scheduled ? .inPrefixed : .bare
        )
    }

    // MARK: - Failure sheet

    /// A `.propose` failure keeps this screen's own honest "couldn't load" copy; a `.commit` (or
    /// unset) failure renders the shared component's generic Cancel/Retry content. MOB-1513 (B4):
    /// the commit is sign-only now — no broadcast happens under Confirm, so `failureKind` is always
    /// `nil` here and the R14-R17 variants (whose buttons below are structurally unreachable no-ops)
    /// can never present on this screen. `zashiSheet`'s `content` closure isn't `@ViewBuilder`, so
    /// the dispatch lives in this ONE `@ViewBuilder` property instead.
    @ViewBuilder private var failureSheetContent: some View {
        if store.failureReason == MigrationTransferPlan.State.FailureReason.propose {
            proposeFailureSheetContent
        } else {
            MigrationBroadcastFailureSheetView(
                failureKind: nil,
                cancelTapped: { store.send(.cancelTapped) },
                proceedWithoutTorTapped: { },
                retryTapped: { store.send(.retryTapped) },
                useSyncServerTapped: { }
            )
        }
    }

    // MARK: - Failure sheet: propose failures only (MOB-1496 R8-T1, S3)

    /// A propose failure (`proposeMigrationTransfers()` threw — nothing was ever broadcast) uses
    /// honest "couldn't load" copy and a plain Cancel/Retry layout; it's never broadcast-related, so
    /// it never adopts the shared `MigrationBroadcastFailureSheetView` component (R9-T2, finding 3)
    /// the `.commit`-reason branch uses instead — see this screen's `body`.
    @ViewBuilder private var proposeFailureSheetContent: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(String(localizable: .migrationPlanProposeFailedTitle))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(String(localizable: .migrationPlanProposeFailedBody))
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                store.send(.cancelTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationNoteSplitRetry)) {
                store.send(.retryTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Mock data

private extension IdentifiedArray where ID == MigrationTransferRow.ID, Element == MigrationTransferRow {
    /// The 6-transfer set from the "Final Designs" canvas, frame 3508:11442 (10.00 / 1.00 / 1.00 /
    /// 0.2 / 0.2 / 0.05 ZEC). MOB-1513 (C2): Transfer 1 is `.pending`, not `.active` — this screen
    /// also shows the synthesized "Split Balance" row ahead of this list (see
    /// `MigrationTransferPlan.State.splitRow`), which now carries the current-step styling alone,
    /// even though Transfer 1's own ETA is a real "in ~6 hours" rather than "ready now" (nothing
    /// has actually started sending on this pre-commit screen).
    static var previewRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .pending, hoursFromNow: 6),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(100_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(100_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 24),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 30),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }

    /// The re-created variant's frame: two already sent, one active, two pending.
    static var previewRecreatedRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 17),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 0),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 6),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 12)
        ]
    }
}

// MARK: - Previews

#Preview("Scheduled") {
    NavigationView {
        MigrationTransferPlanView(
            store: StoreOf<MigrationTransferPlan>(
                initialState: MigrationTransferPlan.State(
                    variant: .scheduled,
                    rows: .previewRows,
                    totalDurationHours: 36
                )
            ) {
                MigrationTransferPlan()
            }
        )
    }
}

#Preview("Manual") {
    NavigationView {
        MigrationTransferPlanView(
            store: StoreOf<MigrationTransferPlan>(
                initialState: MigrationTransferPlan.State(
                    variant: .manual,
                    rows: .previewRows,
                    totalDurationHours: 36
                )
            ) {
                MigrationTransferPlan()
            }
        )
    }
}

#Preview("Recreated") {
    NavigationView {
        MigrationTransferPlanView(
            store: StoreOf<MigrationTransferPlan>(
                initialState: MigrationTransferPlan.State(
                    variant: .recreated,
                    rows: .previewRecreatedRows,
                    totalDurationHours: 12
                )
            ) {
                MigrationTransferPlan()
            }
        )
    }
}
