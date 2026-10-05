//
//  LedgerApproveOnDeviceView.swift
//  Zashi
//
//  MOB-2020 (Android 7cd09f72/aa6d098a, Figma 1560:8988 "Approve on Device"): the screen
//  ConnectHWWalletCoordFlowCoordinator pushes when the device picker's Connect is tapped. Runs
//  the whole pairing -- connecting, opening the Zcash app and the viewing-key export -- that used
//  to run inline on the picker. Two states, told apart by `store.isConnecting || store.isPairing`:
//  while waiting, the header sits above the shared placeholder rows (LedgerDeviceSkeletons) with
//  a waiting indicator over them and only Cancel below; after a failure, only the header shows,
//  with Cancel and a Retry below it and the shared LedgerIssueSheetContent sheet on top -- the
//  same sheet the picker shows for a scan failure. Cancel and the back arrow both cancel the
//  pairing, disconnect and pop back to the picker (AddLedgerHWWalletStore's `.cancelTapped`, and
//  ConnectHWWalletCoordFlowStore's own arm for it, since the coordinator runs before this
//  element's own reducer and cannot safely pop it there -- see the coordinator's doc comment).
//

import SwiftUI
import ComposableArchitecture

struct LedgerApproveOnDeviceView: View {
    @Environment(\.openURL) private var openURL
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    private var isWaiting: Bool {
        store.isConnecting || store.isPairing
    }

    /// Hidden when `store.issue` offers no Try again or Open Settings in `.connect` -- an issue
    /// this screen cannot retry from, such as a signing-only or account-already-added issue.
    /// Unwraps `store.issue` first and switches over the non-optional `PrimaryAction` -- that
    /// type has its own `.none` case, which a switch directly over `PrimaryAction?` would
    /// collide with `Optional.none` (no issue at all) rather than match.
    private var showsRetry: Bool {
        guard let issue = store.issue else { return false }
        switch issue.primaryAction(in: .connect) {
        case .tryAgain, .openSettings: return true
        // `.pairLedger` is a `.sign`-only affordance (`.notPaired.primaryAction(in: .connect)` is
        // always `.none`) -- listed so the switch stays exhaustive over `PrimaryAction`, not
        // because this screen ever shows it.
        case .goToAccount, .close, .pairLedger, .none: return false
        }
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.ledgerTitleLogo.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 32)
                    .padding(.top, 16)

                Text(localizable: .ledgerApproveTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: .ledgerApproveMessage)
                    .zFont(size: 14, style: Design.Text.primary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                if isWaiting {
                    LedgerDeviceSkeletons(isShimmering: false) {
                        ZStack(alignment: .bottom) {
                            // Figma: a fade that turns fully opaque halfway down the rows --
                            // unlike the picker's own fixed 164 pt bottom fade, this one spans
                            // the rows' whole height (matching Android's `LedgerDeviceSkeletons`).
                            LinearGradient(
                                stops: [
                                    .init(color: Asset.Colors.background.color.opacity(0), location: 0),
                                    .init(color: Asset.Colors.background.color, location: 0.5),
                                    .init(color: Asset.Colors.background.color, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .allowsHitTesting(false)

                            WaitingIndicator()
                                .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.top, 24)
                }

                Spacer()

                ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                    store.send(.cancelTapped)
                }
                .padding(.bottom, showsRetry ? 12 : 24)

                if showsRetry {
                    ZashiButton(String(localizable: .ledgerApproveRetry), type: .primary) {
                        // Mirrors LedgerIssueSheetContent's own primary button: Open Settings is
                        // this view's job before `.issuePrimaryTapped` dismisses the sheet -- the
                        // reducer only reconnects for `.tryAgain`.
                        if store.issue?.primaryAction(in: .connect) == .openSettings,
                           let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                        store.send(.issuePrimaryTapped)
                    }
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .zashiBack(customDismiss: { store.send(.cancelTapped) })
            .zashiSheet(isPresented: $store.isIssueSheetPresented) {
                issueSheetContent()
            }
        }
        .applyScreenBackground()
    }

    // `zashiSheet`'s `content` closure isn't `@ViewBuilder`-attributed, so the `if let` needs its
    // own `@ViewBuilder` function rather than sitting directly in that trailing closure -- same
    // as LedgerDevicePickerView's own `issueSheetContent()`.
    @ViewBuilder private func issueSheetContent() -> some View {
        if let issue = store.issue {
            LedgerIssueSheetContent(issue: issue, context: .connect) {
                store.send(.issuePrimaryTapped)
            }
        }
    }
}

/// Figma "Waiting Indicator": a spinner that completes one turn per second, the waiting title and
/// subtitle below it, all centred and at most 280 pt wide.
private struct WaitingIndicator: View {
    @State private var isRotating = false

    var body: some View {
        VStack(spacing: 12) {
            Asset.Assets.Icons.loading.image
                .zImage(size: 24, style: Design.Text.primary)
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isRotating)
                .onAppear { isRotating = true }

            VStack(spacing: 4) {
                Text(localizable: .ledgerApproveWaitingTitle)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .multilineTextAlignment(.center)

                Text(localizable: .ledgerApproveWaitingSubtitle)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 280)
    }
}
