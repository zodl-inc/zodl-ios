//
//  LedgerDevicePickerView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: the Bluetooth device list AddLedgerHWWalletCoordFlow pushes once the
//  instructions screen's CTA is tapped. Row styling mirrors AccountsSelectionView's account row.
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
                Text(localizable: .ledgerDevicePickerTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: .ledgerDevicePickerDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                if let scanError = store.scanError {
                    Text(scanError)
                        .zFont(size: 14, style: Design.Utility.ErrorRed._700)
                        .lineSpacing(1.5)
                        .padding(.top, 24)
                } else if store.devices.isEmpty {
                    VStack(spacing: 0) {
                        ProgressView()
                            .padding(.bottom, 12)

                        Text(localizable: .ledgerDevicePickerScanning)
                            .zFont(size: 14, style: Design.Text.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
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

                Spacer()
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.startScanning) }
            .onDisappear { store.send(.stopScanning) }
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
        }
        .applyScreenBackground()
    }

    @ViewBuilder private func deviceRow(_ device: LedgerBluetoothDevice) -> some View {
        Button {
            store.send(.deviceTapped(device))
        } label: {
            HStack(spacing: 0) {
                Asset.Assets.Partners.ledgerLogo.image
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

                if store.isConnecting && store.selectedDevice == device {
                    ProgressView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._3xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
        }
        .disabled(store.isConnecting)
    }
}
