//
//  MigrationNotificationsView.swift
//  zodl
//
//  "Allow Notifications" screen (MOB-1462, round-2 canvas "Final Designs" — Figma S4 scheduled ·
//  3480:9620 / manual · 3484:13186). `allowTapped` requests `UNUserNotificationCenter`
//  authorization via the store; either outcome, or `skipTapped`, sends the `.continued` delegate,
//  consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//

import ComposableArchitecture
import SwiftUI

struct MigrationNotificationsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationNotifications>

    init(store: StoreOf<MigrationNotifications>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // SCROLLER SHAPE: full-bleed ScrollView, `screenHorizontalPadding()` on its CONTENT
                // and on each pinned footer child — never on the column that holds the scroller.
                // See `MigrationEntryView` for the full note.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizable: .migrationNotificationsTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        bulletRows
                    }
                    .screenHorizontalPadding()
                    .padding(.vertical, 1)
                }

                Spacer(minLength: 16)

                footerNote
                    .screenHorizontalPadding()
                    .padding(.bottom, 16)

                skipButton
                    .screenHorizontalPadding()
                    .padding(.bottom, 12)

                ZashiButton(String(localizable: .migrationAllow)) {
                    store.send(.allowTapped)
                }
                .disabled(store.isProceeding)
                .screenHorizontalPadding()
                .padding(.bottom, 24)
            }
            .zashiBack()
        }
        .applyScreenBackground()
        .onAppear { store.send(.onAppear) }
    }

    // MARK: - Description

    private var description: String {
        switch store.variant {
        case .scheduled:
            return String(localizable: .migrationNotificationsDescScheduled)
        case .manual:
            return String(localizable: .migrationNotificationsDescManual)
        }
    }

    // MARK: - Bullet rows

    @ViewBuilder private var bulletRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch store.variant {
            case .scheduled:
                statusRow
                actionRow
                planRow
            case .manual:
                actionRow
                planRow
                statusRow
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        MigrationBulletRow(
            icon: Asset.Assets.Icons.annotationCheck.image,
            title: String(localizable: .migrationNotificationsStatusTitle),
            caption: String(localizable: .migrationNotificationsStatusDesc)
        )
    }

    @ViewBuilder private var actionRow: some View {
        let caption: String = {
            switch store.variant {
            case .scheduled:
                return String(localizable: .migrationNotificationsActionDescScheduled)
            case .manual:
                return String(localizable: .migrationNotificationsActionDescManual)
            }
        }()

        MigrationBulletRow(
            icon: Asset.Assets.Icons.bellRinging.image,
            title: String(localizable: .migrationNotificationsActionTitle),
            caption: caption
        )
    }

    @ViewBuilder private var planRow: some View {
        MigrationBulletRow(
            icon: Asset.Assets.Icons.announcement.image,
            title: String(localizable: .migrationNotificationsPlanTitle),
            caption: String(localizable: .migrationNotificationsPlanDesc)
        )
    }

    // MARK: - Footer note

    // Both variants render the same (scheduled) copy — the design no longer differentiates the
    // footer note by variant (MOB-1487; the `footerManual` key is retired from the catalog).
    @ViewBuilder private var footerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Utility.WarningYellow._700)

            Text(localizable: .migrationNotificationsFooterScheduled)
                .zFont(size: 12, style: Design.Utility.WarningYellow._700)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Skip button

    // `ZashiButton`'s `Type` enum has no per-instance color hook, so this reproduces a custom style
    // locally: the border and label stay on the `WarningYellow` ramp (`._300`/`._700`), but the fill
    // is `Design.Btns.Destructive1.bg` — Figma's `btn-destroy1-bg` token (adaptive white/near-black)
    // is applied to this fill across the whole canvas, the same token `ZashiButton`'s own
    // `.destructive1` type already uses for its background (MOB-1513; same override duplicated in
    // MigrationBackgroundDeliveryView rather than touching the shared component).
    @ViewBuilder private var skipButton: some View {
        Button {
            store.send(.skipTapped)
        } label: {
            Text(localizable: .migrationSkipOpenApp)
                .zFont(.semiBold, size: 16, style: Design.Utility.WarningYellow._700)
                .fixedSize()
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Design.Btns.Destructive1.bg.color(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .stroke(Design.Utility.WarningYellow._300.color(colorScheme), lineWidth: 1)
                        }
                }
        }
    }
}

// MARK: - Previews

#Preview("Scheduled") {
    NavigationView {
        MigrationNotificationsView(
            store: StoreOf<MigrationNotifications>(
                initialState: MigrationNotifications.State(variant: .scheduled)
            ) {
                MigrationNotifications()
            }
        )
    }
}

#Preview("Manual") {
    NavigationView {
        MigrationNotificationsView(
            store: StoreOf<MigrationNotifications>(
                initialState: MigrationNotifications.State(variant: .manual)
            ) {
                MigrationNotifications()
            }
        )
    }
}
