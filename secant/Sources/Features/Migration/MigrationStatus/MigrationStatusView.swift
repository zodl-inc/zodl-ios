//
//  MigrationStatusView.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). `onAppear` loads live rows via
//  the store; every other delegate emitted here is consumed by `MigrationCoordFlowCoordinator`
//  (phase 3). When `isFlowRoot` is set, the back control closes the flow instead of popping
//  (MOB-1466).
//
//  MOB-1478 (W7): `.rescheduleConfirmed(first:last:)` reuses this same screen for the post-reschedule
//  confirmation — title borrows `migrationPlanTitleConfirm`, body is `migrationStatusRescheduledDesc`,
//  and its "Got it" routes through the same `gotItTapped` exit as `.progress`. Row captions gained
//  two branches: `sentMinutesAgo` (sub-hour "Sent N min ago") ahead of the hours-based sent caption,
//  and `isBroadcasting` ("Sending now") ahead of the `.active` ETA caption — both fall back to
//  today's copy when unset/false.
//
//  MOB-1513 (C5, Figma resume frame 3491:10311): the `.plain` `ZashiInfoCallout` ("Transfer window
//  missed" / "Send now or reschedule to the next window.") that MOB-1497 (T8) added below the
//  timeline is REMOVED again — the resume frame shows only description, timeline, the sync-delay
//  footer note, and the buttons. `windowMissedNote` (the existing "Sending now will delay…" footer)
//  and the conditional Tor-hold note are unchanged: same copy, same position, same `.resume` gate.
//
//  MOB-1513 (A2): the shared timeline no longer relabels `store.rows`' own index 0 as "Split
//  Balance" — an ordinary transfer could be `index == 0` too (and, once actually sent, would have
//  wrongly rendered this screen's "Done"/green treatment below). This screen now passes the store's
//  synthesized `splitRow` in separately, ahead of `rows` (unchanged: every real transfer, numbered
//  1..N, its own status/caption untouched) — always COMPLETED, since post-commit the split has
//  definitely already broadcast.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationStatusView: View {
    @Perception.Bindable var store: StoreOf<MigrationStatus>

    init(store: StoreOf<MigrationStatus>) {
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

                        if let description {
                            Text(description)
                                .zFont(size: 14, style: Design.Text.tertiary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 24)
                        }

                        MigrationTransferTimeline(
                            rows: store.rows,
                            caption: caption(for:),
                            splitRow: store.splitRow,
                            skeletonPendingCaptions: store.isRescheduling,
                            captionStyle: { row in
                                // MOB-1511 (W4): the Split Balance row's "Done" renders green,
                                // matching its check badge; every other caption keeps the default.
                                row.kind == .splitBalance
                                    ? Design.Utility.SuccessGreen._600 as Colorable
                                    : Design.Text.tertiary
                            }
                        )
                    }
                    .padding(.vertical, 1)
                }

                if store.presentation == .resume {
                    VStack(alignment: .leading, spacing: 8) {
                        if store.isTorHoldActive {
                            torHoldNote
                        }
                        footerNote
                    }
                    .padding(.top, 16)
                }

                buttons
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .applyPresentationModifier(store: store)
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Title + description

    private var title: String {
        switch store.presentation {
        case .progress:
            return String(localizable: .migrationStatusTitle)
        case .resume:
            return store.isRescheduling
                ? String(localizable: .migrationStatusReschedulingTitle)
                : String(localizable: .migrationStatusResumeTitle)
        case .rescheduleConfirmed:
            return String(localizable: .migrationPlanTitleConfirm)
        }
    }

    /// `nil` hides the description entirely — reached only by `.progress` when
    /// `store.totalDurationHours` is unknown (a W1 fallback re-entry, MOB-1513): the sentence is a
    /// single fixed-shape localized string carrying the duration as a numeric argument, so there is
    /// no in-sentence placeholder ("—") to substitute without inventing new copy: omitting the
    /// whole line is the honest option that doesn't imply a false duration.
    private var description: String? {
        switch store.presentation {
        case .progress:
            guard let totalDurationHours = store.totalDurationHours else { return nil }
            return String(
                localizable: .migrationStatusDesc(store.rows.count, totalDurationHours, store.remainingCount)
            )
        case .resume:
            return String(
                localizable: .migrationStatusResumeDesc(store.stalledNumber, store.rows.count, store.stalledHoursAgo)
            )
        case .rescheduleConfirmed(let first, let last):
            return String(localizable: .migrationStatusRescheduledDesc(first, last))
        }
    }

    // MARK: - Caption

    private func caption(for row: MigrationTransferRow) -> String {
        // MOB-1511 (W4, Figma 3480:7638): the completed Split Balance row reads "Done" (green, via
        // `captionStyle` below) instead of a sent-ago timestamp — split completion is a state, not
        // an event the user tracks by time. MOB-1513 (A2): keyed off `kind` now, not `index == 0` —
        // an ordinary sent Transfer 1 must keep its own real "Sent Nh ago"/"Sent N min ago" caption
        // below, not this one.
        if row.kind == .splitBalance {
            return String(localizable: .migrationStatusDone)
        }
        switch row.status {
        case .sent:
            if let sentMinutesAgo = row.sentMinutesAgo {
                return String(localizable: .migrationStatusSentMinutesAgo(sentMinutesAgo))
            }
            return row.hoursFromNow == 0
                ? String(localizable: .migrationStatusSentRecently)
                : String(localizable: .migrationPlanSentAgo(row.hoursFromNow))
        case .overdue:
            // hoursFromNow is A3's forward ETA; overdue copy needs elapsed, which rows don't carry — 0 keeps it truthful-enough as "just overdue".
            return String(localizable: .migrationStatusOverdueAgo(0))
        case .active where row.isBroadcasting:
            // The single row actually being broadcast right now, as opposed to merely next-in-queue
            // (MOB-1478 W7) — same `.active` badge, distinct caption.
            return String(localizable: .migrationStatusSendingNow)
        default:
            // Pending/queued-active rows: the shared forward-ETA granularity per the frames
            // (S10-progress Transfer 4 = "~12 hours"). MOB-1513 (B3): a ready-now row now renders
            // "Ready now" (was the "~10 mins" `migrationPlanEtaFirst` fallback), bucketed by the same
            // `MigrationETA` helper every forward surface uses. MOB-1513 (A3): `minutesFromNow` now
            // carries the real, minute-precise ETA (the committed schedule's own per-transfer
            // height against the live tip) for rows backed by a committed schedule, so a sub-hour
            // transfer reads "in ~N mins" here too; it's nil only on the W1 progress-only fallback
            // (no committed schedule yet), where `forwardETAMinutes` falls back to `hoursFromNow`.
            return MigrationETA.caption(minutesFromNow: row.forwardETAMinutes, phrasing: .bare)
        }
    }

    // MARK: - Tor-hold note

    /// R7 final review, Important-1 (spec §G): shown ABOVE `footerNote` when `store.isTorHoldActive`
    /// — reuses `footerNote`'s exact row shape (info icon + tertiary caption) rather than inventing
    /// a new visual, per the fix's own "reuse the existing footerNote-style row" instruction.
    /// Flagged for the product/design pass — no Figma exists for this line (same caveat the
    /// `migrationFailure.*` failure-sheet copy carries).
    @ViewBuilder private var torHoldNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationFailureTorHoldStatusNote)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer note

    @ViewBuilder private var footerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationStatusWindowMissedNote(store.syncPrivacyBufferMinutes))
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buttons

    @ViewBuilder private var buttons: some View {
        switch store.presentation {
        case .progress, .rescheduleConfirmed:
            // `.rescheduleConfirmed`'s "Got it" routes through the same exit as `.progress`'s
            // (MOB-1478 W7).
            ZashiButton(String(localizable: .migrationGotIt)) {
                store.send(.gotItTapped)
            }
        case .resume:
            VStack(spacing: 8) {
                if store.isRescheduling {
                    ZashiButton(
                        String(localizable: .migrationStatusReschedulingTitle),
                        type: .tertiary,
                        prefixView: ProgressView()
                    ) {
                        store.send(.rescheduleTapped)
                    }
                    .disabled(true)
                } else {
                    ZashiButton(String(localizable: .migrationStatusReschedule), type: .secondary) {
                        store.send(.rescheduleTapped)
                    }
                }

                ZashiButton(String(localizable: .migrationStatusSendNow)) {
                    store.send(.sendNowTapped)
                }
                .disabled(store.isSendNowDisabled)
            }
        }
    }
}

// MARK: - Presentation modifier

private extension View {
    /// `.progress`'s back was already close-like (`zashiBackV2` sending `.gotItTapped`) before
    /// `isFlowRoot` existed — that stands unconditionally. `.resume`'s back is a plain pop unless
    /// this screen is the coordinator's re-entry root, in which case it closes the flow instead
    /// (MOB-1466 back-semantics: "when `isFlowRoot == false`, current behavior stands").
    /// `.rescheduleConfirmed` (MOB-1478 W7) falls through to that same plain-pop-or-close handling —
    /// it never needs `.progress`'s special close-wired arrow.
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationStatus>) -> some View {
        if store.presentation == .progress {
            zashiBackV2 {
                store.send(.gotItTapped)
            }
        } else if store.isFlowRoot {
            zashiBackV2 {
                store.send(.closeTapped)
            }
        } else {
            zashiBack()
        }
    }
}

// MARK: - Mock data

private extension IdentifiedArray where ID == MigrationTransferRow.ID, Element == MigrationTransferRow {
    /// The 6-transfer set from the "Final Designs" canvas (10.00 / 1.00 / 1.00 / 0.2 / 0.2 /
    /// 0.05 ZEC). MOB-1478 W7: Transfer 2 exercises sub-hour `sentMinutesAgo` ("Sent 18 min ago")
    /// and Transfer 3 exercises `isBroadcasting` ("Sending now"), matching the updated S10-progress
    /// frame.
    static var previewProgressRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(
                id: "1", index: 1, amount: Zatoshi(100_000_000), status: .sent, hoursFromNow: 0, sentMinutesAgo: 18
            ),
            MigrationTransferRow(
                id: "2", index: 2, amount: Zatoshi(100_000_000), status: .active, hoursFromNow: 0, isBroadcasting: true
            ),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }

    /// The resume/re-scheduling frame (Figma B8 · Migration in Progress): two sent, one overdue,
    /// three pending.
    static var previewResumeRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(100_000_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(100_000_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }

    /// The post-reschedule confirmation frame (MOB-1478 W7): the two already-sent transfers stand,
    /// Transfer 3 (the one that was stalled) is freshly re-windowed to a real ETA rather than
    /// "Sending now" — the reschedule only re-queues it, broadcasting hasn't started yet.
    static var previewRescheduleConfirmedRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(
                id: "1", index: 1, amount: Zatoshi(100_000_000), status: .sent, hoursFromNow: 0, sentMinutesAgo: 18
            ),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(100_000_000), status: .active, hoursFromNow: 6),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }
}

// MARK: - Previews

#Preview("Progress") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .progress,
                    rows: .previewProgressRows,
                    totalDurationHours: 24
                )
            ) {
                MigrationStatus()
            }
        )
    }
}

#Preview("Resume") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .resume,
                    rows: .previewResumeRows,
                    totalDurationHours: 24,
                    stalledNumber: 3,
                    stalledHoursAgo: 5
                )
            ) {
                MigrationStatus()
            }
        )
    }
}

#Preview("Re-scheduling") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .resume,
                    rows: .previewResumeRows,
                    totalDurationHours: 24,
                    stalledNumber: 3,
                    stalledHoursAgo: 5,
                    isRescheduling: true
                )
            ) {
                MigrationStatus()
            }
        )
    }
}

#Preview("Reschedule Confirmed") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .rescheduleConfirmed(first: 3, last: 6),
                    rows: .previewRescheduleConfirmedRows,
                    totalDurationHours: 24
                )
            ) {
                MigrationStatus()
            }
        )
    }
}
