//
//  MigrationTorFailureSheetView.swift
//  zodl
//
//  "Couldn't Connect to Tor" bottom sheet (MOB-1497 T6, Figma 4207:9064 light / 4207:9324 dark).
//  Mirrors `MigrationTorSheetView`'s custom-server ("unavailable") variant composition exactly — the
//  circular obsidian Tor badge, a 20pt semibold title, a tertiary body, a `MigrationRisksCard`, and a
//  destructive1 / primary button column — swapped to this surface's copy (`migrationTorFailure.*`) and
//  actions ("Continue without Tor" / "Try again"). Hosted by `RootView` as a `zashiSheet` (which
//  applies the horizontal padding + drag indicator), so the content here carries vertical spacing
//  only. See `MigrationTorFailureSheetStore` for why this surface — not a second alert — is the R15
//  clearnet-consent escape hatch.
//

import ComposableArchitecture
import SwiftUI

struct MigrationTorFailureSheetView: View {
    @PlatformBindable var store: StoreOf<MigrationTorFailureSheet>

    init(store: StoreOf<MigrationTorFailureSheet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                torBadge
                    .padding(.top, 48)
                    .padding(.bottom, 12)

                Text(localizable: .migrationTorFailureTitle)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
                    .padding(.bottom, 4)

                Text(localizable: .migrationTorFailureBody)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, Design.Spacing._3xl)

                MigrationRisksCard(body: String(localizable: .migrationTorFailureRisksBody))
                    .padding(.bottom, Design.Spacing._3xl)

                VStack(spacing: 12) {
                    ZashiButton(String(localizable: .migrationTorSheetContinueWithoutTor), type: .destructive1) {
                        store.send(.continueWithoutTorTapped)
                    }

                    ZashiButton(String(localizable: .migrationTorFailureTryAgain)) {
                        store.send(.tryAgainTapped)
                    }
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }

    // MARK: - Tor badge

    /// Duplicated verbatim from `MigrationTorSheetView` (the tiny badge is deliberately copied rather
    /// than refactored into a shared component — see this task's brief): a 48pt fixed-obsidian circle
    /// with the white Tor mark. Fixed color by design (the dark mocks sample ~#333A41, no exact token).
    @ViewBuilder private var torBadge: some View {
        Circle()
            .fill(Asset.Colors.ZDesign.Base.obsidian.color)
            .frame(width: 48, height: 48)
            .overlay {
                Asset.Assets.Partners.torLogo.image
                    .zImage(width: 28, height: 19, color: .white)
            }
    }
}

// MARK: - Previews

#Preview {
    MigrationTorFailureSheetView(
        store: StoreOf<MigrationTorFailureSheet>(
            initialState: MigrationTorFailureSheet.State()
        ) {
            MigrationTorFailureSheet()
        }
    )
    .screenHorizontalPadding()
}
