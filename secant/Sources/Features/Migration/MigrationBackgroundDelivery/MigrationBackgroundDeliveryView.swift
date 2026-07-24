//
//  MigrationBackgroundDeliveryView.swift
//  zodl
//
//  "Allow Background Delivery" screen (MOB-1462, round-2 canvas "Final Designs" — Figma S3 ·
//  3484:12873). `allowTapped` opens the Settings deep-link; `scenePhaseActive` re-checks Background
//  App Refresh on return and the store auto-advances once it's available (MOB-1466). The
//  `skipTapped` delegate is consumed by `MigrationCoordFlowCoordinator` (phase 3).
//

import ComposableArchitecture
import SwiftUI

struct MigrationBackgroundDeliveryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
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

                skipButton
                    .padding(.bottom, 12)

                ZashiButton(String(localizable: .migrationAllow)) {
                    store.send(.allowTapped)
                    if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settingsUrl)
                    }
                }
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .zashiBack()
        }
        .applyScreenBackground()
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                store.send(.scenePhaseActive)
            }
        }
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
                .zImage(size: 16, style: Design.Utility.WarningYellow._700)

            Text(localizable: .migrationBackgroundDeliveryFooter)
                .zFont(size: 12, style: Design.Utility.WarningYellow._700)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Skip button

    // `ZashiButton`'s `Type` enum has no per-instance color hook, so this reproduces a custom style
    // locally: fill, border, and label are all `WarningYellow` ramp steps — the dark mock binds the
    // fill to `._50` too, so this is no longer a `Destructive1` hybrid (MOB-1478 W8; round-2 fill
    // update MOB-1487; MOB-1487 R3 dark pass; same override duplicated in MigrationNotificationsView
    // rather than touching the shared component).
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
                        .fill(Design.Utility.WarningYellow._50.color(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .stroke(Design.Utility.WarningYellow._300.color(colorScheme), lineWidth: 1)
                        }
                }
        }
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
