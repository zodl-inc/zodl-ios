//
//  MigrationBulletRow.swift
//  zodl
//
//  Shared bullet row for migration permission screens (MOB-1462): a bare icon 20 pt
//  `Design.Text.primary` in a 24 pt frame, top-aligned, next to a medium-weight title and a
//  tertiary caption. Generalizes the `outcomeRow` pattern from the since-deleted
//  MigrationNetworkPrivacyView. Used by MigrationBackgroundDelivery, MigrationNotifications, and
//  (MOB-1478) MigrationHowItWorks.
//

import SwiftUI

struct MigrationBulletRow: View {
    let icon: Image
    let title: String
    let caption: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .zImage(size: 20, style: Design.Text.primary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(caption)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        MigrationBulletRow(
            icon: Asset.Assets.Icons.clockCheck.image,
            title: "Transfers send at their scheduled windows",
            caption: "Zodl wakes up and sends each transfer at its scheduled time — no action needed."
        )

        MigrationBulletRow(
            icon: Asset.Assets.Icons.faceSmile.image,
            title: "No need to open the app for each send",
            caption: "Once the schedule is committed, all transfers are sent in the background."
        )

        MigrationBulletRow(
            icon: Asset.Assets.Icons.shieldTick.image,
            title: "Sends on a fixed schedule, not your activity",
            caption: "Transfers go out at set network-wide times, so they're not linked to when you open Zodl."
        )
    }
    .screenHorizontalPadding()
}
