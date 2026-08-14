//
//  MigrationHowItWorksView.swift
//  zodl
//
//  "How This Works" explainer screen (MOB-1478 W3). Pushed after Entry for the scheduled/private
//  path; the `continueTapped` delegate is consumed by `MigrationCoordFlowCoordinator`, which gates on
//  the Tor bottom sheet (W2) before continuing into the permission-step chain.
//

import ComposableArchitecture
import SwiftUI

struct MigrationHowItWorksView: View {
    @PlatformBindable var store: StoreOf<MigrationHowItWorks>

    init(store: StoreOf<MigrationHowItWorks>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // SCROLLER SHAPE: full-bleed ScrollView, `screenHorizontalPadding()` on its CONTENT,
                // so the scroll indicator rides the screen edge rather than the content column's.
                // See `MigrationEntryView` for the full note.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizable: .migrationHowItWorksTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(localizable: .migrationHowItWorksIntro)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        bulletRows
                    }
                    .screenHorizontalPadding()
                    .padding(.vertical, 1)
                }

                Spacer(minLength: 16)

                VStack(spacing: 0) {
                    footerNote
                        .padding(.bottom, 16)

                    ZashiButton(String(localizable: .migrationHowItWorksContinue)) {
                        store.send(.continueTapped)
                    }
                    .padding(.bottom, 24)
                }
                .screenHorizontalPadding()
            }
            .zashiBack()
        }
        .applyScreenBackground()
    }

    // MARK: - Bullet rows

    @ViewBuilder private var bulletRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            MigrationBulletRow(
                icon: Asset.Assets.Icons.coinsSwap.image,
                title: String(localizable: .migrationHowItWorksSplitScheduleTitle),
                caption: String(localizable: .migrationHowItWorksSplitScheduleDesc)
            )

            MigrationBulletRow(
                icon: Asset.Assets.Icons.checkSquareBroken.image,
                title: String(localizable: .migrationHowItWorksApproveOnceTitle),
                caption: String(localizable: .migrationHowItWorksApproveOnceDesc)
            )

            MigrationBulletRow(
                icon: Asset.Assets.Icons.bellRinging.image,
                title: String(localizable: .migrationHowItWorksFailsTitle),
                caption: String(localizable: .migrationHowItWorksFailsDesc)
            )

            MigrationBulletRow(
                icon: Asset.Assets.Icons.layersThree.image,
                title: String(localizable: .migrationHowItWorksLargeBalanceTitle),
                caption: String(localizable: .migrationHowItWorksLargeBalanceDesc)
            )
        }
    }

    // MARK: - Footer note

    // Top-aligned + wrapping (unlike MigrationTransferPlanView's centered one-liner idiom this
    // otherwise mirrors) — the dust note runs multiple lines, so a centered single-line layout would
    // leave the icon floating mid-paragraph.
    @ViewBuilder private var footerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationHowItWorksDustNote)
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
        MigrationHowItWorksView(
            store: StoreOf<MigrationHowItWorks>(
                initialState: MigrationHowItWorks.State()
            ) {
                MigrationHowItWorks()
            }
        )
    }
}
