//
//  MigrationStatusView.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). Visually complete per Figma;
//  every delegate emitted here is consumed by nobody yet — wiring the real reschedule/send-now
//  behavior and chaining into the rest of the migration flow lands in MOB-1466.
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
        }
    }

    // MARK: - Caption

    private func caption(for row: MigrationTransferRow) -> String {
        switch row.status {
        case .sent:
            return row.hoursFromNow == 0
                ? String(localizable: .migrationStatusSentRecently)
                : String(localizable: .migrationPlanSentAgo(row.hoursFromNow))
        case .overdue:
            return String(localizable: .migrationStatusOverdueAgo(row.hoursFromNow))
        default:
            // Pending/active rows: "~Nh" ETA per the frames (S10-progress Transfer 3 = "~6 hours").
            return String(localizable: .migrationPlanEtaHours(row.hoursFromNow))
        }
    }

    // MARK: - Footer note

    @ViewBuilder private var footerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationStatusWindowMissedNote)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buttons

    @ViewBuilder private var buttons: some View {
        switch store.presentation {
        case .progress:
            ZashiButton(String(localizable: .migrationGotIt)) {
                store.send(.gotItTapped)
            }
        case .resume:
            VStack(spacing: 8) {
                if store.isRescheduling {
                    ZashiButton(
                        String(localizable: .migrationStatusReschedulingTitle),
                        type: .tertiary,
                        accessoryView: ProgressView()
                    ) {
                        store.send(.rescheduleTapped)
                    }
                    .disabled(true)
                } else {
                    ZashiButton(String(localizable: .migrationStatusReschedule), type: .ghost) {
                        store.send(.rescheduleTapped)
                    }
                }

                ZashiButton(String(localizable: .migrationStatusSendNow)) {
                    store.send(.sendNowTapped)
                }
            }
        }
    }
}

// MARK: - Presentation modifier

private extension View {
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationStatus>) -> some View {
        if store.presentation == .progress {
            zashiBackV2 {
                store.send(.gotItTapped)
            }
        } else {
            zashiBack()
        }
    }
}

// MARK: - Mock data

private extension IdentifiedArray where ID == MigrationTransferRow.ID, Element == MigrationTransferRow {
    /// The 5-transfer set from the Figma frames (3.51220 / 2.87410 / 2.43100 / 1.99830 / 1.64240 ZEC).
    static var previewProgressRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 6),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 18)
        ]
    }

    /// The resume/re-scheduling frame: two sent, one overdue, two pending.
    static var previewResumeRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 11),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 1),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 7)
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
