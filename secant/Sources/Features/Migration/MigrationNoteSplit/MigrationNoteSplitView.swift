//
//  MigrationNoteSplitView.swift
//  zodl
//
//  Figma nodes 2670:14995 / 15235 / 15570 (Split / Splitting / Confirmed).
//

import ComposableArchitecture
import SwiftUI

struct MigrationNoteSplitView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationNoteSplit>
    let tokenName: String

    init(store: StoreOf<MigrationNoteSplit>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 24)

                        Text("This sends a transaction to yourself, breaking your balance into smaller notes. Each Ironwood migration transfer can then send independently — no waiting for change.")
                            .zFont(.regular, size: 16, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if store.step == .confirmed {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .resizable()
                                    .frame(width: 64, height: 64)
                                    .foregroundStyle(Color.green)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }

                        detailsBlock()

                        if store.step == .splitting {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                primaryButton()
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }
}

extension MigrationNoteSplitView {
    private var title: String {
        switch store.step {
        case .confirm: return "Split Your Wallet Funds"
        case .splitting: return "Splitting Funds…"
        case .confirmed: return "Split Confirmed!"
        }
    }

    @ViewBuilder func detailsBlock() -> some View {
        VStack(spacing: 0) {
            detailRow(title: "Amount", value: "\(store.totalAmount.decimalString()) \(tokenName)")
            divider()
            detailRow(title: "Fee", value: "\(store.fee.decimalString()) \(tokenName)")
            divider()
            detailRow(title: "Notes", value: "\(store.noteCount)")

            if !store.txId.isEmpty {
                divider()
                detailRow(title: "Transaction ID", value: store.txId)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)

            Spacer(minLength: 16)

            Text(value)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder func divider() -> some View {
        Rectangle()
            .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
            .frame(height: 1)
    }

    @ViewBuilder func primaryButton() -> some View {
        switch store.step {
        case .confirm:
            ZashiButton("Confirm") {
                store.send(.confirmTapped)
            }
        case .splitting:
            ZashiButton("Splitting Funds…") { }
                .disabled(true)
        case .confirmed:
            ZashiButton("Continue") {
                store.send(.continueTapped)
            }
        }
    }
}
