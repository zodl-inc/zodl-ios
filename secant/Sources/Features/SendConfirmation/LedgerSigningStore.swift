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
        /// The last scan, connect or signing failure -- drives the `LedgerIssueSheetContent` the
        /// sheet shows in place of its normal content while `phase == .failed`.
        var issue: LedgerIssue?
        /// Whether the view has already sent the user to Settings for a `.bluetoothUnauthorized`
        /// failure. Read only by `failedPrimaryAction` below.
        var hasOpenedSettings = false
        var isConnectionLost = false
        var request: SignRequest?

        /// `LedgerIssueSheetContent`'s primary button for the current `issue`, in the `.sign`
        /// context. Once the user has come back from Settings for `.bluetoothUnauthorized`
        /// (`hasOpenedSettings`), the sheet must offer a retry instead of Open Settings again --
        /// after "Open System Settings" the user comes back to a sheet that must offer a retry.
        var failedPrimaryAction: LedgerIssue.PrimaryAction {
            issue == .bluetoothUnauthorized && hasOpenedSettings ? .tryAgain : (issue?.primaryAction(in: .sign) ?? .none)
        }
    }

    enum Action: Equatable {
        case onAppear
        case startScanning
        case devicesUpdated([LedgerBluetoothDevice])
        case scanFailed(LedgerIssue)
        case scanTimedOut
        case deviceTapped(LedgerBluetoothDevice)
        case connect
        case deviceConnected
        case connectionFailed(LedgerIssue)
        case signRequested(State.SignRequest)
        case startSigningIfReady
        case signingProgressed(LedgerSigningProgress)
        case signed(Pczt)
        case signingFailed(issue: LedgerIssue, connectionLost: Bool)
        case openSettingsTapped
        case tryAgainTapped
        case stopScanning
    }

    // Not `private`: the parent (`SendConfirmation`) cancels both directly from `.resetPCZTs`.
    enum CancelId {
        case scan
        case sign
    }

    @Dependency(\.continuousClock) var clock
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
                state.issue = nil
                state.hasOpenedSettings = false
                state.devices = []
                // The scan and the no-devices timer run as sibling child tasks of the SAME
                // effect, rather than the timer racing a separate `.cancellable` -- so the timer
                // can never outlive the scan it is timing. Whichever finishes first cancels the
                // other; when the timer fires first the scan keeps running. Mirrors
                // `AddLedgerHWWalletStore.startScanning`.
                return .run { send in
                    await withTaskGroup(of: Bool.self) { group in
                        group.addTask {                       // the scan; `true` = the scan ended
                            do {
                                for try await batch in ledgerClient.scanDevices() {
                                    await send(.devicesUpdated(batch))
                                }
                            } catch {
                                await send(.scanFailed(LedgerIssue(error)))
                            }
                            return true
                        }
                        group.addTask {                       // the no-devices timer
                            do {
                                try await clock.sleep(for: LedgerIssue.noDevicesFoundTimeout)
                                await send(.scanTimedOut)
                            } catch {}
                            return false
                        }
                        while let scanEnded = await group.next() {
                            if scanEnded {
                                group.cancelAll()
                                break
                            }
                        }
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

            case let .scanFailed(issue):
                // Same shape as `connectionFailed`: a scan-level failure (e.g. Bluetooth powered
                // off) leaves nothing to retry in place -- `tryAgainTapped` must rescan, not
                // resume a signing attempt that never had a device.
                state.phase = .failed
                state.issue = issue
                state.isConnectionLost = true
                return .none

            case .scanTimedOut:
                // Ignored once a device has already turned up, or once the scan is no longer the
                // one running (it already failed, was cancelled, or already timed out once).
                guard state.phase == .scanning, state.devices.isEmpty else { return .none }
                state.phase = .failed
                state.issue = .noDevicesFound
                state.isConnectionLost = true
                return .cancel(id: CancelId.scan)

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
                            await send(.connectionFailed(LedgerIssue(error)))
                        }
                    }
                )

            case .deviceConnected:
                state.phase = .connected
                return .send(.startSigningIfReady)

            case let .connectionFailed(issue):
                // A connect failure always leaves the transport unusable, so it is reported as
                // connection-lost regardless of what `LedgerIssue(error).retryNeedsNewConnection`
                // would classify the underlying error as -- same rule AddLedgerHWWallet's own
                // `connectDeviceTapped` follows.
                state.phase = .failed
                state.issue = issue
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
                        let issue = LedgerIssue(error)
                        await send(.signingFailed(issue: issue, connectionLost: issue.retryNeedsNewConnection))
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

            case let .signingFailed(issue, connectionLost):
                state.phase = .failed
                state.issue = issue
                state.isConnectionLost = connectionLost
                return .none

            case .openSettingsTapped:
                // The view has already opened Settings itself before sending this.
                state.hasOpenedSettings = true
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
                state.issue = nil
                return .send(.startSigningIfReady)

            case .stopScanning:
                return .cancel(id: CancelId.scan)
            }
        }
    }
}
