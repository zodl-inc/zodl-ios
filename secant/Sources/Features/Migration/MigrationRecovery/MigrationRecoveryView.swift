//
//  MigrationRecoveryView.swift
//  zodl
//
//  "Transfer No Longer Valid" (Figma C5 · 2621:10289). The pre-signed transfer is stale (input note
//  spent / anchor expired); the user re-creates it for the remaining amount and the rest is
//  re-scheduled. Deep entry from the Home banner — the leading control closes the whole flow → Home.
//

import ComposableArchitecture
import SwiftUI

struct MigrationRecoveryView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationRecovery>
    let tokenName: String

    init(store: StoreOf<MigrationRecovery>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    private var transferNumber: Int {
        store.invalidTransferNumber > 0 ? store.invalidTransferNumber : 1
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transfer No Longer Valid")
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Transfer \(transferNumber) was pre-signed for a balance that has since changed. It needs to be re-created for the remaining amount.")
                                .zFont(.regular, size: 14, style: Design.Text.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 12)

                        staleCard

                        whatHappensNext
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }

                VStack(alignment: .leading, spacing: 24) {
                    continuesNote

                    VStack(spacing: 12) {
                        ZashiButton("Learn more", type: .secondary) {
                            store.send(.learnMoreTapped)
                        }

                        ZashiButton("Re-create Transfer") {
                            store.send(.recreateTapped)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .navigationBarBackButtonHidden(true)
            .toolbar {
                // Deep entry from the Home banner — the leading control closes the whole flow → Home.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.send(.closeTapped)
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Design.Text.primary.color(colorScheme))
                    }
                }
            }
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    // MARK: - Stale transfer card

    @ViewBuilder private var staleCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stale transfer detected")
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text("Signed for \(store.invalidAmount.decimalString()) \(tokenName). Your balance has changed since pre-signing.")
                    .zFont(.regular, size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "info.circle")
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - What happens next

    @ViewBuilder private var whatHappensNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Happens Next")
                .zFont(.medium, size: 14, style: Design.Text.primary)

            VStack(alignment: .leading, spacing: 8) {
                bulletRow(1, "A new transfer is created for Transfer \(transferNumber)")
                bulletRow(2, "Remaining transfers are re-scheduled")
                bulletRow(3, "No funds are lost — only the pre-signed key is discarded")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func bulletRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Design.Text.tertiary.color(colorScheme))
                Text("\(number)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)

            Text(text)
                .zFont(.medium, size: 12, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Continues note

    @ViewBuilder private var continuesNote: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))

            Text("\(store.summary.transfersSent) of \(store.summary.transfersTotal) transfers done; migration will continue.")
                .zFont(.regular, size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
