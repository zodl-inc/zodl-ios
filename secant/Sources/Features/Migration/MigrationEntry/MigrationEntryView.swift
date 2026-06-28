//
//  MigrationEntryView.swift
//  zodl
//
//  "Move to Ironwood" entry screen (Figma B1 · 2630:11744). Root of the migration flow — the leading
//  control is a close (X) that dismisses the whole flow back to Home.
//

import ComposableArchitecture
import SwiftUI

struct MigrationEntryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationEntry>
    let tokenName: String

    init(store: StoreOf<MigrationEntry>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                topBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            pairedIcons
                                .padding(.top, 4)

                            Text("Move to Ironwood")
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        }

                        Text("Latest Zcash network upgrade requires moving your \(tokenName) from the Orchard pool to the new Ironwood pool. Your funds are safe.")
                            .zFont(.regular, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        balanceCard

                        if store.balanceLoadFailed {
                            failureBlock
                        } else {
                            optionsBlock
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }

                if !store.balanceLoadFailed {
                    Spacer(minLength: 16)

                    disclaimerRow
                        .padding(.bottom, 16)

                    ZashiButton("Next") {
                        store.send(.nextTapped)
                    }
                    .disabled(!store.nextEnabled)
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    // MARK: - Top bar

    @ViewBuilder private var topBar: some View {
        HStack {
            Button {
                store.send(.closeTapped)
            } label: {
                Asset.Assets.Icons.xClose.image
                    .zImage(size: 24, style: Design.Text.primary)
            }

            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Header icons

    @ViewBuilder private var pairedIcons: some View {
        MigrationPairedIcons()
    }

    // MARK: - Balance card

    @ViewBuilder private var balanceCard: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Orchard balance")
                    .zFont(.regular, size: 12, style: Design.Text.tertiary)

                Text("\(store.orchardBalance.decimalString()) \(tokenName)")
                    .zFont(.semiBold, size: 18, style: Design.Text.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(MigrationFiat.string(for: store.orchardBalance))
                .zFont(.regular, size: 12, style: Design.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - Options

    @ViewBuilder private var optionsBlock: some View {
        VStack(spacing: 8) {
            optionCard(
                mode: .immediate,
                title: "Migrate Immediately",
                subtitle: "Single transfer · Sends now · No privacy"
            )

            optionCard(
                mode: .privateScheduled,
                title: "Migrate with Privacy",
                subtitle: "Split transfers over time · Scheduled in background · Maximum privacy"
            )
        }
    }

    @ViewBuilder private func optionCard(mode: MigrationMode, title: String, subtitle: String) -> some View {
        let isSelected = store.selectedMode == mode

        Button {
            store.send(.modeSelected(mode))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                radioIndicator(isSelected: isSelected)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .zFont(.medium, size: 16, style: Design.Text.primary)

                    Text(subtitle)
                        .zFont(.regular, size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .stroke(Design.Checkboxes.onBg.color(colorScheme), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func radioIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    isSelected
                        ? Design.Checkboxes.onBg.color(colorScheme)
                        : Design.Checkboxes.offBg.color(colorScheme)
                )
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected
                                ? Design.Checkboxes.onBg.color(colorScheme)
                                : Design.Checkboxes.offStroke.color(colorScheme),
                            lineWidth: 1
                        )
                }

            if isSelected {
                Circle()
                    .fill(Design.Checkboxes.onFg.color(colorScheme))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - Disclaimer

    @ViewBuilder private var disclaimerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text("Pool-crossing transfer amounts are visible on-chain.")
                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Failure

    @ViewBuilder private var failureBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Couldn't load your Orchard balance")
                .zFont(.medium, size: 16, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ZashiButton("Try again") {
                store.send(.retryTapped)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
