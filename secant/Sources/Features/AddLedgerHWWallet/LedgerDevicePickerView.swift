//
//  LedgerDevicePickerView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: the Bluetooth device list ConnectHWWalletCoordFlow pushes once the
//  instructions screen's CTA is tapped. Per the Figma "Select Your Device" review, this is now
//  the one screen that finds, selects, connects and pairs the Ledger — there is no separate
//  "Approve on your Ledger" screen; the export prompt is explained in place via the status line
//  below the list. Row styling mirrors AccountsSelectionView's account row; the busy Connect
//  button mirrors KeystoneDeviceReadyView's accessoryView pattern. A scan/connect/pair failure
//  shows as a LedgerIssueSheetContent sheet (MOB-2020 error states) on top of this screen; a
//  swipe-dismiss leaves only the bottom Try again to retry.
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
                    .frame(height: 32)
                    .padding(.top, 16)

                Text(localizable: store.devices.isEmpty ? .ledgerDevicePickerSearchingTitle : .ledgerDevicePickerTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: store.devices.isEmpty ? .ledgerDevicePickerSearchingDesc : .ledgerDevicePickerDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                if store.devices.isEmpty {
                    skeletonDeviceList()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.devices) { device in
                                deviceRow(device)
                            }
                        }
                    }
                    .padding(.top, 24)
                }

                if store.isPairing {
                    Text(localizable: .ledgerDevicePickerConfirmOnDevice)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .lineSpacing(1.5)
                        .padding(.top, 16)
                }

                Spacer()

                if store.isScanning && store.devices.isEmpty {
                    ZashiButton(
                        String(localizable: .ledgerDevicePickerSearching),
                        prefixView: ProgressView()
                    ) { }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else if store.isConnecting || store.isPairing {
                    ZashiButton(
                        String(localizable: .keystoneAddHWWalletConnect),
                        accessoryView: ProgressView()
                    ) {
                        store.send(.connectDeviceTapped)
                    }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else if store.canRescan {
                    ZashiButton(String(localizable: .ledgerIssueTryAgain)) {
                        store.send(.startScanning)
                    }
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(
                        store.issue != nil
                        ? String(localizable: .ledgerIssueTryAgain)
                        : String(localizable: .keystoneAddHWWalletConnect)
                    ) {
                        store.send(.connectDeviceTapped)
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

    // Figma "Search for devices" (1073:10702): three shimmer skeleton cards stand in for the
    // device list while `store.devices` is empty, whether or not a scan is currently running —
    // the shimmer itself keys off `store.isScanning`. The bottom fade uses `Asset.Colors.background`,
    // not `.clear` or white, so it matches whatever `applyScreenBackground()` painted in both color
    // schemes. A plain `VStack`, not a `ScrollView`.
    @ViewBuilder private func skeletonDeviceList() -> some View {
        VStack(spacing: 12) {
            skeletonCard()
            skeletonCard()
            skeletonCard()
        }
        .padding(.top, 32)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Asset.Colors.background.color.opacity(0), Asset.Colors.background.color],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 164)
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    // Same placeholder chain as `NoTransactionPlaceholder`: `.fill(...)` -> `.shimmer(...)` ->
    // `.clipShape(...)` -> `.frame(...)`, one per shape, so the shimmer gradient is clipped to
    // each shape rather than the shape's bounding box.
    @ViewBuilder private func skeletonCard() -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(store.isScanning)
                .clipShape(Circle())
                .frame(width: 32, height: 32)
                .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: Design.Radius._xs)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(store.isScanning)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius._xs))
                    .frame(width: 100, height: 16)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(store.isScanning)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: 68, height: 12)
            }

            Spacer()

            RoundedRectangle(cornerRadius: Design.Radius._sm)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(store.isScanning)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
                .frame(width: 20, height: 20)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
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
                    .padding(.trailing, 8)

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
                        get: { store.selectedDevice == device },
                        set: { _ in store.send(.deviceTapped(device)) }
                    )
                )
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
