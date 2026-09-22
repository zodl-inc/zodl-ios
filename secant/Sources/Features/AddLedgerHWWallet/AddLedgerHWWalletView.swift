//
//  AddLedgerHWWalletView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3. Mirrors AddKeystoneHWWalletView's instructions screen, swapping the
//  Keystone-specific step copy/logo for Ledger's and the Bluetooth-pairing CTA
//  (`connectTapped`, which the coord flow maps to pushing the device picker) for Keystone's
//  QR-scan CTA.
//

import SwiftUI
import ComposableArchitecture

struct AddLedgerHWWalletView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Asset.Assets.Partners.ledgerTitleLogo.image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 32)
                            .padding(.top, 16)

                        Text(localizable: .keystoneConnect)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.top, 24)

                        Text(localizable: .ledgerAddHWWalletPair)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .lineSpacing(1.5)
                            .padding(.top, 8)

                        Text(localizable: .keystoneAddHWWalletHowTo)
                            .zFont(.semiBold, size: 18, style: Design.Text.primary)
                            .padding(.top, 24)

                        LedgerNumberedStepRow(number: 1, title: String(localizable: .ledgerAddHWWalletStep1))
                            .padding(.top, 16)

                        LedgerNumberedStepRow(number: 2, title: String(localizable: .ledgerAddHWWalletStep2))
                            .padding(.top, 16)

                        LedgerNumberedStepRow(number: 3, title: String(localizable: .ledgerAddHWWalletStep3))
                            .padding(.top, 16)

                        LedgerNumberedStepRow(number: 4, title: String(localizable: .ledgerAddHWWalletStep4))
                            .padding(.top, 16)

                        LedgerNumberedStepRow(number: 5, title: String(localizable: .ledgerAddHWWalletStep5))
                            .padding(.top, 16)
                    }
                }
                .padding(.vertical, 1)

                Spacer()

                ZashiButton(String(localizable: .keystoneAddHWWalletConnect)) {
                    store.send(.connectTapped)
                }
                .padding(.vertical, 24)
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
            .zashiBack() {
                store.send(.backToHomeTapped)
            }
            .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                helpSheetContent()
            }
            .navigationBarItems(
                trailing:
                    Button {
                        store.send(.helpSheetRequested)
                    } label: {
                        Asset.Assets.Icons.help.image
                            .zImage(size: 24, style: Design.Text.primary)
                            .padding(Design.Spacing.navBarButtonPadding)
                    }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }

    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .hardwareWalletExplainerTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Text(localizable: .hardwareWalletExplainerDescription)
                .zFont(size: 14, style: Design.Text.primary)
                .padding(.bottom, Design.Spacing._2xl)
                .fixedSize(horizontal: false, vertical: true)

            infoContent(
                Asset.Assets.Icons.chainLink.image,
                title: String(localizable: .hardwareWalletExplainerFeatureTitle1),
                desc: String(localizable: .hardwareWalletExplainerFeatureDescription1)
            )
            .padding(.bottom, Design.Spacing._xl)

            infoContent(
                Asset.Assets.Icons.shieldTick.image,
                title: String(localizable: .hardwareWalletExplainerFeatureTitle2),
                desc: String(localizable: .hardwareWalletExplainerFeatureDescription2)
            )
            .padding(.bottom, Design.Spacing._xl)

            infoContent(
                Asset.Assets.Icons.crypto.image,
                title: String(localizable: .hardwareWalletExplainerFeatureTitle3),
                desc: String(localizable: .hardwareWalletExplainerFeatureDescription3)
            )
            .padding(.bottom, Design.Spacing._4xl)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Asset.Assets.Partners.ledgerLogo.image
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(.trailing, Design.Spacing._md)

                    Text(localizable: .hardwareWalletExplainerInfoBoxTitleLedger)
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                }
                .padding(.bottom, Design.Spacing._md)

                Text(localizable: .hardwareWalletExplainerInfoBoxDescriptionLedger)
                    .zFont(size: 14, style: Design.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Design.Spacing._2xl)
            .padding(.vertical, Design.Spacing._xl)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
            .padding(.bottom, Design.Spacing._4xl)

            ZashiButton(String(localizable: .hardwareWalletExplainerCta)) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder private func infoContent(_ icon: Image, title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                icon
                    .zImage(size: 16, style: Design.Text.primary)
                    .padding(.trailing, Design.Spacing._md)

                Text(title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
            }
            .padding(.bottom, Design.Spacing._xs)

            Text(desc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A step row for the pairing instructions: a numbered circle (matching `InfoRow`'s icon-circle
/// styling) instead of an icon, since these five steps have no per-step icon in the Figma layout.
private struct LedgerNumberedStepRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .frame(width: 40, height: 40)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                }
                .padding(.trailing, 16)

            Text(title)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            Spacer(minLength: 2)
        }
        .background(Asset.Colors.background.color)
    }
}

// MARK: Placeholders

extension AddLedgerHWWallet.State {
    static var initial: AddLedgerHWWallet.State { AddLedgerHWWallet.State() }
}

extension AddLedgerHWWallet {
    @MainActor static let initial = StoreOf<AddLedgerHWWallet>(
        initialState: .initial
    ) {
        AddLedgerHWWallet()
    }
}

#Preview {
    NavigationView {
        AddLedgerHWWalletView(store: AddLedgerHWWallet.initial)
    }
}
