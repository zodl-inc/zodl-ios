//
//  MigrationEntryView.swift
//  zodl
//
//  "Move to Ironwood" entry screen. Figma node 2630:11744 / 2539:63191.
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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Move to Ironwood")
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)
                            .padding(.top, 24)

                        Text("The latest Zcash network upgrade requires moving your ZEC from the Orchard pool to the new Ironwood pool. Your funds are safe.")
                            .zFont(.regular, size: 16, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        balanceBlock()
                            .padding(.top, 8)

                        if store.balanceLoadFailed {
                            failureBlock()
                                .padding(.top, 8)
                        } else {
                            optionsBlock()
                                .padding(.top, 8)

                            Text("Pool-crossing transfer amounts are visible on-chain.")
                                .zFont(.regular, size: 12, style: Design.Text.support)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }

                if !store.balanceLoadFailed {
                    ZashiButton("Next") {
                        store.send(.nextTapped)
                    }
                    .padding(.bottom, 24)
                    .padding(.top, 8)
                }
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    @ViewBuilder
    private func balanceBlock() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ORCHARD BALANCE")
                .zFont(.medium, size: 12, style: Design.Text.support)

            Text("\(store.orchardBalance.decimalString()) \(tokenName)")
                .zFont(.semiBold, size: 36, style: Design.Text.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder
    private func optionsBlock() -> some View {
        VStack(spacing: 12) {
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

    @ViewBuilder
    private func optionCard(mode: MigrationMode, title: String, subtitle: String) -> some View {
        let isSelected = store.selectedMode == mode

        Button {
            store.send(.modeSelected(mode))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                radioIndicator(isSelected: isSelected)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)

                    Text(subtitle)
                        .zFont(.regular, size: 13, style: Design.Text.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .stroke(
                                isSelected
                                    ? Design.Surfaces.brandPrimary.color(colorScheme)
                                    : Design.Surfaces.strokePrimary.color(colorScheme),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func radioIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(
                    isSelected
                        ? Design.Surfaces.brandPrimary.color(colorScheme)
                        : Design.Surfaces.strokePrimary.color(colorScheme),
                    lineWidth: 2
                )
                .frame(width: 20, height: 20)

            if isSelected {
                Circle()
                    .fill(Design.Surfaces.brandPrimary.color(colorScheme))
                    .frame(width: 10, height: 10)
            }
        }
    }

    @ViewBuilder
    private func failureBlock() -> some View {
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
