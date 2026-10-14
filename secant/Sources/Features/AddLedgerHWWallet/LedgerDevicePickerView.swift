//
//  LedgerDevicePickerView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: the Bluetooth device list ConnectHWWalletCoordFlow pushes once the Turn On
//  and Unlock step's Continue is tapped. Restyled to Figma's step 2 (1599:11869 searching,
//  1599:11500 unselected, 1599:11578 selected, part of node 1599:12387's frame): the shared step
//  header/nav title, a back arrow that pops to step 1 instead of a close X that left the whole
//  flow, and a device row redrawn as a single-line name with a radio instead of ZashiToggle. This
//  screen finds and selects the Ledger; Connect (`.approveOnDeviceTapped`) bonds right here, and
//  its button reflects isConnecting while that bond runs, the way the searching state's button
//  already reflects isScanning -- the coordinator pushes the Approve on Your Device screen
//  (LedgerApproveOnDeviceView), which runs the actual connect-and-pair, only once the bond
//  settles. A scan failure shows as a LedgerIssueSheetContent sheet (MOB-2020 error states) on top
//  of this screen; a swipe-dismiss leaves only the bottom Try again to retry. The placeholder rows
//  are LedgerDeviceSkeletons, shared with the approve screen.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK

struct LedgerDevicePickerView: View {
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                LedgerStepHeader(
                    title: String(localizable: store.isShowingSearchingCopy ? .ledgerDevicePickerSearchingTitle : .ledgerDevicePickerTitle),
                    subtitle: String(localizable: store.isShowingSearchingCopy ? .ledgerDevicePickerSearchingDesc : .ledgerDevicePickerDesc)
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

                            // MOB-2020: part of the list, not pinned above Connect -- scrolls
                            // with the device rows instead of sitting fixed at the bottom.
                            LedgerAdvancedOptionsCard(
                                isExpanded: store.isAdvancedOptionsExpanded,
                                accountIndexText: $store.accountIndexText,
                                isAccountIndexValid: store.selectedAccountIndex != nil,
                                isConnecting: store.isConnecting,
                                onToggle: { store.send(.advancedOptionsToggleTapped) }
                            )
                        }
                    }
                    .padding(.top, 24)
                    // MOB-2020: .numberPad has no Return key, and nothing else here dismisses it
                    // -- without this, Connect can end up under the keyboard on small screens.
                    .scrollDismissesKeyboard(.interactively)
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
            // MOB-2020: `.pairing`, not `.connect` -- this sheet shows both a scan failure and a
            // step 2 bond failure, and the two contexts' copy differs only for `.deviceLocked`.
            LedgerIssueSheetContent(issue: issue, context: .pairing) {
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
            // MOB-2020: `.approveOnDeviceTapped` sets this while the phone bonds with the
            // selected Ledger. Android keeps "Connect" with a spinner here rather than reusing
            // the sign sheet's own status string, which can reword independently of this screen.
            ZashiButton(
                String(localizable: .keystoneAddHWWalletConnect),
                minHeight: 48,
                prefixView: ProgressView()
            ) { }
            .disabled(true)
        } else {
            // MOB-2020: Connect sends `.approveOnDeviceTapped`, which bonds right on this
            // screen -- never `.connectDeviceTapped` here. The coordinator pushes the Open the
            // Zcash App and/or Approve on Your Device screens only once `.deviceBonded` reports
            // the bond's outcome.
            ZashiButton(
                store.issue != nil
                ? String(localizable: .ledgerIssueTryAgain)
                : String(localizable: .keystoneAddHWWalletConnect),
                minHeight: 48
            ) {
                store.send(.approveOnDeviceTapped)
            }
            // MOB-2020: an invalid account index disables Connect on top of the existing
            // no-selection condition.
            .disabled(store.selectedDevice == nil || store.selectedAccountIndex == nil)
        }
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice) -> some View {
        let isSelected = store.selectedDevice?.id == device.id

        Button {
            store.send(.deviceTapped(device))
        } label: {
            LedgerDeviceCard(device: device, isSelected: isSelected)
        }
        .disabled(store.isConnecting)
        // MOB-2020: on the Button itself, the element VoiceOver reads, not the card label
        // underneath it.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
