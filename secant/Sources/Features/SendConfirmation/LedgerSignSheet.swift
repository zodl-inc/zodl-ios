//
//  LedgerSignSheet.swift
//  Zashi
//
//  MOB-2020: Figma 1073:19914 -- the Ledger signing sheet that replaces the pushed Ledger
//  confirm-on-device screen for send, request-ZEC, pay and swap (and, since UI round 2, shielding
//  too -- see `RootCoordinator`'s `.signWithKeystoneRequested`). Presented as a `zashiSheet` over
//  the screen the user confirmed from while the Ledger signs -- only "Cancel Transaction" closes
//  it, via `.interactiveDismissDisabled()`. The status block below copies (not moves) that former
//  screen's `statusContent`/`deviceRow`, without its bone-coloured card. A failed ceremony instead
//  shows `LedgerIssueSheetContent`, the same Ledger error-state sheet `AddLedgerHWWallet`'s device
//  picker uses.
//
//  MOB-2020: Figma 1439:28498 ("Confirmation Screen v2", the iOS 26 bottom sheet) redraws every
//  spinner state as `LedgerWaitingIndicator` (node 1439:28709, shared with step 4's approve
//  screen -- see LedgerStepComponents.swift), 24 pt below the description instead of 16.
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
                        case .pairLedger:
                            store.send(.pairLedgerTapped)
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
                        .padding(.top, 24)

                    ZashiButton(
                        String(localizable: .ledgerSignSheetCancel),
                        type: .destructive1
                    ) {
                        store.send(.ledgerSignCancelTapped)
                    }
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity)
                // The top and bottom padding apply only to this normal content -- `LedgerIssueSheetContent`
                // pads itself.
                .padding(.top, 32)
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
            LedgerWaitingIndicator(title: String(localizable: .ledgerSignWithScanning))

        case .selectingDevice:
            VStack(spacing: 12) {
                Text(localizable: .ledgerSignWithSelectDevice)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .multilineTextAlignment(.center)

                ForEach(store.ledgerSigning.devices) { device in
                    deviceRow(device, colorScheme)
                }
            }

        case .connecting:
            LedgerWaitingIndicator(title: String(localizable: .ledgerSignWithConnecting))

        case .openingZcashApp:
            LedgerWaitingIndicator(title: String(localizable: .ledgerSignWithOpeningApp))

        case .connected:
            LedgerWaitingIndicator(title: String(localizable: .ledgerSignWithPreparing))

        case .signing(.identifyingDevice), .signing(.streaming):
            LedgerWaitingIndicator(title: String(localizable: .ledgerSignWithSending))

        case .signing(.awaitingReviewOnDevice):
            // The sheet's own description is already the instruction -- nothing more to show.
            EmptyView()

        case .signing(.signing), .signing(.complete), .signed:
            LedgerWaitingIndicator(title: String(localizable: .ledgerSignWithSigning))

        case .failed:
            // `body` renders `LedgerIssueSheetContent` instead of this content while
            // `phase == .failed` -- this case only keeps the switch exhaustive over `Phase`.
            EmptyView()
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
                .zashiSheet(
                    isPresented: $store.isLedgerSignSheetPresented,
                    onDismiss: {
                        // MOB-2020 (Android e36fedb2/ebc98b38): every caller gets this signal, not
                        // just Ledger shielding's (the only one that used to pass its own
                        // `onDismiss`) -- Root's Pair Ledger repair-flow switch needs the real
                        // animation-complete moment for every host of this sheet, the same reason
                        // `.ledgerShieldingSheetDismissed` exists. `onDismiss` below is unchanged,
                        // whatever additional reaction a caller already wired up.
                        store.send(.ledgerSignSheetDismissed)
                        onDismiss?()
                    }
                ) {
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
