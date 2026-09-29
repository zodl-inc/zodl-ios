//
//  LedgerDevicePickerView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: the Bluetooth device list ConnectHWWalletCoordFlow pushes once the
//  instructions screen's CTA is tapped. Per the Figma "Select Your Device" review, this screen
//  finds and selects the Ledger; Connect now pushes the Approve on Your Device screen
//  (LedgerApproveOnDeviceView), which runs the actual connect-and-pair -- this screen never
//  connects on its own, so its Connect button never shows a spinner. Row styling mirrors
//  AccountsSelectionView's account row. A scan failure shows as a LedgerIssueSheetContent sheet
//  (MOB-2020 error states) on top of this screen; a swipe-dismiss leaves only the bottom Try
//  again to retry. The placeholder rows are LedgerDeviceSkeletons, shared with the approve screen.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct LedgerDevicePickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.ledgerTitleLogo.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .padding(.top, 16)

                Text(localizable: store.devices.isEmpty ? .ledgerDevicePickerSearchingTitle : .ledgerDevicePickerTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: store.devices.isEmpty ? .ledgerDevicePickerSearchingDesc : .ledgerDevicePickerDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                if store.devices.isEmpty {
                    LedgerDeviceSkeletons(isShimmering: store.isScanning) {
                        // Unchanged from before the extraction: a 164 pt gradient anchored to the
                        // bottom of the rows, not the rows-spanning fade the approve screen uses.
                        LinearGradient(
                            colors: [Asset.Colors.background.color.opacity(0), Asset.Colors.background.color],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 164)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                    }
                    .padding(.top, 32)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.devices) { device in
                                deviceRow(device)
                            }
                        }
                    }
                    .padding(.top, 32)
                }

                Spacer()

                if store.isScanning && store.devices.isEmpty {
                    ZashiButton(
                        String(localizable: .ledgerDevicePickerSearching),
                        prefixView: ProgressView()
                    ) { }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else if store.canRescan {
                    ZashiButton(String(localizable: .ledgerIssueTryAgain)) {
                        store.send(.startScanning)
                    }
                    .padding(.bottom, 24)
                } else {
                    // MOB-2020: pushes the Approve on Your Device screen, which starts the
                    // connect-and-pair -- never `.connectDeviceTapped` here. The element reducer
                    // (below the coordinator in the reduce order) would otherwise also see that
                    // action and connect right on this screen, which no longer shows a spinner for it.
                    ZashiButton(
                        store.issue != nil
                        ? String(localizable: .ledgerIssueTryAgain)
                        : String(localizable: .keystoneAddHWWalletConnect)
                    ) {
                        store.send(.approveOnDeviceTapped)
                    }
                    .disabled(store.selectedDevice == nil)
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.startScanning) }
            .onDisappear { store.send(.stopScanning) }
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
            .zashiSheet(isPresented: $store.isIssueSheetPresented) {
                issueSheetContent()
            }
        }
        .applyScreenBackground()
    }

    // `zashiSheet`'s `content` closure isn't `@ViewBuilder`-attributed (unlike SwiftUI's own
    // `.sheet`), so the `if let` below needs its own `@ViewBuilder` function rather than sitting
    // directly in that trailing closure.
    @ViewBuilder private func issueSheetContent() -> some View {
        if let issue = store.issue {
            LedgerIssueSheetContent(issue: issue, context: .connect) {
                store.send(.issuePrimaryTapped)
            }
        }
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice) -> some View {
        Button {
            store.send(.deviceTapped(device))
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
                    .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 0) {
                    Text(device.model.productName)
                        .zFont(.semiBold, size: 14, style: Design.Text.primary)

                    if let name = device.name {
                        Text(name)
                            .zFont(size: 12, style: Design.Text.tertiary)
                    }
                }

                Spacer()

                ZashiToggle(
                    isOn: Binding(
                        get: { store.selectedDevice?.id == device.id },
                        set: { _ in store.send(.deviceTapped(device)) }
                    )
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
        }
    }
}
