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
            // MOB-2020: the Bluetooth link is open and `LedgerSession.connect` has asked the
            // device which app it runs and found it isn't the Zcash app -- the on-device "Open
            // Zcash?" prompt is showing. No Figma node covers this state; the sheet's copy
            // (`ledger.signWith.openingApp`) is a placeholder until product sends final wording.
            case openingZcashApp
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
        /// Set on a `.deviceMismatch` failure (the wrong Ledger connected) and cleared once the
        /// user taps a device. While set, the next scan shows the picker even for a lone device
        /// instead of auto-connecting to it -- that lone device may be the same wrong Ledger.
        var isPickerRequired = false
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
        // MOB-2020: `LedgerSession.connect`'s own report that it is about to ask the device to
        // open the Zcash app (the device isn't already running it) -- moves `.connecting` to
        // `.openingZcashApp` so the sheet can tell the user to look at the device.
        case openingZcashApp
        case deviceConnected
        case connectionFailed(LedgerIssue)
        case signRequested(State.SignRequest)
        // MOB-2020: sent by the parent's `.ledgerSignRequest` in place of `.signRequested` when
        // the account has no stored Ledger binding at all -- there is no pczt/account/binding to
        // hand over, so this fails the ceremony directly instead of ever reaching `.connected`.
        case pairingMissing
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
        // MOB-2020: the empty-picker timeout below. Chained onto `.scan` (never on its own),
        // so cancelling the scan -- every existing call site already does, and the parent's
        // `.resetPCZTs`/`.ledgerSignCancelTapped` need no changes -- cancels this too, while a
        // device reappearing can still cancel just this timer without touching the live scan.
        case pickerTimer
    }

    /// `.connect`'s outcome once its connect effect and the approval-timeout race
    /// (`LedgerIssue.racingApprovalTimeout`) have settled.
    private enum ConnectOutcome: Sendable {
        case connected
        case failed(LedgerIssue)
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
                                await send(.scanFailed(LedgerIssue(error, in: .sign)))
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
                if state.phase == .scanning {
                    // MOB-2020: a lone device auto-connects UNLESS the last session already met
                    // the wrong Ledger -- that lone device may be the very same wrong one, so the
                    // picker shows it instead of reconnecting silently.
                    if devices.count == 1, let device = devices.first, !state.isPickerRequired {
                        state.selectedDevice = device
                        return .send(.connect)
                    } else if !devices.isEmpty {
                        state.phase = .selectingDevice
                    }
                    return .none
                }
                // MOB-2020: once the picker is showing, every device dropping out of range must
                // not hang forever -- start the same no-devices timer the scan's own timeout
                // uses, restarted (`cancelInFlight: true`) each time the list re-empties, and
                // cancelled below the moment a device is back.
                guard state.phase == .selectingDevice else {
                    return .none
                }
                guard devices.isEmpty else {
                    return .cancel(id: CancelId.pickerTimer)
                }
                return .run { send in
                    do {
                        try await clock.sleep(for: LedgerIssue.noDevicesFoundTimeout)
                        await send(.scanTimedOut)
                    } catch {}
                }
                .cancellable(id: CancelId.pickerTimer, cancelInFlight: true)
                .cancellable(id: CancelId.scan)

            case let .scanFailed(issue):
                // Same shape as `connectionFailed`: a scan-level failure (e.g. Bluetooth powered
                // off) leaves nothing to retry in place -- `tryAgainTapped` must rescan, not
                // resume a signing attempt that never had a device.
                state.phase = .failed
                state.issue = issue
                state.isConnectionLost = true
                // The scan child task group cancels its OWN no-devices timer internally; the
                // picker's empty-list timer, started later from `devicesUpdated`, is a separate
                // effect and needs its own cancel.
                return .cancel(id: CancelId.pickerTimer)

            case .scanTimedOut:
                // Ignored once a device has already turned up, or once neither timer's phase is
                // still current (already failed, was cancelled, or already timed out once).
                guard state.phase == .scanning || state.phase == .selectingDevice, state.devices.isEmpty else {
                    return .none
                }
                state.phase = .failed
                state.issue = .noDevicesFound
                state.isConnectionLost = true
                return .cancel(id: CancelId.scan)

            case let .deviceTapped(device):
                state.selectedDevice = device
                // A tap answers "is this the right Ledger" itself -- the flag's job (skip the
                // silent one-device auto-connect) is done once the user has chosen explicitly.
                state.isPickerRequired = false
                return .send(.connect)

            case .connect:
                // MOB-2020: `.openingZcashApp` is still mid-connect (the report already fired,
                // the connect effect hasn't settled) -- the same non-cancellable-effect guard
                // `.connecting` has always needed, extended to cover it too.
                guard let device = state.selectedDevice, state.phase != .connecting, state.phase != .openingZcashApp else {
                    return .none
                }
                state.phase = .connecting
                return .merge(
                    .cancel(id: CancelId.scan),
                    .run { send in
                        // MOB-2020: caps the on-device "Open Zcash?" prompt this connect can wait
                        // on -- never the on-device transaction review later in the ceremony,
                        // which this effect has already finished by the time that starts.
                        let outcome = await LedgerIssue.racingApprovalTimeout(clock: clock) { () -> ConnectOutcome in
                            do {
                                try await ledgerClient.connect(device) {
                                    await send(.openingZcashApp)
                                }
                                return .connected
                            } catch {
                                return .failed(LedgerIssue(error, in: .sign))
                            }
                        }
                        switch outcome {
                        case .completed(.connected):
                            await send(.deviceConnected)
                        case let .completed(.failed(issue)):
                            await send(.connectionFailed(issue))
                        case .timedOut:
                            // The race above already cancelled the connect; only the cleanup is
                            // left, the same way `AddLedgerHWWalletStore.connectDeviceTapped`
                            // handles its own cap winning.
                            await ledgerClient.disconnect()
                            await send(.connectionFailed(.disconnected))
                        }
                    }
                )

            case .openingZcashApp:
                // MOB-2020: a late report must not resurrect a ceremony that already failed or
                // moved on -- same non-cancellable-`connect` reasoning as `.deviceConnected` and
                // `.connectionFailed` below, which is also why they now accept this phase too.
                guard state.phase == .connecting else { return .none }
                state.phase = .openingZcashApp
                return .none

            case .deviceConnected:
                // `.connect`'s effect is not cancellable, so a connect already in flight can still
                // report back later -- a late result must not overwrite a ceremony that already
                // failed (e.g. via `.pairingMissing`). `.openingZcashApp` is still that same
                // in-flight connect, just past its report.
                guard state.phase == .connecting || state.phase == .openingZcashApp else { return .none }
                state.phase = .connected
                return .send(.startSigningIfReady)

            case let .connectionFailed(issue):
                // Same non-cancellable-`connect` reasoning as `.deviceConnected` above: a late
                // result must not overwrite a ceremony that already failed.
                guard state.phase == .connecting || state.phase == .openingZcashApp else { return .none }
                // A connect failure always leaves the transport unusable, so it is reported as
                // connection-lost regardless of what
                // `LedgerIssue(error, in: .sign).retryNeedsNewConnection(in: .sign)` would classify
                // the underlying error as -- same rule AddLedgerHWWallet's own `connectDeviceTapped`
                // follows.
                state.phase = .failed
                state.issue = issue
                state.isConnectionLost = true
                // MOB-2020: a wrong-Ledger connect (the SDK checked the device before the sign
                // request even landed) gets the same picker-on-next-scan treatment signing's own
                // `.deviceMismatch` does below.
                if issue == .deviceMismatch {
                    state.isPickerRequired = true
                }
                return .none

            case let .signRequested(request):
                state.request = request
                return .send(.startSigningIfReady)

            case .pairingMissing:
                // No device is ever going to sign for this account -- fail the ceremony outright
                // and cancel any scan/sign still in flight (the `connect` effect can't be
                // cancelled; the guards above handle a late result from it).
                state.phase = .failed
                state.issue = .notPaired
                state.isConnectionLost = false
                return .merge(.cancel(id: CancelId.scan), .cancel(id: CancelId.sign))

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
                        let issue = LedgerIssue(error, in: .sign)
                        await send(.signingFailed(issue: issue, connectionLost: issue.retryNeedsNewConnection(in: .sign)))
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
                // MOB-2020: after the wrong Ledger, the NEXT scan must show the picker even for a
                // lone device instead of silently reconnecting to what may be that same device.
                if issue == .deviceMismatch {
                    state.isPickerRequired = true
                }
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
