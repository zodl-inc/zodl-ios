//
//  MigrationStatusView.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). `onAppear` loads live rows via
//  the store; every other delegate emitted here is consumed by nobody yet — chaining is the
//  coordinator's job (phase 3). When `isFlowRoot` is set, the back control closes the flow instead
//  of popping (MOB-1466).
//
//  MOB-1478 (W7): `.rescheduleConfirmed(first:last:)` reuses this same screen for the post-reschedule
//  confirmation — title borrows `migrationPlanTitleConfirm`, body is `migrationStatusRescheduledDesc`,
//  and its "Got it" routes through the same `gotItTapped` exit as `.progress`. Row captions gained
//  two branches: `sentMinutesAgo` (sub-hour "Sent N min ago") ahead of the hours-based sent caption,
//  and `isBroadcasting` ("Sending now") ahead of the `.active` ETA caption — both fall back to
//  today's copy when unset/false.
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

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        MigrationTransferTimeline(
                            rows: store.rows,
                            caption: caption(for:),
                            skeletonPendingCaptions: store.isRescheduling
                        )
                    }
                    .padding(.vertical, 1)
                }

                if store.presentation == .resume {
                    footerNote
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

    private var description: String {
        switch store.presentation {
        case .progress:
            return String(
                localizable: .migrationStatusDesc(store.rows.count, store.totalDurationHours, store.remainingCount)
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
        switch row.status {
        case .sent:
            if let sentMinutesAgo = row.sentMinutesAgo {
                return String(localizable: .migrationStatusSentMinutesAgo(sentMinutesAgo))
            }
            return row.hoursFromNow == 0
                ? String(localizable: .migrationStatusSentRecently)
                : String(localizable: .migrationPlanSentAgo(row.hoursFromNow))
        case .overdue:
            return String(localizable: .migrationStatusOverdueAgo(row.hoursFromNow))
        case .active where row.isBroadcasting:
            // The single row actually being broadcast right now, as opposed to merely next-in-queue
            // (MOB-1478 W7) — same `.active` badge, distinct caption.
            return String(localizable: .migrationStatusSendingNow)
        default:
            // Pending/queued-active rows: "~Nh" ETA per the frames (S10-progress Transfer 4 =
            // "~12 hours"). A ready-now row renders "~10 mins", matching the Transfer Plan screen's
            // treatment.
            return row.hoursFromNow == 0
                ? String(localizable: .migrationPlanEtaFirst)
                : String(localizable: .migrationPlanEtaHours(row.hoursFromNow))
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
