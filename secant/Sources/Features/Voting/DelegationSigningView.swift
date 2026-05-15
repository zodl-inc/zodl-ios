import SwiftUI
import ComposableArchitecture

struct DelegationSigningView: View {
    @Environment(\.colorScheme)
    var colorScheme
    @Dependency(\.sdkSynchronizer)
    var sdkSynchronizer

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        keystoneDeviceCard()
                            .padding(.top, 40)

                        if isMultiBundleSigning {
                            multiBundleProgressCard()
                                .padding(.top, 24)
                        }

                        qrCodeSection()
                            .padding(.top, isMultiBundleSigning ? 24 : 32)

                        instructionText()
                            .padding(.top, 32)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                actionButtons()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .screenTitle(String(localizable: .coinVoteCommonConfirmation))
        .zashiBack {
            store.send(.delegationRejected)
        }
        .navigationBarBackButtonHidden()
        .alert(
            store: store.scope(
                state: \.$skipBundlesAlert,
                action: \.skipBundlesAlert
            )
        )
    }

    // MARK: - Keystone Device Card

    @ViewBuilder
    private func keystoneDeviceCard() -> some View {
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

                if let address = store.selectedWalletAccount?.unifiedAddress {
                    Text(address)
                        .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

    // MARK: - QR Code Section

    @ViewBuilder
    private func qrCodeSection() -> some View {
        switch store.keystoneSigningStatus {
        case .idle, .preparingRequest:
            VStack {
                ProgressView()
                    .padding(.bottom, 8)
                Text(buildingRequestText)
                    .zFont(.medium, size: 13, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
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

        case .awaitingSignature:
            if let pczt = store.pendingUnsignedDelegationPczt,
               let encoder = sdkSynchronizer.urEncoderForPCZT(pczt) {
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
            } else {
                Text(localizable: .coinVoteDelegationSigningQrEncodingFailed)
                    .zFont(size: 13, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }

        case .parsingSignature:
            VStack {
                ProgressView()
                    .padding(.bottom, 8)
                Text(localizable: .coinVoteDelegationSigningProcessingSignature)
                    .zFont(.medium, size: 13, style: Design.Text.tertiary)
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

        case .failed(let error):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(Design.Utility.ErrorRed._500.color(colorScheme))
                Text(error)
                    .zFont(size: 13, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 216)
            .padding(24)
        }
    }

    // MARK: - Instruction Text

    @ViewBuilder
    private func instructionText() -> some View {
        VStack(spacing: 4) {
            Text(instructionTitle)
                .zFont(.medium, size: 16, style: Design.Text.primary)

            Text(instructionDescription)
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let bundleWeight = store.currentBundleZECString {
                Text(localizable: .coinVoteDelegationSigningCurrentBundleWeight(bundleWeight))
                    .zFont(size: 13, style: Design.Text.tertiary)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons() -> some View {
        VStack(spacing: 8) {
            switch store.keystoneSigningStatus {
            case .idle, .preparingRequest:
                if !isMultiBundleSigning {
                    cancelButton()
                }
                ZashiButton(scanSignatureButtonTitle) { }
                    .disabled(true)
                    .opacity(0.5)

            case .awaitingSignature:
                if !isMultiBundleSigning {
                    cancelButton()
                }
                ZashiButton(scanSignatureButtonTitle) {
                    store.send(.openKeystoneSignatureScan)
                }

            case .parsingSignature:
                ZashiButton(String(localizable: .coinVoteDelegationSigningProcessing)) { }
                    .disabled(true)
                    .opacity(0.5)

            case .failed:
                if !isMultiBundleSigning {
                    cancelButton()
                }
                ZashiButton(String(localizable: .coinVoteCommonRetry)) {
                    store.send(.retryKeystoneSigning)
                }
            }

        }
    }

    private func cancelButton() -> some View {
        ZashiButton(String(localizable: .coinVoteCommonCancel), type: .ghost) {
            store.send(.delegationRejected)
        }
    }

    private var isMultiBundleSigning: Bool {
        store.bundleCount > 1
    }

    private var totalBundleCount: Int {
        max(Int(store.bundleCount), 1)
    }

    private var signedBundleCount: Int {
        min(store.keystoneBundleSignatures.count, totalBundleCount)
    }

    private var currentBundleNumber: Int {
        min(Int(store.currentKeystoneBundleIndex) + 1, totalBundleCount)
    }

    private var buildingRequestText: String {
        guard isMultiBundleSigning else {
            return String(localizable: .coinVoteDelegationSigningBuildingRequest)
        }

        if signedBundleCount > 0 {
            return String(
                localizable: .coinVoteDelegationSigningPreparingNextBundle(
                    String(signedBundleCount),
                    String(currentBundleNumber),
                    String(totalBundleCount)
                )
            )
        }

        return String(
            localizable: .coinVoteDelegationSigningBuildingBundleRequest(
                String(currentBundleNumber),
                String(totalBundleCount)
            )
        )
    }

    private var instructionTitle: String {
        guard isMultiBundleSigning else {
            return String(localizable: .keystoneSignWithTitle)
        }

        return String(
            localizable: .coinVoteDelegationSigningBundleProgress(
                String(currentBundleNumber),
                String(totalBundleCount)
            )
        )
    }

    private var instructionDescription: String {
        guard isMultiBundleSigning else {
            return String(localizable: .coinVoteDelegationSigningInstruction)
        }

        return String(localizable: .coinVoteDelegationSigningMultiBundleInstruction(String(totalBundleCount)))
    }

    private var scanSignatureButtonTitle: String {
        guard isMultiBundleSigning else {
            return String(localizable: .coinVoteDelegationSigningScanSignature)
        }

        return String(localizable: .coinVoteDelegationSigningScanSignedBundle(String(currentBundleNumber)))
    }
}

// MARK: - Multi-Bundle Progress

extension DelegationSigningView {
    @ViewBuilder
    func multiBundleProgressCard() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text(
                    localizable: .coinVoteDelegationSigningCurrentBundleProgress(
                        String(currentBundleNumber),
                        String(totalBundleCount)
                    )
                )
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .id(currentBundleNumber)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(
                    localizable: .coinVoteDelegationSigningSignedProgress(
                        String(signedBundleCount),
                        String(totalBundleCount)
                    )
                )
                .zFont(.medium, size: 12, style: Design.Utility.HyperBlue._700)
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background {
                    Capsule()
                        .fill(Design.Utility.HyperBlue._50.color(colorScheme))
                }
                .overlay {
                    Capsule()
                        .stroke(Design.Utility.HyperBlue._200.color(colorScheme), lineWidth: 1)
                }
            }

            ProgressView(value: Double(signedBundleCount), total: Double(totalBundleCount))
                .tint(Design.Utility.HyperBlue._500.color(colorScheme))

            Text(
                localizable: .coinVoteDelegationSigningSignedWeightSummary(
                    store.signedBundlesZECString,
                    store.skippedBundlesZECString
                )
            )
            .zFont(size: 13, style: Design.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if signedBundleCount > 0 && signedBundleCount < totalBundleCount {
                Divider()
                    .overlay(Design.Surfaces.strokeSecondary.color(colorScheme))

                Button {
                    store.send(.skipRemainingKeystoneBundles)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localizable: .coinVoteDelegationSigningUseSignedBundlesOnly)
                                .zFont(.medium, size: 14, style: Design.Text.primary)

                            Text(
                                localizable: .coinVoteDelegationSigningUseSignedBundlesOnlySubtitle(
                                    store.skippedBundlesZECString
                                )
                            )
                            .zFont(size: 12, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Design.Text.tertiary.color(colorScheme))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Design.Surfaces.bgSecondary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: currentBundleNumber)
        .animation(.easeInOut(duration: 0.2), value: signedBundleCount)
    }
}
