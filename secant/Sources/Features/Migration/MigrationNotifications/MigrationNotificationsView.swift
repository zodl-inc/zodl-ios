//
//  MigrationNotificationsView.swift
//  zodl
//
//  "Allow Notifications" screen (MOB-1462, Figma S4 scheduled · 2840:4728 / manual · 2867:1921).
//  Visually complete per Figma; `allowTapped` (notification authorization request) is declared but
//  inert — wiring it up lands in MOB-1466. The `skipTapped` delegate is emitted but consumed by
//  nobody yet.
//

import ComposableArchitecture
import SwiftUI

struct MigrationNotificationsView: View {
    @Perception.Bindable var store: StoreOf<MigrationNotifications>

    init(store: StoreOf<MigrationNotifications>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
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
                    .padding(.vertical, 1)
                }

                Spacer(minLength: 16)

                footerNote
                    .padding(.bottom, 16)

                ZashiButton(String(localizable: .migrationSkipOpenApp), type: .tertiary) {
                    store.send(.skipTapped)
                }
                .padding(.bottom, 12)

                ZashiButton(String(localizable: .migrationAllow)) {
                    store.send(.allowTapped)
                }
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .zashiBack()
        }
        .applyScreenBackground()
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

    @ViewBuilder private var footerNote: some View {
        let text: String = {
            switch store.variant {
            case .scheduled:
                return String(localizable: .migrationNotificationsFooterScheduled)
            case .manual:
                return String(localizable: .migrationNotificationsFooterManual)
            }
        }()

        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(text)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
