//
//  AddLedgerHWWalletStore.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: connect a Ledger over Bluetooth. Mirrors AddKeystoneHWWallet's shape —
//  see AddHWWalletStore.swift — but drives the SDK's Bluetooth scan/pair API (LedgerClient)
//  instead of a QR-code scan.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct AddLedgerHWWallet {
    @ObservableState
    struct State: Equatable {
        var devices: [LedgerBluetoothDevice] = []
        var isScanning = false
        /// The current screen's status/error line: a scan failure while `devicePicker` is on
        /// screen, or a pairing failure while `pairing` is on screen. Each pushed screen owns a
        /// separate `AddLedgerHWWallet.State`, so the two never collide.
        var scanError: String? = nil
        var selectedDevice: LedgerBluetoothDevice? = nil
        var isConnecting = false
        var pairing: LedgerPairing? = nil
        var isPairing = false
        var isAccountSelected = false
        var isImportingAccount = false
        var isHelpSheetPresented = false
        var randomSuccessIconIndex = 0
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        /// The paired account's address, derived from the pairing's UFVK the same way Keystone's
        /// `keystoneAddress` is — empty when there is no pairing yet or derivation fails.
        var pairedAddress: String {
            @Dependency(\.derivationTool) var derivationTool
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

            guard let pairing else { return "" }

            do {
                return try derivationTool
                    .deriveUnifiedAddressFrom(pairing.ufvk, zcashSDKEnvironment.network().networkType)
                    .stringEncoded
            } catch {
                return ""
            }
        }

        var successIlustration: Image {
            switch randomSuccessIconIndex {
            case 1: return Asset.Assets.Illustrations.success1.image
            default: return Asset.Assets.Illustrations.success2.image
            }
        }

        init() { }
    }

    enum Action: BindableAction, Equatable {
        case accountImported(AccountUUID)
        case accountImportFailed(String)
        case accountImportSucceeded
        case accountTapped
        case backToHomeTapped
        case binding(BindingAction<AddLedgerHWWallet.State>)
        case closeTapped
        case connectTapped
        case deviceConnected
        case deviceConnectionFailed(String)
        case deviceTapped(LedgerBluetoothDevice)
        case devicesUpdated([LedgerBluetoothDevice])
        case forgetThisDeviceTapped
        case helpSheetRequested
        case loadedWalletAccounts([WalletAccount], AccountUUID)
        case nextTapped
        case onAppear
        case pairingFailed(message: String, connectionLost: Bool)
        case pairingSucceeded(LedgerPairing)
        case retryPairingTapped
        case scanFailed(String)
        case setBirthdayTapped
        case startPairing
        case startScanning
        case stopScanning
        case unlockTapped(BlockHeight?)
    }

    private enum CancelId {
        case scan
    }

    init() { }

    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.ledgerClient) var ledgerClient
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                state.devices = []
                state.isScanning = false
                state.scanError = nil
                state.selectedDevice = nil
                state.isConnecting = false
                state.pairing = nil
                state.isPairing = false
                state.isAccountSelected = false
                state.isImportingAccount = false
                state.randomSuccessIconIndex = Int.random(in: 1...2)
                return .none

            case .connectTapped:
                return .none

            case .startScanning:
                state.isScanning = true
                state.scanError = nil
                state.devices = []
                return .run { send in
                    do {
                        for try await batch in ledgerClient.scanDevices() {
                            await send(.devicesUpdated(batch))
                        }
                    } catch {
                        await send(.scanFailed(LedgerErrorText.message(for: error)))
                    }
                }
                .cancellable(id: CancelId.scan, cancelInFlight: true)

            case let .devicesUpdated(devices):
                state.devices = devices
                return .none

            case let .scanFailed(message):
                state.isScanning = false
                state.scanError = message
                return .cancel(id: CancelId.scan)

            case .stopScanning:
                state.isScanning = false
                return .cancel(id: CancelId.scan)

            case let .deviceTapped(device):
                state.selectedDevice = device
                state.isConnecting = true
                state.scanError = nil
                return .run { send in
                    do {
                        try await ledgerClient.connect(device)
                        await send(.deviceConnected)
                    } catch {
                        await send(.deviceConnectionFailed(LedgerErrorText.message(for: error)))
                    }
                }

            case .deviceConnected:
                state.isConnecting = false
                return .cancel(id: CancelId.scan)

            case let .deviceConnectionFailed(message):
                state.isConnecting = false
                state.scanError = message
                return .none

            case .startPairing:
                state.isPairing = true
                state.scanError = nil
                return .run { send in
                    do {
                        let pairing = try await ledgerClient.pairAccount(Zip32AccountIndex(0))
                        await send(.pairingSucceeded(pairing))
                    } catch {
                        await send(
                            .pairingFailed(
                                message: LedgerErrorText.message(for: error),
                                connectionLost: LedgerErrorText.isConnectionLost(error)
                            )
                        )
                    }
                }

            case let .pairingSucceeded(pairing):
                state.isPairing = false
                state.pairing = pairing
                return .none

            case let .pairingFailed(message, _):
                state.isPairing = false
                state.scanError = message
                return .none

            case .retryPairingTapped:
                return .send(.startPairing)

            case .accountTapped:
                state.isAccountSelected.toggle()
                return .none

            case .nextTapped:
                return .none

            case .setBirthdayTapped:
                return .none

            case let .unlockTapped(birthday):
                guard let pairing = state.pairing, !state.isImportingAccount else {
                    return .none
                }
                state.isImportingAccount = true
                return .run { send in
                    do {
                        let uuid = try await sdkSynchronizer.importAccount(
                            pairing.ufvk,
                            nil,
                            nil,
                            .spending,
                            String(localizable: .accountsLedger),
                            Account.ledgerKeySource,
                            birthday
                        )
                        guard let uuid else {
                            // The live SDK never returns nil today, but the interface permits it;
                            // treat it as a failure so isImportingAccount can't be left stuck true.
                            await send(.accountImportFailed("Ledger account import returned no account UUID"))
                            return
                        }
                        do {
                            try walletStorage.importLedgerBinding(pairing.binding, uuid)
                        } catch {
                            await send(.accountImportFailed(error.localizedDescription))
                            return
                        }
                        await send(.accountImported(uuid))
                    } catch {
                        // Surface only the SDK error's localizedDescription (a static code +
                        // message); the raw Rust error string is never included, so no
                        // UFVK/binding/device-identity data can leak.
                        await send(.accountImportFailed(error.localizedDescription))
                    }
                }

            case let .accountImported(uuid):
                return .run { send in
                    do {
                        let walletAccounts = try await sdkSynchronizer.walletAccounts()
                        await send(.loadedWalletAccounts(walletAccounts, uuid))
                        await send(.accountImportSucceeded)
                    } catch {
                        await send(.accountImportFailed(error.localizedDescription))
                    }
                }

            case .accountImportFailed:
                state.isImportingAccount = false
                return .none

            case .accountImportSucceeded:
                state.isImportingAccount = false
                return .run { _ in
                    await ledgerClient.disconnect()
                }

            case let .loadedWalletAccounts(walletAccounts, uuid):
                // MOB-1859: preserve any rotation stash the in-memory accounts already carried,
                // same as AddKeystoneHWWallet's own handler.
                let mergedWalletAccounts = WalletAccount.mergingPrivateUAStash(from: state.walletAccounts, into: walletAccounts)
                state.$walletAccounts.withLock { $0 = mergedWalletAccounts }
                for walletAccount in mergedWalletAccounts {
                    if walletAccount.id == uuid {
                        state.$selectedWalletAccount.withLock { $0 = walletAccount }
                        break
                    }
                }
                return .none

            case .forgetThisDeviceTapped:
                return .run { _ in await ledgerClient.disconnect() }

            case .backToHomeTapped:
                return .run { _ in await ledgerClient.disconnect() }

            case .closeTapped:
                return .run { _ in await ledgerClient.disconnect() }

            case .helpSheetRequested:
                state.isHelpSheetPresented.toggle()
                return .none

            case .binding:
                return .none
            }
        }
    }
}
