//
//  MigrationKeystoneSignView.swift
//  zodl
//
//  Migration-owned Keystone signing screen (MOB-1468, Figma sign frame 2867:11861). Visually
//  mirrors `SignWithKeystoneView`'s composition exactly: an account card carrying the Keystone
//  logo, a truncated ZIP-316 address and a "Hardware" badge; `AnimatedQRCode` (or the same
//  empty/loading treatment while the frames haven't built yet); "Scan with your Keystone" copy; Reject
//  (secondary/destructive) / Get Signature (primary). Reuses `SignWithKeystoneView`'s existing
//  localized keys — zero new *localized* strings.
//
//  MOB-1513: batch ceremonies read `store.frames`, built once by the store's `.onAppear` effect
//  (`sdkSynchronizer.buildKeystoneSignBatchQRParts`, see `MigrationKeystoneSignStore`'s header).
//  MOB-1513 (R8): the immediate lane's SINGLE-PCZT mode (`store.redactedSinglePczt` set) instead
//  computes the production `urEncoderForPCZT` encoder live in the view over the redacted bytes —
//  `SignWithKeystoneView` parity, and the reason the SDK dependency is back in the view (a
//  `UREncoder` is a non-`Equatable`, non-`Sendable` class that can't ride `@ObservableState`).
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct MigrationKeystoneSignView: View {
    @Environment(\.colorScheme) private var colorScheme

    @PlatformBindable var store: StoreOf<MigrationKeystoneSign>

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init(store: StoreOf<MigrationKeystoneSign>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // SCROLLER SHAPE: full-bleed ScrollView, `screenHorizontalPadding()` on its CONTENT
                // and on each pinned footer child — never on the column that holds the scroller, or
                // the indicator is inset by the same 24pt and draws ON TOP of the account card's
                // edge. See `MigrationEntryView` for the full note. The description below keeps its
                // OWN extra `screenHorizontalPadding()`, so it stays inset 48pt as before.
                ScrollView {
                    VStack(spacing: 0) {
                        accountCard
                            .padding(.top, 40)

                        qrArea
                            .padding(.top, 32)

                        Text(localizable: .keystoneSignWithTitle)
                            .zFont(.medium, size: 16, style: Design.Text.primary)
                            .padding(.top, 32)

                        // MOB-1513 (R9): a multi-round ceremony (packed by action budget in the SDK)
                        // tells the user where they are; the common single-round ceremony shows
                        // nothing new.
                        if store.totalRounds > 1 {
                            Text(localizable: .migrationKeystoneSignRoundIndicator(store.roundIndex + 1, store.totalRounds))
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                                .padding(.top, 4)
                        }

                        Text(localizable: .keystoneSignWithDesc)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .screenHorizontalPadding()
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .screenHorizontalPadding()
                }

                Spacer()

                ZashiButton(
                    String(localizable: .keystoneSignWithReject),
                    type: .destructive1
                ) {
                    store.send(.rejectTapped)
                }
                .screenHorizontalPadding()
                .padding(.bottom, 8)

                ZashiButton(
                    String(localizable: .keystoneSignWithGetSignature)
                ) {
                    store.send(.getSignatureTapped)
                }
                .screenHorizontalPadding()
                .padding(.bottom, 24)
            }
            .onAppear {
                store.send(.onAppear)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .applyScreenBackground()
        .navigationBarBackButtonHidden(true)
        .zashiNavBarTitleDisplayMode(.inline)
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
        // MOB-1513 (R8): single-PCZT mode (the immediate lane's PRODUCTION ceremony) computes the
        // `zcash-pczt` UR encoder live over the redacted-for-signer bytes — `SignWithKeystoneView`
        // parity, exactly why the encoder is view-computed and never state-held (a `UREncoder` is a
        // non-`Equatable`, non-`Sendable` class). Batch ceremonies render the SDK-built frames.
        if let redactedSinglePczt = store.redactedSinglePczt,
           let encoder = sdkSynchronizer.urEncoderForPCZT(Pczt(redactedSinglePczt)) {
            AnimatedQRCode(urEncoder: encoder, size: 250)
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
        } else if store.redactedSinglePczt == nil, !store.frames.isEmpty {
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
                initialState: MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: 0, pczt: Data(), actions: 3)])
            ) {
                MigrationKeystoneSign()
            }
        )
    }
}
