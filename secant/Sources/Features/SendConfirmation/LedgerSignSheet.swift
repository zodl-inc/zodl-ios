//
//  LedgerSignSheet.swift
//  Zashi
//
//  MOB-2020: Figma 1073:19914 -- the Ledger signing sheet that replaces the pushed Ledger
//  confirm-on-device screen for send, request-ZEC, pay and swap (and, since UI round 2, shielding
//  too -- see `RootCoordinator`'s `.signWithKeystoneRequested`). Presented as a `zashiSheet` over
//  the screen the user confirmed from while the Ledger signs -- only "Cancel Transaction" closes
//  it, via `.interactiveDismissDisabled()`. The status block below copies (not moves) that former
//  screen's `statusContent`/`spinnerStatus`/`deviceRow`, without its bone-coloured card. A failed
//  ceremony instead shows `LedgerIssueSheetContent`, the same Ledger error-state sheet
//  `AddLedgerHWWallet`'s device picker uses.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct LedgerSignSheetView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<SendConfirmation>

    var body: some View {
        WithPerceptionTracking {
            if store.ledgerSigning.phase == .failed, let issue = store.ledgerSigning.issue {
                LedgerIssueSheetContent(
                    issue: issue,
                    context: .sign,
                    primaryAction: store.ledgerSigning.failedPrimaryAction,
                    onPrimary: {
                        switch store.ledgerSigning.failedPrimaryAction {
                        case .tryAgain:
                            store.send(.ledgerSigning(.tryAgainTapped))
                        case .openSettings:
                            store.send(.ledgerSigning(.openSettingsTapped))
                        case .goToAccount, .close, .none:
                            break
                        }
                    },
                    secondary: .init(
                        title: String(localizable: .ledgerSignSheetCancel),
                        type: .destructive1,
                        action: { store.send(.ledgerSignCancelTapped) }
                    )
                )
            } else {
                VStack(spacing: 0) {
                    Asset.Assets.Partners.ledgerLogo.image
                        .resizable()
                        .frame(width: 44, height: 44)

                    Text(localizable: .ledgerSignSheetTitle)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .padding(.top, 12)

                    Text(localizable: .ledgerSignSheetDesc)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    statusContent()
                        .padding(.top, 16)

                    ZashiButton(
                        String(localizable: .ledgerSignSheetCancel),
                        type: .destructive1
                    ) {
                        store.send(.ledgerSignCancelTapped)
                    }
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity)
                // The bottom padding applies only to this normal content -- `LedgerIssueSheetContent`
                // pads itself.
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
        // No `.onAppear` here: on iOS 16.4-25 `ZashiSheetModifier` re-identifies this content
        // on every height change (the status block below switches shape), which would refire
        // `.onAppear` mid-ceremony -- `.confirmWithLedgerTapped` starts it once instead.
        .interactiveDismissDisabled()
    }
}

extension LedgerSignSheetView {
    @ViewBuilder private func statusContent() -> some View {
        switch store.ledgerSigning.phase {
        case .scanning:
            spinnerStatus(String(localizable: .ledgerSignWithScanning))

        case .selectingDevice:
            VStack(spacing: 12) {
                Text(localizable: .ledgerSignWithSelectDevice)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)

                ForEach(store.ledgerSigning.devices) { device in
                    deviceRow(device, colorScheme)
                }
            }

        case .connecting:
            spinnerStatus(String(localizable: .ledgerSignWithConnecting))

        case .connected:
            spinnerStatus(String(localizable: .ledgerSignWithPreparing))

        case .signing(.identifyingDevice), .signing(.streaming):
            spinnerStatus(String(localizable: .ledgerSignWithSending))

        case .signing(.awaitingReviewOnDevice):
            // The sheet's own description is already the instruction -- nothing more to show.
            EmptyView()

        case .signing(.signing), .signing(.complete), .signed:
            spinnerStatus(String(localizable: .ledgerSignWithSigning))

        case .failed:
            // `body` renders `LedgerIssueSheetContent` instead of this content while
            // `phase == .failed` -- this case only keeps the switch exhaustive over `Phase`.
            EmptyView()
        }
    }

    @ViewBuilder private func spinnerStatus(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()

            Text(text)
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice, _ colorScheme: ColorScheme) -> some View {
        Button {
            store.send(.ledgerSigning(.deviceTapped(device)))
        } label: {
            HStack(spacing: 0) {
                Asset.Assets.Partners.ledgerMark.image
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(8)
                    .background {
                        Circle()
                            .fill(Design.Surfaces.bgAlt.color(colorScheme))
                    }
                    .padding(.trailing, 8)

                Text(device.model.productName)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._3xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
        }
    }
}

private struct LedgerSignSheetModifier: ViewModifier {
    @Perception.Bindable var store: StoreOf<SendConfirmation>
    let onDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .zashiSheet(isPresented: $store.isLedgerSignSheetPresented, onDismiss: onDismiss) {
                    LedgerSignSheetView(store: store)
                }
        }
    }
}

extension View {
    func ledgerSignSheet(store: StoreOf<SendConfirmation>, onDismiss: (() -> Void)? = nil) -> some View {
        modifier(LedgerSignSheetModifier(store: store, onDismiss: onDismiss))
    }
}
