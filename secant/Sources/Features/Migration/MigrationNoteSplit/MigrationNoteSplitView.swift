//
//  MigrationNoteSplitView.swift
//  zodl
//
//  "Splitting Funds…" / "Split Confirmed!" screen (MOB-1461, Figma S2 · 2867:10741 progress /
//  2867:10645 success / 2670:15570 failure sheet) — MOB-1478 (W4): re-entry-only now, see
//  `MigrationNoteSplitStore`'s header comment. `onAppear` resumes/observes the split live via the
//  store; the back control always closes the flow (re-entry is always the flow root). The
//  `continueTapped` delegate (confirmed phase) is consumed by `MigrationCoordFlowCoordinator`, which
//  closes the flow too — the commit already happened before the split started.
//
//  MOB-1496 (W6): this screen is ALSO pushed mid-Keystone-batch-commit
//  (`MigrationCoordFlowCoordinator.resumeAfterKeystoneSigning`) to broadcast a signed split PCZT
//  whose schedule is already stored — the first production case with `isFlowRoot == false`. See
//  `applyPresentationModifier`'s doc for why its back control is hidden entirely in that case.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationNoteSplitView: View {
    private enum RowAppereance {
        case bottom
        case full
        case middle
        case top

        var corners: UIRectCorner {
            switch self {
            case .bottom:
                return [.bottomLeft, .bottomRight]
            case .full:
                return [.allCorners]
            case .middle:
                return []
            case .top:
                return [.topLeft, .topRight]
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationNoteSplit>

    init(store: StoreOf<MigrationNoteSplit>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MigrationPairedIcons(badge: headerBadge, vendor: store.selectedWalletAccount?.vendor ?? .zcash)
                            .padding(.bottom, 16)

                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        detailRows
                    }
                    .padding(.vertical, 1)
                }

                footer
            }
            .screenHorizontalPadding()
            .applyPresentationModifier(store: store)
            .zashiSheet(isPresented: $store.isFailurePresented) {
                failureSheetContent
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Header badge

    private var headerBadge: MigrationPairedIcons.Badge {
        switch store.phase {
        case .splitting:
            return .spinner
        case .confirmed:
            return .successCheck
        }
    }

    // MARK: - Title + description

    private var title: String {
        switch store.phase {
        case .splitting:
            return String(localizable: .migrationNoteSplitSplittingTitle)
        case .confirmed:
            return String(localizable: .migrationNoteSplitConfirmedTitle)
        }
    }

    private var description: String {
        switch store.phase {
        case .splitting:
            return String(localizable: .migrationNoteSplitSplittingDesc)
        case .confirmed:
            return String(localizable: .migrationNoteSplitConfirmedDesc)
        }
    }

    // MARK: - Detail rows

    @ViewBuilder private var detailRows: some View {
        VStack(spacing: 0) {
            detailRow(
                title: String(localizable: .transactionListTransactionId),
                value: store.txId.truncateMiddle,
                isAddressFont: true,
                icon: Asset.Assets.copy.image,
                rowAppereance: .top
            )
            .onTapGesture {
                store.send(.copyTxIdTapped)
            }

            detailRow(
                title: String(localizable: .sendAmount),
                value: "\(store.amount.decimalString()) ZEC",
                rowAppereance: .middle
            )

            detailRow(
                title: String(localizable: .sendFeeSummary),
                value: "\(store.fee.decimalString()) ZEC",
                rowAppereance: .bottom
            )
        }
    }

    @ViewBuilder private func detailRow(
        title: String,
        value: String,
        isAddressFont: Bool = false,
        icon: Image? = nil,
        rowAppereance: RowAppereance = .full
    ) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .zFont(size: 14, style: Design.Text.tertiary)

            Spacer()

            Text(value)
                .zFont(.medium, fontFamily: isAddressFont ? .robotoMono : .inter, size: 14, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let icon {
                icon
                    .zImage(size: 20, style: Design.Text.primary)
                    .padding(.leading, 6)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background {
            CustomRoundedRectangle(corners: rowAppereance.corners, radius: 12)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .padding(.bottom, rowAppereance == .full || rowAppereance == .bottom ? 0 : 1)
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        switch store.phase {
        case .splitting:
            VStack(spacing: 16) {
                inProgressInfoCard

                ZashiButton(
                    String(localizable: .migrationNoteSplitSplittingTitle),
                    type: .secondary,
                    prefixView: ProgressView()
                ) { }
                .disabled(true)
            }
            .padding(.top, 16)
            .padding(.bottom, 24)

        case .confirmed:
            ZashiButton(String(localizable: .migrationNoteSplitContinue)) {
                store.send(.continueTapped)
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private var inProgressInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(localizable: .migrationNoteSplitInProgressTitle)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)

                Spacer()

                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: Design.Text.tertiary)
            }

            Text(localizable: .migrationNoteSplitInProgressBody)
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - Failure sheet

    @ViewBuilder private var failureSheetContent: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(localizable: .migrationNoteSplitFailedTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(localizable: .migrationNoteSplitFailedBody)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                store.send(.cancelTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationNoteSplitRetry)) {
                store.send(.retryTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Presentation modifier

private extension View {
    /// Re-entry is always the flow root (MOB-1478 W4: forward routing never pushes a FRESH silent
    /// split's `.noteSplit` any more), across both phases — a plain pop would silently fall back to
    /// Entry underneath, which is wrong for a screen the user reached via the home banner, not by
    /// pushing forward.
    ///
    /// MOB-1496 (W6): `isFlowRoot == false` is reachable now too — the Keystone batch-commit's
    /// mid-flow split-broadcast push (`MigrationCoordFlowCoordinator.resumeAfterKeystoneSigning`).
    /// That push's schedule is ALREADY stored (no-partial-storage invariant already held by the time
    /// this screen appears); a plain pop would leave the coordinator's `pendingKeystoneSplitResume`
    /// stashed with no way to clear it (only the `.continued` delegate does), and would strand the
    /// user back on the underlying TransferPlan/ReviewTransfer screen, which has no way to know its
    /// schedule is already committed — re-tapping its Confirm would re-sign/re-store transfer ids the
    /// engine already has. Mirroring `MigrationKeystoneSignView`'s unconditional
    /// `.navigationBarBackButtonHidden(true)` for the identical "mid-commit, no casual abandon"
    /// reason, this hides the back control entirely instead: the only way off this screen in that
    /// case is `continueTapped`, once the split confirms.
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationNoteSplit>) -> some View {
        if store.isFlowRoot {
            zashiBackV2 {
                store.send(.closeTapped)
            }
        } else {
            zashiBack(hidden: true)
        }
    }
}

// MARK: - Previews

#Preview("Splitting") {
    NavigationView {
        MigrationNoteSplitView(
            store: StoreOf<MigrationNoteSplit>(
                initialState: MigrationNoteSplit.State(
                    phase: .splitting,
                    amount: Zatoshi(1_245_800_000),
                    fee: Zatoshi(100_000),
                    txId: "e87f1234567890abcdef6f28b"
                )
            ) {
                MigrationNoteSplit()
            }
        )
    }
}

#Preview("Confirmed") {
    NavigationView {
        MigrationNoteSplitView(
            store: StoreOf<MigrationNoteSplit>(
                initialState: MigrationNoteSplit.State(
                    phase: .confirmed,
                    amount: Zatoshi(1_245_800_000),
                    fee: Zatoshi(100_000),
                    txId: "e87f1234567890abcdef6f28b"
                )
            ) {
                MigrationNoteSplit()
            }
        )
    }
}

#Preview("Splitting + failure sheet") {
    NavigationView {
        MigrationNoteSplitView(
            store: StoreOf<MigrationNoteSplit>(
                initialState: MigrationNoteSplit.State(
                    phase: .splitting,
                    amount: Zatoshi(1_245_800_000),
                    fee: Zatoshi(100_000),
                    txId: "e87f1234567890abcdef6f28b",
                    isFailurePresented: true
                )
            ) {
                MigrationNoteSplit()
            }
        )
    }
}
