#if VOTING_ENABLED
//
//  DelegationSigningStore.swift
//  Zashi
//

import ComposableArchitecture
import Combine

@Reducer
struct DelegationSigning {
    @ObservableState
    struct State: Equatable {
        let roundId: String

        init(roundId: String) {
            self.roundId = roundId
        }
    }

    enum Action: Equatable {}

    var body: some ReducerOf<Self> {
        EmptyReducer()
    }
}

import SwiftUI
/// Keystone QR signing screen for the multi-bundle delegation flow. One
/// PCZT is built per note bundle and rendered as a QR; the user signs on
/// the Keystone device, scans the signed PCZT back, and the loop advances
/// to the next bundle until all signatures are gathered.
struct DelegationSigningView: View {
    @Environment(\.colorScheme) var colorScheme
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    @PlatformBindable var store: StoreOf<VotingCoordFlow>
    let roundId: String

    @State private var isQRCodeEnlarged = false

    var body: some View {
        WithPerceptionTracking {
            let session = store.roundCache[roundId]
            let status = session?.keystoneSigningStatus ?? .idle
            let bundleCount = session?.bundleCount ?? 0
            let currentBundle = session?.currentKeystoneBundleIndex ?? 0
            // Use the resolved prefix rather than `keystoneBundleSignatures.count`
            // so the count reflects bundles already accepted by the reducer
            // (including any recovered after a crash) — not just the ones the
            // user signed in the current session.
            let signedBundleCount = session?.resolvedKeystonePrefixCount ?? 0
            let bundleWeights = Self.bundleWeightSummary(session: session)
            let pollTitle = store.allRounds.first { $0.id == roundId }?.title ?? ""
            let currentBundleMemo = Self.currentBundleMemo(
                session: session,
                pollTitle: pollTitle
            )
            let isSigningRouteActive = Self.isSigningRouteActive(store.path, roundId: roundId)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        keystoneDeviceCard()
                            .padding(.top, 12)

                        if isSigningRouteActive {
                            qrCodeSection(status: status)
                                .padding(.top, 20)
                        }

                        signingDetailsCard(
                            current: currentBundle,
                            total: bundleCount,
                            signed: signedBundleCount,
                            signedWeight: bundleWeights.signed,
                            pendingWeight: bundleWeights.pending,
                            memo: currentBundleMemo,
                            status: status
                        )
                        .padding(.top, 24)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                Spacer(minLength: 0)

                if isSigningRouteActive {
                    actionButtons(status: status)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteDelegationSigningTitle))
            .zashiBack {
                store.send(.delegationRejected(roundId: roundId))
            }
            .navigationBarBackButtonHidden()
            .sheet(
                store: store.scope(state: \.$keystoneScan, action: \.keystoneScan)
            ) { scanStore in
                ScanView(store: scanStore, popoverRatio: 1.075)
            }
            .enlargeQR(isPresented: $isQRCodeEnlarged) {
                Group {
                    if let pczt = store.roundCache[roundId]?.pendingUnsignedDelegationPczt,
                       let encoder = sdkSynchronizer.urEncoderForPCZT(pczt) {
                        #if os(macOS)
                        // No full device screen to fill — clamp to the capped content column so the
                        // enlarged QR doesn't overflow the window. iOS fills the device width.
                        let qrSize = Design.Mac.viewCapWidth - 64
                        #else
                        let qrSize = PlatformScreen.bounds.width - 64
                        #endif
                        AnimatedQRCode(urEncoder: encoder, size: qrSize)
                            .padding()
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._4xl)
                                    .fill(Color.white)
                            }
                    }
                }
            }
            // While this screen is up the user typically steps away to fetch
            // and use their Keystone — keep the display awake so the QR stays
            // visible and the submission flow stays foregrounded.
            .onAppear { PlatformIdleTimer.disabled = true }
            .onDisappear { PlatformIdleTimer.disabled = false }
        }
    }

    // MARK: - Keystone Device

    @ViewBuilder
    private func keystoneDeviceCard() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Brandmarks.brandmarkKeystone.image
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .padding(.trailing, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .accountsKeystone)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                if let address = store.selectedWalletAccount?.unifiedAddress {
                    Text(address)
                        .zFont(size: 12, style: Design.Text.tertiary)
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
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
                }
        }
    }

    // MARK: - QR Code

    @ViewBuilder
    private func qrCodeSection(status: KeystoneSigningStatus) -> some View {
        ZStack {
            switch status {
            case .idle, .preparingRequest:
                qrStatusView(
                    text: status == .preparingRequest
                        ? String(localizable: .coinVoteDelegationSigningPreparingRequestEllipsis)
                        : nil
                )

            case .awaitingSignature:
                if let pczt = store.roundCache[roundId]?.pendingUnsignedDelegationPczt,
                   let encoder = sdkSynchronizer.urEncoderForPCZT(pczt),
                   !isQRCodeEnlarged {
                    AnimatedQRCode(urEncoder: encoder, size: 216)
                        .frame(width: 216, height: 216)
                        .onTapGesture {
                            withAnimation(.easeInOut) {
                                isQRCodeEnlarged = true
                            }
                        }
                } else {
                    qrStatusView(text: nil)
                }

            case .parsingSignature:
                qrStatusView(text: String(localizable: .coinVoteDelegationSigningParsingSignatureEllipsis))

            case .finalizingAuthorization:
                qrStatusView(text: String(localizable: .coinVoteDelegationSigningFinalizingAuthorizationEllipsis))

            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(Design.Utility.ErrorRed._500.color(colorScheme))

                    Text(message)
                        .zFont(.medium, size: 13, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
        }
        .frame(width: 248, height: 248)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func qrStatusView(text: String?) -> some View {
        VStack(spacing: 8) {
            ZashiSpinner()
            if let text {
                Text(text)
                    .zFont(.medium, size: 13, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 216, height: 216)
    }

    // MARK: - Signing Details

    @ViewBuilder
    private func signingDetailsCard(
        current: UInt32,
        total: UInt32,
        signed: UInt32,
        signedWeight: UInt64,
        pendingWeight: UInt64,
        memo: String?,
        status: KeystoneSigningStatus
    ) -> some View {
        VStack(spacing: 0) {
            signatureProgressSection(
                current: current,
                total: total,
                signed: signed,
                signedWeight: signedWeight,
                pendingWeight: pendingWeight
            )

            if canUseSignedBundlesOnly(signed: signed, total: total, status: status) {
                detailsDivider()
                useSignedBundlesOnlyRow(pendingWeight: pendingWeight)
            }

            if let memo {
                detailsDivider()
                memoSection(memo)
            }
        }
        .background(Design.Surfaces.bgSecondary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._xl))
    }

    @ViewBuilder
    private func signatureProgressSection(
        current: UInt32,
        total: UInt32,
        signed: UInt32,
        signedWeight: UInt64,
        pendingWeight: UInt64
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(localizable: .coinVoteDelegationSigningCurrentBundleProgress(
                    String(Self.displayBundleNumber(current: current, total: total)),
                    String(max(total, 1))
                ))
                .zFont(.medium, size: 14, style: Design.Text.primary)

                Spacer(minLength: 8)

                Text(localizable: .coinVoteDelegationSigningSignedProgress(String(signed), String(max(total, 1))))
                    .zFont(.medium, size: 12, style: Design.Utility.HyperBlue._700)
                    .lineLimit(1)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background {
                        Capsule()
                            .fill(Design.Utility.HyperBlue._50.color(colorScheme))
                            .overlay {
                                Capsule()
                                    .stroke(Design.Utility.HyperBlue._200.color(colorScheme), lineWidth: 1)
                            }
                    }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Design.Surfaces.bgQuaternary.color(colorScheme))
                    Capsule()
                        .fill(Design.Text.primary.color(colorScheme))
                        .frame(width: geometry.size.width * Self.signingProgress(signed: signed, total: total))
                }
            }
            .frame(height: 6)

            Text(weightSummary(signed: signed, signedWeight: signedWeight, pendingWeight: pendingWeight))
                .zFont(size: 12, style: Design.Text.tertiary)
                .lineLimit(1)
        }
        .padding(16)
    }

    @ViewBuilder
    private func useSignedBundlesOnlyRow(pendingWeight: UInt64) -> some View {
        Button {
            store.send(.skipRemainingKeystoneBundles(roundId: roundId))
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(localizable: .coinVoteDelegationSigningUseSignedBundlesOnly)
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                        .lineLimit(1)

                    Text(localizable: .coinVoteDelegationSigningUseSignedBundlesOnlySubtitle(Self.formatZec(pendingWeight)))
                        .zFont(size: 12, style: Design.Text.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Asset.Assets.chevronRight.image
                    .zImage(size: 20, style: Design.Text.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .zashiPlainButtonStyle()
    }

    @ViewBuilder
    private func memoSection(_ memo: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localizable: .coinVoteDelegationSigningMemo)
                .zFont(size: 14, style: Design.Text.tertiary)

            Text(memo)
                .zFont(.medium, size: 12, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailsDivider() -> some View {
        Design.Surfaces.strokeSecondary.color(colorScheme)
            .frame(height: 1)
    }

    // MARK: - Memo

    private static func currentBundleMemo(session: RoundSession?, pollTitle: String) -> String? {
        guard
            let session,
            session.bundleCount > 0
        else {
            return nil
        }

        let bundles = session.walletNotes.smartBundles().bundles
        let bundleIndex = Int(session.currentKeystoneBundleIndex)
        guard bundleIndex < Int(session.bundleCount), bundleIndex < bundles.count else {
            return nil
        }

        let bundleTotal = bundles[bundleIndex].reduce(UInt64(0)) { $0 + $1.value }
        return votingAuthorizationMemo(pollTitle: pollTitle, rawWeight: bundleTotal)
    }

    private static func bundleWeightSummary(session: RoundSession?) -> (signed: UInt64, pending: UInt64) {
        guard let session else { return (0, 0) }

        let bundles = session.walletNotes.smartBundles().bundles
        // Drive the signed/pending split from the resolved-prefix count so
        // recovered bundles roll into the "signed" bucket even when the
        // current-session signature array hasn't been repopulated yet.
        let signedCount = min(Int(session.resolvedKeystonePrefixCount), bundles.count)
        let countedBundleCount = min(Int(session.bundleCount), bundles.count)
        var signed: UInt64 = 0
        var pending: UInt64 = 0

        for index in 0..<countedBundleCount {
            let rawWeight = bundles[index].reduce(UInt64(0)) { $0 + $1.value }
            if index < signedCount {
                signed += quantizeWeight(rawWeight)
            } else {
                pending += quantizeWeight(rawWeight)
            }
        }

        return (signed, pending)
    }

    private static func formatZec(_ zatoshi: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        formatter.usesGroupingSeparator = true

        let value = Double(zatoshi) / 100_000_000.0
        return formatter.string(from: NSNumber(value: value)) ?? "0.000"
    }

    private static func displayBundleNumber(current: UInt32, total: UInt32) -> UInt32 {
        guard total > 0 else { return 1 }
        return min(current + 1, total)
    }

    /// Fraction of bundles already signed, clamped to [0, 1]. Drives the
    /// signing-progress capsule. Replaces an earlier `bundleShare(total:)`
    /// that ignored `signed` and always returned `1 / total` (showing 50%
    /// indefinitely on a 2-bundle round).
    private static func signingProgress(signed: UInt32, total: UInt32) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(signed) / Double(total))
    }

    private func weightSummary(signed: UInt32, signedWeight: UInt64, pendingWeight: UInt64) -> String {
        if signed == 0 {
            return String(localizable: .coinVoteDelegationSigningAwaitingWeightSummary(
                Self.formatZec(signedWeight),
                Self.formatZec(pendingWeight)
            ))
        }

        return String(localizable: .coinVoteDelegationSigningSignedWeightSummary(
            Self.formatZec(signedWeight),
            Self.formatZec(pendingWeight)
        ))
    }

    private func canUseSignedBundlesOnly(signed: UInt32, total: UInt32, status: KeystoneSigningStatus) -> Bool {
        // Only surface the row while we're idle on a new bundle request — the
        // old standalone CTA had the same gate. Without it, the row can be
        // tapped while the next Keystone PCZT is still being prepared, which
        // races the in-flight signing-status transitions.
        guard status == .awaitingSignature else { return false }

        // Mirror the gate added on main (PR #1789 / commit 8e570578): we only
        // surface "Use signed bundles only" when the resolved bundles form a
        // contiguous prefix starting from index 0. Without that constraint,
        // an out-of-order signature (e.g. bundle 2 signed before 1) could
        // cause `skipRemainingKeystoneBundles` to skip across a gap and
        // submit nothing for the missing prefix.
        let resolvedPrefix = store.roundCache[roundId]?.resolvedKeystonePrefixCount ?? 0
        return total > 1 && signed > 0 && signed < total && resolvedPrefix > 0
    }

    private static func isSigningRouteActive(
        _ path: StackState<VotingCoordFlow.Path.State>,
        roundId: String
    ) -> Bool {
        path.contains {
            guard case let .delegationSigning(signingState) = $0 else {
                return false
            }
            return signingState.roundId == roundId
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private func actionButtons(status: KeystoneSigningStatus) -> some View {
        switch status {
        case .awaitingSignature:
            ZashiButton(String(localizable: .coinVoteDelegationSigningScanSignature)) {
                store.send(.openKeystoneSignatureScan)
            }
        case .failed:
            ZashiButton(String(localizable: .coinVoteCommonGoBack)) {
                store.send(.delegationRejected(roundId: roundId))
            }
        default:
            EmptyView()
        }
    }
}
#endif
