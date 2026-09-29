//
//  LedgerDevicePickerView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: the Bluetooth device list ConnectHWWalletCoordFlow pushes once the Turn On
//  and Unlock step's Continue is tapped. Restyled to Figma's step 2 (1599:11869 searching,
//  1599:11500 unselected, 1599:11578 selected, part of node 1599:12387's frame): the shared step
//  header/nav title, a back arrow that pops to step 1 instead of a close X that left the whole
//  flow, and a device row redrawn as a single-line name with a radio instead of ZashiToggle. This
//  screen finds and selects the Ledger; Connect now pushes the Approve on Your Device screen
//  (LedgerApproveOnDeviceView), which runs the actual connect-and-pair -- this screen never
//  connects on its own, though its Connect button reflects isConnecting while the phone pairs, the
//  way the searching state's button already reflects isScanning. A scan failure shows as a
//  LedgerIssueSheetContent sheet (MOB-2020 error states) on top of this screen; a swipe-dismiss
//  leaves only the bottom Try again to retry. The placeholder rows are LedgerDeviceSkeletons,
//  shared with the approve screen.
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
                LedgerStepHeader(
                    title: String(localizable: store.devices.isEmpty ? .ledgerDevicePickerSearchingTitle : .ledgerDevicePickerTitle),
                    subtitle: String(localizable: store.devices.isEmpty ? .ledgerDevicePickerSearchingDesc : .ledgerDevicePickerDesc)
                )

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
                    .padding(.top, 24)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.devices) { device in
                                deviceRow(device)
                            }
                        }
                    }
                    .padding(.top, 24)
                }

                Spacer()

                connectButton()
                    .padding(.bottom, 24)
            }
            .padding(.top, 12)
            .screenHorizontalPadding()
            .onAppear { store.send(.startScanning) }
            .onDisappear { store.send(.stopScanning) }
            .ledgerStepNavTitle(step: 2)
            .zashiBack()
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

    @ViewBuilder private func connectButton() -> some View {
        if store.isScanning && store.devices.isEmpty {
            ZashiButton(
                String(localizable: .ledgerDevicePickerSearching),
                minHeight: 48,
                prefixView: ProgressView()
            ) { }
            .disabled(true)
        } else if store.canRescan {
            ZashiButton(String(localizable: .ledgerIssueTryAgain), minHeight: 48) {
                store.send(.startScanning)
            }
        } else if store.isConnecting {
            // MOB-2020: the other executor's connection logic sets this while the phone pairs
            // over Bluetooth -- mirrors the searching button above (spinner, disabled).
            ZashiButton(
                String(localizable: .ledgerSignWithConnecting),
                minHeight: 48,
                prefixView: ProgressView()
            ) { }
            .disabled(true)
        } else {
            // MOB-2020: pushes the Approve on Your Device screen, which starts the
            // connect-and-pair -- never `.connectDeviceTapped` here. The element reducer
            // (below the coordinator in the reduce order) would otherwise also see that
            // action and connect right on this screen, which no longer shows a spinner for it.
            ZashiButton(
                store.issue != nil
                ? String(localizable: .ledgerIssueTryAgain)
                : String(localizable: .keystoneAddHWWalletConnect),
                minHeight: 48
            ) {
                store.send(.approveOnDeviceTapped)
            }
            .disabled(store.selectedDevice == nil)
        }
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice) -> some View {
        let isSelected = store.selectedDevice?.id == device.id

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

                Text(device.name ?? device.model.productName)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
                    .lineLimit(1)

                Spacer()

                radio(isSelected: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .stroke(
                                isSelected
                                ? Design.Surfaces.bgAlt.color(colorScheme)
                                : Design.Surfaces.strokeSecondary.color(colorScheme),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
            }
            // Figma's small card shadow, the same two-layer pair used across the app -- shown
            // only for the selected row, via opacity rather than branching the view so the row's
            // identity (and any implicit animation) stays stable across selection changes.
            .shadow(color: .black.opacity(isSelected ? 0.02 : 0), radius: 0.66667, x: 0, y: 1.33333)
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 1.33333, x: 0, y: 1.33333)
        }
    }

    @ViewBuilder private func radio(isSelected: Bool) -> some View {
        if isSelected {
            Circle()
                .fill(Design.Btns.Primary.bg.color(colorScheme))
                .frame(width: 20, height: 20)
                .overlay {
                    Asset.Assets.check.image
                        .zImage(size: 12, style: Design.Btns.Primary.fg)
                }
        } else {
            Circle()
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(Design.Checkboxes.offStroke.color(colorScheme), lineWidth: 1)
                }
        }
    }
}
