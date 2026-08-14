//
//  MigrationLeaveGuardSheet.swift
//  zodl
//
//  "Your migration hasn't started yet" (MOB-1466, field finding O5) — presented over the
//  PRE-COMMIT Transfer Plan screen when the toolbar back button is tapped before Confirm has done
//  anything. See `MigrationTransferPlanStore`'s `.backTapped` doc for the guard's exact trigger
//  condition and its two silent pass-through carve-outs.
//
//  A plain `View`, holding no state — presented through `zashiSheet` by
//  `MigrationTransferPlanView`, matching `SendOrchardWarningSheet`. Unlike that sheet (a genuine
//  fund-safety warning, hence its red alert icon), nothing here is actually at risk — leaving loses
//  no funds and schedules nothing — so this carries no icon, mirroring the plain informational
//  header `MigrationPrepareBalanceSheet` (the other sheet on this same screen) uses.
//
//  Button weight is deliberate, same convention as `SendOrchardWarningSheet` and this screen's own
//  `proposeFailureSheetContent`: the encouraged action ("Keep reviewing") is the PRIMARY (dark,
//  bottom) button; "Leave anyway" is the de-emphasized secondary one, above it — present, never
//  hidden or disabled, but not the nudge.
//

import SwiftUI

struct MigrationLeaveGuardSheet: View {
    let stayTapped: () -> Void
    let leaveTapped: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(String(localizable: .migrationPlanLeaveGuardTitle))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 32)
                .padding(.bottom, 12)

            Text(String(localizable: .migrationPlanLeaveGuardBody))
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .migrationPlanLeaveGuardLeave), type: .secondary) {
                leaveTapped()
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationPlanLeaveGuardStay)) {
                stayTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Previews

#Preview {
    MigrationLeaveGuardSheet(stayTapped: { }, leaveTapped: { })
        .screenHorizontalPadding()
}

#Preview("Dark") {
    MigrationLeaveGuardSheet(stayTapped: { }, leaveTapped: { })
        .screenHorizontalPadding()
        .preferredColorScheme(.dark)
}
