//
//  LedgerSigningStore.swift
//  Zashi
//
//  MOB-2020 Phase 3.2: signs a PCZT with a connected Ledger from inside the send confirmation
//  flow -- the signing counterpart to AddLedgerHWWallet's scan/connect (Phase 1.3), reused here
//  for the ceremony rather than for pairing. `SendConfirmationStore.swift` owns the PCZT machine
//  (proposal -> PCZT -> proofs -> submit) and hands this child reducer the pczt/account/binding
//  once it is ready to be signed; this reducer owns only finding the device, connecting, and
//  running the signing ceremony.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct LedgerSigning {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case scanning
            case selectingDevice
            case connecting
            case connected
            case signing(LedgerSigningProgress)
            case signed
            case failed
        }

        /// What to sign, and with which account/binding, once a device is connected. Set by the
        /// parent's `.ledgerSignRequest` (possibly before the device is even chosen) and kept
        /// across a reconnect so a lost connection can resume signing once `tryAgainTapped` gets a
        /// fresh transport open again.
        struct SignRequest: Equatable {
            let pczt: Pczt
            let accountUUID: AccountUUID
            let binding: LedgerAccountBinding
        }

        var devices: [LedgerBluetoothDevice] = []
        var selectedDevice: LedgerBluetoothDevice?
        var phase: Phase = .scanning
        var errorMessage: String?
        var isRestartable = false
        var isConnectionLost = false
        var request: SignRequest?
    }

    enum Action: Equatable {
        case onAppear
        case startScanning
        case devicesUpdated([LedgerBluetoothDevice])
        case scanFailed(String)
        case deviceTapped(LedgerBluetoothDevice)
        case connect
        case deviceConnected
        case connectionFailed(String)
        case signRequested(State.SignRequest)
        case startSigningIfReady
        case signingProgressed(LedgerSigningProgress)
        case signed(Pczt)
        case signingFailed(message: String, restartable: Bool, connectionLost: Bool)
        case tryAgainTapped
        case stopScanning
    }

    // Not `private`: the parent (`SendConfirmation`) cancels both directly from `.resetPCZTs`.
    enum CancelId {
        case scan
        case sign
    }

    @Dependency(\.ledgerClient) var ledgerClient

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let request = state.request
                state = State()
                state.request = request
                return .send(.startScanning)

            case .startScanning:
                state.phase = .scanning
                state.errorMessage = nil
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
                guard state.phase == .scanning else {
                    return .none
                }
                if devices.count == 1, let device = devices.first {
                    state.selectedDevice = device
                    return .send(.connect)
                } else if devices.count > 1 {
                    state.phase = .selectingDevice
                }
                return .none

            case let .scanFailed(message):
                // Same shape as `connectionFailed`: a scan-level failure (e.g. Bluetooth powered
                // off) leaves nothing to retry in place -- `tryAgainTapped` must rescan, not
                // resume a signing attempt that never had a device.
                state.phase = .failed
                state.errorMessage = message
                state.isRestartable = true
                state.isConnectionLost = true
                return .none

            case let .deviceTapped(device):
                state.selectedDevice = device
                return .send(.connect)

            case .connect:
                guard let device = state.selectedDevice, state.phase != .connecting else {
                    return .none
                }
                state.phase = .connecting
                return .merge(
                    .cancel(id: CancelId.scan),
                    .run { send in
                        do {
                            try await ledgerClient.connect(device)
                            await send(.deviceConnected)
                        } catch {
                            await send(.connectionFailed(LedgerErrorText.message(for: error)))
                        }
                    }
                )

            case .deviceConnected:
                state.phase = .connected
                return .send(.startSigningIfReady)

            case let .connectionFailed(message):
                // A connect failure always leaves the transport unusable, so it is reported as
                // connection-lost regardless of what `LedgerErrorText.isConnectionLost` would
                // classify the underlying error as -- same rule AddLedgerHWWallet's own
                // `connectDeviceTapped` follows.
                state.phase = .failed
                state.errorMessage = message
                state.isRestartable = true
                state.isConnectionLost = true
                return .none

            case let .signRequested(request):
                state.request = request
                return .send(.startSigningIfReady)

            case .startSigningIfReady:
                guard state.phase == .connected, let request = state.request else {
                    return .none
                }
                state.phase = .signing(.identifyingDevice)
                return .run { send in
                    do {
                        for try await event in ledgerClient.signPCZT(request.pczt, request.accountUUID, request.binding) {
                            switch event {
                            case let .progress(stage):
                                await send(.signingProgressed(stage))
                            case let .signed(pczt):
                                await send(.signed(pczt))
                            }
                        }
                    } catch {
                        await send(
                            .signingFailed(
                                message: LedgerErrorText.signingMessage(for: error),
                                restartable: LedgerErrorText.isRestartable(error),
                                connectionLost: LedgerErrorText.isConnectionLost(error)
                            )
                        )
                    }
                }
                .cancellable(id: CancelId.sign, cancelInFlight: true)

            case let .signingProgressed(stage):
                state.phase = .signing(stage)
                return .none

            case .signed:
                state.phase = .signed
                // The parent (`SendConfirmation`) observes `.ledgerSigning(.signed)` and drives
                // `createTransactionFromPCZT` -- nothing further to do here.
                return .none

            case let .signingFailed(message, restartable, connectionLost):
                state.phase = .failed
                state.errorMessage = message
                state.isRestartable = restartable
                state.isConnectionLost = connectionLost
                return .none

            case .tryAgainTapped:
                if state.isConnectionLost {
                    // The kept `request` makes signing resume automatically once the reconnect
                    // (auto-connect on a single device, or a fresh tap) lands on `.connected`.
                    state.devices = []
                    state.selectedDevice = nil
                    state.phase = .scanning
                    return .send(.startScanning)
                }
                state.phase = .connected
                return .send(.startSigningIfReady)

            case .stopScanning:
                return .cancel(id: CancelId.scan)
            }
        }
    }
}
