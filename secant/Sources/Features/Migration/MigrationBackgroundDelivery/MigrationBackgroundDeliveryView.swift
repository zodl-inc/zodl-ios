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
                        Text("Allow Background Delivery")
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.top, 24)

                        VStack(alignment: .leading, spacing: 20) {
                            bulletRow(
                                icon: "bolt.fill",
                                title: "Transfers send automatically",
                                subtitle: "Your device wakes up and broadcasts each transfer at its scheduled window."
                            )

                            bulletRow(
                                icon: "app.badge",
                                title: "No need to open the app for each send",
                                subtitle: "Once committed, transfers broadcast in the background over the next ~24 hours."
                            )

                            bulletRow(
                                icon: "shuffle",
                                title: "Sends de-correlated from your activity",
                                subtitle: "Transfers go out on fixed-ish windows, not tied to when you open ZODL."
                            )
                        }

                        Text("Background delivery is best-effort, not guaranteed.")
                            .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }

                VStack(spacing: 8) {
                    ZashiButton("Skip — I'll open the app", type: .secondary) {
                        store.send(.skipTapped)
                    }
                    
                    ZashiButton("Allow Background Access") {
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

    private func bulletRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .zForegroundColor(Design.Text.primary)
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
