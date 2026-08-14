//
//  MigrationEntryView.swift
//  zodl
//
//  "Move to Ironwood" entry screen (MOB-1460, Figma S1 · 2867:10445 privacy selected /
//  2867:5641 + 2867:5731 immediate selected; MOB-1487 round 2 restyle · canvas "Final Designs" ·
//  3480:6578 privacy / 3480:5841 immediate). The `nextTapped` delegate is consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1497 (T7, Q3'26 canvas · 3508:11219 / 4207:10692): the immediate-mode disclaimer note is
//  replaced with the shared `ZashiInfoCallout(.warning)` "Privacy Disclaimer" card — same visibility
//  condition (`.immediate` selected), same position — now sharing its look with the Review Transfer
//  screen's manual-mode callout. The privacy-mode `footerNote` and its `.migrationEntryFooterNote`
//  key are untouched.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationEntryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationEntry>

    init(store: StoreOf<MigrationEntry>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // SCROLLER SHAPE (all four migration screens): the ScrollView spans the full screen
                // width and its CONTENT carries `screenHorizontalPadding()`, rather than the whole
                // screen being padded and the scroller living inside that column. Otherwise the
                // scroll indicator is inset by the same 24pt as the content and draws ON TOP of it —
                // over the ZEC amounts on Transfer Plan, over the card edges here. Same shape the
                // Activity list has always used (`TransactionsManagerView`: full-bleed list, padded
                // rows). The footer below is pinned outside the scroller, so it pads itself.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MigrationPairedIcons(vendor: store.selectedWalletAccount?.vendor ?? .zcash)
                            .padding(.bottom, 16)

                        Text(localizable: .migrationEntryTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        description
                            .padding(.bottom, 12)

                        Button {
                            store.send(.findOutMoreTapped)
                        } label: {
                            Text(localizable: .migrationEntryFindOutMore)
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                                .underline()
                        }
                        .padding(.bottom, 24)

                        optionCards
                    }
                    .screenHorizontalPadding()
                    .padding(.vertical, 1)
                }

                VStack(spacing: 0) {
                    if store.isDisclaimerVisible {
                        disclaimer
                            .padding(.top, 16)
                    } else {
                        footerNote
                            .padding(.top, 16)
                    }

                    ZashiButton(String(localizable: .generalNext)) {
                        store.send(.nextTapped)
                    }
                    .disabled(store.isProceeding)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .screenHorizontalPadding()
            }
            .zashiBack() { store.send(.dismissRequired) }
            .sheet(isPresented: $store.isInAppBrowserOn) {
                if let url = URL(string: MigrationEntry.findOutMoreURLString) {
                    InAppBrowserView(url: url)
                }
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Description

    @ViewBuilder private var description: some View {
        let amountText = "\(store.orchardBalance.decimalString()) ZEC"

        if let fiatText = store.fiatText {
            let markdown = String(localizable: .migrationEntryDesc(
                "^[\(amountText)](style: 'boldPrimary')",
                fiatText
            ))

            if let attrText = try? AttributedString(markdown: markdown, including: \.zashiApp) {
                ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let markdown = String(localizable: .migrationEntryDescNoFiat(
                "^[\(amountText)](style: 'boldPrimary')"
            ))

            if let attrText = try? AttributedString(markdown: markdown, including: \.zashiApp) {
                ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Option cards

    @ViewBuilder private var optionCards: some View {
        VStack(spacing: 12) {
            optionCard(
                mode: .privateScheduled,
                title: String(localizable: .migrationEntryPrivacyTitle),
                subtitle: String(localizable: .migrationEntryPrivacyDesc)
            )

            optionCard(
                mode: .immediate,
                title: String(localizable: .migrationEntryImmediateTitle),
                subtitle: String(localizable: .migrationEntryImmediateDesc)
            )
        }
    }

    @ViewBuilder private func optionCard(mode: MigrationMode, title: String, subtitle: String) -> some View {
        let isSelected = store.selectedMode == mode
        let isWarning = isSelected && mode == .immediate

        Button {
            store.send(.modeTapped(mode))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                radioIndicator(isSelected: isSelected, isWarning: isWarning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .zFont(.semiBold, size: 16, style: isWarning ? Design.Utility.WarningYellow._700 : Design.Text.primary)

                    Text(subtitle)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(isSelected ? Design.Surfaces.bgPrimary.color(colorScheme) : Design.Surfaces.bgSecondary.color(colorScheme))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .strokeBorder(
                                    isWarning ? Design.Utility.WarningYellow._500.color(colorScheme) : Design.Checkboxes.onBg.color(colorScheme),
                                    lineWidth: isWarning ? 1 : 2
                                )
                        }
                    }
                    .overlay {
                        if isWarning {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl + 2)
                                .stroke(Design.Utility.WarningYellow._100.color(colorScheme), lineWidth: 2)
                                .padding(-2)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func radioIndicator(isSelected: Bool, isWarning: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    isSelected
                        ? (isWarning ? Design.Utility.WarningYellow._600.color(colorScheme) : Design.Checkboxes.onBg.color(colorScheme))
                        : Design.Checkboxes.offBg.color(colorScheme)
                )
                .overlay {
                    if !isSelected {
                        Circle()
                            .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                    }
                }

            if isSelected {
                Circle()
                    .fill(Design.Checkboxes.onFg.color(colorScheme))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - Disclaimer

    /// MOB-1511 (W1, Figma 3480:5841): the immediate path's note — same plain info-note anatomy as
    /// `footerNote` below, in the warning tone (the `WarningYellow` ramp renders the design's
    /// orange), replacing the earlier titled "Privacy Disclaimer" callout.
    @ViewBuilder private var disclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Utility.WarningYellow._700)

            Text(localizable: .migrationEntryImmediateNote)
                .zFont(size: 12, style: Design.Utility.WarningYellow._700)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // MARK: - Footer note

    @ViewBuilder private var footerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationEntryFooterNote)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

// MARK: - Previews

#Preview("Privacy selected") {
    NavigationView {
        MigrationEntryView(
            store: StoreOf<MigrationEntry>(
                initialState: MigrationEntry.State(
                    selectedMode: .privateScheduled,
                    orchardBalance: Zatoshi(1_245_800_000)
                )
            ) {
                MigrationEntry()
            }
        )
    }
}

#Preview("Immediate selected") {
    NavigationView {
        MigrationEntryView(
            store: StoreOf<MigrationEntry>(
                initialState: MigrationEntry.State(
                    selectedMode: .immediate,
                    orchardBalance: Zatoshi(1_245_800_000)
                )
            ) {
                MigrationEntry()
            }
        )
    }
}
