//
//  MigrationKeystoneSignView.swift
//  zodl
//
//  Migration-owned Keystone signing screen (MOB-1468, Figma sign frame 2867:11861). Visually
//  mirrors `SignWithKeystoneView`'s composition exactly: account card with Keystone logo +
//  truncated ZIP-316 address + "Hardware" badge, `AnimatedQRCode` (or the same empty/loading
//  treatment while the frames haven't built yet), "Scan with your Keystone wallet" copy, Reject
//  (secondary/destructive) / Get Signature (primary). Reuses `SignWithKeystoneView`'s existing
//  localized keys — zero new *localized* strings.
//
//  MOB-1513: the QR frames are now built once by the store's `.onAppear` effect
//  (`sdkSynchronizer.buildKeystoneSignBatchQRParts`, see `MigrationKeystoneSignStore`'s header) and
//  read from `store.frames` — the view no longer calls the SDK dependency directly.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct MigrationKeystoneSignView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationKeystoneSign>

    init(store: StoreOf<MigrationKeystoneSign>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        accountCard
                            .padding(.top, 40)

                        qrArea
                            .padding(.top, 32)

                        Text(localizable: .keystoneSignWithTitle)
                            .zFont(.medium, size: 16, style: Design.Text.primary)
                            .padding(.top, 32)

                        Text(localizable: .keystoneSignWithDesc)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .screenHorizontalPadding()
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                ZashiButton(
                    String(localizable: .keystoneSignWithReject),
                    type: .destructive1
                ) {
                    store.send(.rejectTapped)
                }
                .padding(.bottom, 8)

                ZashiButton(
                    String(localizable: .keystoneSignWithGetSignature)
                ) {
                    store.send(.getSignatureTapped)
                }
                .padding(.bottom, 24)
            }
            .onAppear {
                store.send(.onAppear)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .screenTitle(String(localizable: .keystoneSignWithSignTransaction))
    }

    // MARK: - Account card

    @ViewBuilder private var accountCard: some View {
        HStack(spacing: 0) {
            Asset.Assets.Partners.keystoneLogo.image
                .resizable()
                .frame(width: 24, height: 24)
                .padding(8)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgAlt.color(colorScheme))
                }
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .accountsKeystone)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(store.selectedWalletAccount?.unifiedAddress?.zip316 ?? "")
                    .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
            }

            Spacer()

            Text(localizable: .keystoneSignWithHardware)
                .zFont(.medium, size: 12, style: Design.Utility.HyperBlue._700)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .fill(Design.Utility.HyperBlue._50.color(colorScheme))
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .stroke(Design.Utility.HyperBlue._200.color(colorScheme))
                        }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
        }
    }

    // MARK: - QR area

    @ViewBuilder private var qrArea: some View {
        if !store.frames.isEmpty {
            AnimatedQRCode(frames: store.frames, size: 250)
                .frame(width: 216, height: 216)
                .padding(24)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Asset.Colors.ZDesign.Base.bone.color)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                        }
                }
        } else {
            VStack {
                ProgressView()
            }
            .frame(width: 216, height: 216)
            .padding(24)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .fill(Asset.Colors.ZDesign.Base.bone.color)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                    }
            }
        }
    }
}

// MARK: - Previews

#Preview("Dormant (stub encoder)") {
    NavigationView {
        MigrationKeystoneSignView(
            store: StoreOf<MigrationKeystoneSign>(
                initialState: MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "preview", pczt: Data())])
            ) {
                MigrationKeystoneSign()
            }
        )
    }
}
