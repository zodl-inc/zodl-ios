//
//  MigrationBackgroundDeliveryView.swift
//  zodl
//
//  "Allow Background Delivery" — explains background sending and requests notification authorization.
//

import ComposableArchitecture
import SwiftUI

struct MigrationBackgroundDeliveryView: View {
    @Perception.Bindable var store: StoreOf<MigrationBackgroundDelivery>
    let tokenName: String

    init(store: StoreOf<MigrationBackgroundDelivery>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(localizable: .migrationBgDeliveryTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.top, 24)

                        VStack(alignment: .leading, spacing: 20) {
                            bulletRow(
                                icon: Asset.Assets.Icons.flashOn.image,
                                title: String(localizable: .migrationBgDeliveryBullet1Title),
                                subtitle: String(localizable: .migrationBgDeliveryBullet1Subtitle)
                            )

                            bulletRow(
                                icon: Asset.Assets.Icons.checkVerified.image,
                                title: String(localizable: .migrationBgDeliveryBullet2Title),
                                subtitle: String(localizable: .migrationBgDeliveryBullet2Subtitle)
                            )

                            bulletRow(
                                icon: Asset.Assets.Icons.swapArrows.image,
                                title: String(localizable: .migrationBgDeliveryBullet3Title),
                                subtitle: String(localizable: .migrationBgDeliveryBullet3Subtitle)
                            )
                        }

                        Text(localizable: .migrationBgDeliveryDisclaimer)
                            .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }

                VStack(spacing: 8) {
                    ZashiButton(String(localizable: .migrationBgDeliverySkip), type: .secondary) {
                        store.send(.skipTapped)
                    }

                    ZashiButton(String(localizable: .migrationBgDeliveryAllow)) {
                        store.send(.allowTapped)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
        }
        .applyScreenBackground()
    }

    private func bulletRow(icon: Image, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            icon
                .zImage(size: 20, style: Design.Text.primary)
                .frame(width: 28, height: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(subtitle)
                    .zFont(.regular, size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
