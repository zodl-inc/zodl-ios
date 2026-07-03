//
//  MigrationBackgroundDeliveryView.swift
//  zodl
//
//  "Allow Background Delivery" screen (MOB-1462, Figma S3 · 2840:4480). Visually complete per
//  Figma; `allowTapped` (Settings deep-link) and `scenePhaseActive` (BAR re-check) are declared but
//  inert — wiring them up lands in MOB-1466. The `skipTapped` delegate is emitted but consumed by
//  nobody yet.
//

import ComposableArchitecture
import SwiftUI

struct MigrationBackgroundDeliveryView: View {
    @Perception.Bindable var store: StoreOf<MigrationBackgroundDelivery>

    init(store: StoreOf<MigrationBackgroundDelivery>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizable: .migrationBackgroundDeliveryTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(localizable: .migrationBackgroundDeliveryDesc)
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

    // MARK: - Bullet rows

    @ViewBuilder private var bulletRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            MigrationBulletRow(
                icon: Asset.Assets.Icons.clockCheck.image,
                title: String(localizable: .migrationBackgroundDeliveryBullet1Title),
                caption: String(localizable: .migrationBackgroundDeliveryBullet1Desc)
            )

            MigrationBulletRow(
                icon: Asset.Assets.Icons.faceSmile.image,
                title: String(localizable: .migrationBackgroundDeliveryBullet2Title),
                caption: String(localizable: .migrationBackgroundDeliveryBullet2Desc)
            )

            MigrationBulletRow(
                icon: Asset.Assets.Icons.shieldTick.image,
                title: String(localizable: .migrationBackgroundDeliveryBullet3Title),
                caption: String(localizable: .migrationBackgroundDeliveryBullet3Desc)
            )
        }
    }

    // MARK: - Footer note

    @ViewBuilder private var footerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationBackgroundDeliveryFooter)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        MigrationBackgroundDeliveryView(
            store: StoreOf<MigrationBackgroundDelivery>(
                initialState: MigrationBackgroundDelivery.State()
            ) {
                MigrationBackgroundDelivery()
            }
        )
    }
}
