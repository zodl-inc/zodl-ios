//
//  MigrationEntryView.swift
//  zodl
//
//  "Move to Ironwood" entry screen (MOB-1460, Figma S1 · 2867:10445 privacy selected /
//  2867:5641 + 2867:5731 immediate selected). Visually complete per Figma; the delegate emitted by
//  `nextTapped` is consumed by nobody yet — chaining into the rest of the migration flow lands in
//  MOB-1466.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationEntryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationEntry>

    init(store: StoreOf<MigrationEntry>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MigrationPairedIcons()
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
                    .padding(.vertical, 1)
                }

                if store.isDisclaimerVisible {
                    disclaimer
                        .padding(.top, 16)
                }

                footerNote
                    .padding(.top, 16)

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.nextTapped)
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .zashiBack()
        }
        .applyScreenBackground()
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
                        .zFont(.semiBold, size: 16, style: isWarning ? Design.Utility.WarningYellow._600 : Design.Text.primary)

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
                                .stroke(
                                    isWarning ? Design.Utility.WarningYellow._500.color(colorScheme) : Design.Checkboxes.onBg.color(colorScheme),
                                    lineWidth: 2
                                )
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
                        ? (isWarning ? Design.Utility.WarningYellow._500.color(colorScheme) : Design.Checkboxes.onBg.color(colorScheme))
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
                    .fill(isWarning ? .white : Design.Checkboxes.onFg.color(colorScheme))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - Disclaimer

    @ViewBuilder private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(localizable: .migrationEntryDisclaimerTitle)
                    .zFont(.medium, size: 14, style: Design.Utility.WarningYellow._600)

                Spacer()

                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: Design.Utility.WarningYellow._500)
            }

            Text(localizable: .migrationEntryDisclaimerDesc)
                .zFont(size: 12, style: Design.Utility.WarningYellow._700)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Utility.WarningYellow._50.color(colorScheme))
        }
    }

    // MARK: - Footer note

    @ViewBuilder private var footerNote: some View {
        HStack(spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationEntryFooterNote)
                .zFont(size: 12, style: Design.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Previews

#Preview("Privacy selected") {
    NavigationView {
        MigrationEntryView(
            store: StoreOf<MigrationEntry>(
                initialState: MigrationEntry.State(
                    selectedMode: .privateScheduled,
                    orchardBalance: Zatoshi(1_245_800_000),
                    fiatText: "$4,832.86"
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
                    orchardBalance: Zatoshi(1_245_800_000),
                    fiatText: "$4,832.86"
                )
            ) {
                MigrationEntry()
            }
        )
    }
}
