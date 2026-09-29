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
        /// The last scan, connect or pair failure -- drives the issue sheet. Cleared whenever a
        /// device is (re-)selected or a new scan/connect attempt starts. The Approve on Your
        /// Device screen is now the only screen that connects and pairs — see
        /// ConnectHWWalletCoordFlowCoordinator.
        var issue: LedgerIssue? = nil
        /// Whether `issue`'s sheet is on screen. A swipe-to-dismiss clears only this flag, so
        /// `issue` stays set and the page keeps only its bottom Try again button -- a rescan
        /// when `canRescan`, otherwise a reconnect of the kept selection -- instead of losing
        /// the failure entirely.
        var isIssueSheetPresented = false
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

        /// Set only on the copy of the picker's state that
        /// `ConnectHWWalletCoordFlowCoordinator`'s `.ledgerDevicePicker(.deviceBonded)` arm pushes
        /// as the Approve on Your Device screen -- never on the picker's own state, which this
        /// same reducer also drives. `issuePrimaryTapped` reads it to tell a pairing issue's
        /// retry (reconnect the selected device -- this screen's only retry) from a bond or scan
        /// issue's retry (bond again, or rescan -- the picker's own retries): both share this
        /// reducer, and `selectedDevice` alone can't tell an approve-screen retry from a
        /// picker-screen retry once a device is selected while a stale issue is still showing.
        var isApproveScreen = false

        /// MOB-2020: set only on the copy of the picker's state the coordinator pushes as step 3
        /// (`.ledgerOpenApp`) when `.deviceBonded`'s device did NOT already report the Zcash app
        /// running -- that screen opens it automatically on first appearance only when this is
        /// `true`. `false` (the default) when step 3 is pushed idle, under step 4, because the
        /// device already ran the app, and on every other screen this reducer drives.
        var autoOpenZcashApp = false

        /// Whether the picker can offer its own Try again button below the (now empty) device
        /// list: there is a failure showing, and nothing else is already in flight or selected.
        var canRescan: Bool { issue != nil && !isScanning && !isConnecting && !isPairing && selectedDevice == nil }

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
        case accountAlreadyImported(WalletAccount?)
        case accountImported(AccountUUID)
        case accountImportFailed(String)
        case accountImportSucceeded
        case accountTapped
        /// The picker's Connect button (MOB-2020, Android aac01e65): bonds `selectedDevice` right
        /// here, on the picker element -- unlike before, nothing is pushed until the bond
        /// succeeds or fails. `deviceBonded` reports the outcome.
        case approveOnDeviceTapped
        case backToHomeTapped
        case binding(BindingAction<AddLedgerHWWallet.State>)
        /// Cancel and the Approve on Your Device screen's own back arrow. Cancels the
        /// connect-and-pair effect and disconnects; popping back to the picker is the
        /// coordinator's job (ConnectHWWalletCoordFlowStore), since this reducer runs before the
        /// element is removed from the path.
        case cancelTapped
        case closeTapped
        case connectDeviceTapped
        case connectTapped
        /// MOB-2020 (Android aac01e65): `approveOnDeviceTapped`'s `ledgerClient.bond` succeeded --
        /// carries whether the device already runs the Zcash app, which
        /// ConnectHWWalletCoordFlowCoordinator reads to decide what it pushes next.
        case deviceBonded(isZcashAppRunning: Bool)
        case deviceConnected
        case deviceTapped(LedgerBluetoothDevice)
        case devicesUpdated([LedgerBluetoothDevice])
        case forgetThisDeviceTapped
        case helpSheetRequested
        case issuePrimaryTapped
        case loadedWalletAccounts([WalletAccount], AccountUUID)
        case nextTapped
        case onAppear
        case pairingFailed(issue: LedgerIssue, connectionLost: Bool)
        case pairingSucceeded(LedgerPairing)
        case scanFailed(LedgerIssue)
        case scanTimedOut
        case setBirthdayTapped
        case startScanning
        case stopScanning
        case unlockTapped(BlockHeight?)
    }

    private enum CancelId {
        case scan
        case bond
        case connectAndPair
    }

    /// `connectDeviceTapped`'s outcome once its connect-then-pair effect and the approval-timeout
    /// race (`LedgerIssue.racingApprovalTimeout`) have settled.
    private enum ConnectAndPairOutcome: Sendable {
        case paired(LedgerPairing)
        case failed(issue: LedgerIssue, connectionLost: Bool)
    }

    init() { }

    @Dependency(\.continuousClock) var clock
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
                state.issue = nil
                state.isIssueSheetPresented = false
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
                state.issue = nil
                state.isIssueSheetPresented = false
                state.devices = []
                // The scan and the no-devices timer run as sibling child tasks of the SAME
                // effect, rather than the timer racing a separate `.cancellable` -- so the timer
                // can never outlive the scan it is timing. Whichever finishes first cancels the
                // other; when the timer fires first the scan keeps running.
                return .run { send in
                    await withTaskGroup(of: Bool.self) { group in
                        group.addTask {                       // the scan; `true` = the scan ended
                            do {
                                for try await batch in ledgerClient.scanDevices() {
                                    await send(.devicesUpdated(batch))
                                }
                            } catch {
                                await send(.scanFailed(LedgerIssue(error, in: .connect)))
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
                // The scan republishes a device each time its signal strength changes, so the
                // selection follows the same device's latest value, not the one that was tapped.
                if let selected = state.selectedDevice,
                   let refreshed = devices.first(where: { $0.id == selected.id }) {
                    state.selectedDevice = refreshed
                }
                return .none

            case .scanTimedOut:
                // Ignored once a device has already turned up, or once the scan is no longer the
                // one running (it already failed, was cancelled, or already timed out once).
                guard state.isScanning, state.devices.isEmpty else { return .none }
                state.isScanning = false
                state.issue = .noDevicesFound
                state.isIssueSheetPresented = true
                return .cancel(id: CancelId.scan)

            case let .scanFailed(issue):
                state.isScanning = false
                state.issue = issue
                state.isIssueSheetPresented = true
                return .cancel(id: CancelId.scan)

            case .stopScanning:
                state.isScanning = false
                return .cancel(id: CancelId.scan)

            case let .deviceTapped(device):
                state.selectedDevice = device
                state.issue = nil
                state.isIssueSheetPresented = false
                return .none

            case .approveOnDeviceTapped:
                // MOB-2020 (Android 48b8d5bc, 6c9491c7, e3480698): bonds right here, on the
                // picker, instead of pushing first -- a first Bluetooth pairing with the Zcash
                // app already open freezes the device on its pairing screen, so nothing opens the
                // app until the bond (and this device's already-running-app answer) is in.
                guard let device = state.selectedDevice, !state.isConnecting, !state.isPairing else {
                    return .none
                }
                state.isConnecting = true
                state.issue = nil
                state.isIssueSheetPresented = false
                state.isScanning = false
                return .merge(
                    .cancel(id: CancelId.scan),
                    .run { send in
                        do {
                            let isZcashAppRunning = try await ledgerClient.bond(device)
                            await send(.deviceBonded(isZcashAppRunning: isZcashAppRunning))
                        } catch {
                            let issue = LedgerIssue(error, in: .connect, bonding: true)
                            await send(.pairingFailed(issue: issue, connectionLost: true))
                        }
                    }
                    .cancellable(id: CancelId.bond, cancelInFlight: true)
                )

            case .deviceBonded:
                // ConnectHWWalletCoordFlowCoordinator's own arm for this action reads
                // `isZcashAppRunning` and does the actual pushing (coordinatorReduce() runs
                // before this reducer, per TCA's ordering) -- nothing else to do with it here.
                state.isConnecting = false
                return .none

            case .connectDeviceTapped:
                guard let device = state.selectedDevice, !state.isConnecting, !state.isPairing else {
                    return .none
                }
                state.isConnecting = true
                state.issue = nil
                state.isIssueSheetPresented = false
                return .run { send in
                    let outcome = await LedgerIssue.racingApprovalTimeout(clock: clock) { () -> ConnectAndPairOutcome in
                        do {
                            try await ledgerClient.connect(device)
                        } catch {
                            // A connect failure always leaves the transport unusable, so it is
                            // reported as needing a new connection even when
                            // `LedgerIssue(error, in: .connect).retryNeedsNewConnection(in: .connect)`
                            // would say otherwise for this same underlying error.
                            return .failed(issue: LedgerIssue(error, in: .connect), connectionLost: true)
                        }

                        await send(.deviceConnected)

                        do {
                            let pairing = try await ledgerClient.pairAccount(Zip32AccountIndex(0))
                            return .paired(pairing)
                        } catch {
                            let issue = LedgerIssue(error, in: .connect)
                            return .failed(issue: issue, connectionLost: issue.retryNeedsNewConnection(in: .connect))
                        }
                    }
                    switch outcome {
                    case let .completed(.paired(pairing)):
                        await send(.pairingSucceeded(pairing))
                    case let .completed(.failed(issue, connectionLost)):
                        await send(.pairingFailed(issue: issue, connectionLost: connectionLost))
                    case .timedOut:
                        // MOB-2020: the user's approval on the device must not keep enrollment
                        // waiting forever -- the race above already cancelled the connect/pair
                        // work, so only the cleanup is left: close the transport and report it
                        // the same way any other lost connection is.
                        await ledgerClient.disconnect()
                        await send(.pairingFailed(issue: .disconnected, connectionLost: true))
                    }
                }
                // MOB-2020: the Approve on Your Device screen's Cancel and back arrow cancel
                // this same effect (`CancelId.connectAndPair`) -- today it was not cancellable,
                // so leaving mid-pairing left it running to completion in the background.
                .cancellable(id: CancelId.connectAndPair, cancelInFlight: true)

            case .deviceConnected:
                state.isConnecting = false
                state.isPairing = true
                // The scan is cancelled below; isScanning must say so too, since nothing else
                // flips it back once the effect it belonged to is torn down.
                state.isScanning = false
                return .cancel(id: CancelId.scan)

            case let .pairingSucceeded(pairing):
                state.isPairing = false
                state.pairing = pairing
                return .none

            case let .pairingFailed(issue, _):
                state.isConnecting = false
                state.isPairing = false
                state.issue = issue
                state.isIssueSheetPresented = true
                // MOB-2020: this now fires only on the Approve on Your Device screen (the picker
                // no longer connects or pairs itself), which has no scan to fall back on -- so a
                // failure here always keeps `selectedDevice` and `devices`, even one that lost
                // the connection, so Retry (`issuePrimaryTapped`) can reconnect the same device.
                return .none

            case .issuePrimaryTapped:
                state.isIssueSheetPresented = false
                // Only `.tryAgain` needs a follow-up action here: for `.openSettings` the view
                // has already opened Settings before sending this, and every other action
                // (`.goToAccount`, `.close`, `.none`) just dismisses the sheet, which the line
                // above already did.
                guard state.issue?.primaryAction(in: .connect) == .tryAgain else { return .none }
                // MOB-2020 (Android aac01e65): the Approve on Your Device screen always
                // reconnects and pairs again with the same device (`isApproveScreen`, not
                // `selectedDevice`, tells its retry apart -- see that property's doc comment).
                // The picker itself now bonds on Connect, so ITS retry needs telling apart too:
                // a kept selection (a bond failure) bonds that same device again; no selection
                // (a plain scan failure) rescans, as before.
                if state.isApproveScreen {
                    return .send(.connectDeviceTapped)
                } else if state.selectedDevice != nil {
                    return .send(.approveOnDeviceTapped)
                } else {
                    return .send(.startScanning)
                }

            case .cancelTapped:
                // Popping back to the picker is the coordinator's job -- see the doc comment on
                // this case. Here: cancel the in-flight connect-and-pair (a no-op if it already
                // finished) and disconnect, the same two things `.forgetThisDeviceTapped` and
                // friends already do when leaving the flow entirely.
                return .merge(
                    .cancel(id: CancelId.connectAndPair),
                    .run { _ in await ledgerClient.disconnect() }
                )

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
                let walletAccounts = state.walletAccounts
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
                            // MOB-2020: a binding that never got stored leaves the account
                            // permanently unsignable, so the import is rolled back before the
                            // failure is reported. Run in an unstructured `Task` and awaited by
                            // its `.value` -- not `.cancellableValue` -- so the deletion still
                            // finishes even if this effect is cancelled right now (e.g. the user
                            // backs out while the write is in flight); Swift's structured
                            // concurrency has no direct `NonCancellable` scope the way Kotlin's
                            // `withContext(NonCancellable)` does.
                            let rollback = Task {
                                do {
                                    try await sdkSynchronizer.deleteAccount(uuid)
                                } catch {
                                    // Best-effort: a failed rollback must not replace the binding
                                    // failure reported below, and never logs the raw Rust error
                                    // string (which could carry UFVK/binding/device-identity data).
                                    LoggerProxy.warn("Ledger: rolling back an unbound account import failed (\(type(of: error)))")
                                }
                            }
                            await rollback.value
                            await send(.accountImportFailed(error.localizedDescription))
                            return
                        }
                        await send(.accountImported(uuid))
                    } catch {
                        // A viewing-key collision (the Ledger matches an account already in the
                        // wallet) is not surfaced as a generic import failure -- it has its own
                        // sheet. Every other `importAccount` failure keeps today's behavior.
                        if LedgerAccountCollision.isCollision(error) {
                            await send(.accountAlreadyImported(LedgerAccountCollision.collidingAccount(in: error, among: walletAccounts)))
                            return
                        }
                        // Surface only the SDK error's localizedDescription (a static code +
                        // message); the raw Rust error string is never included, so no
                        // UFVK/binding/device-identity data can leak.
                        await send(.accountImportFailed(error.localizedDescription))
                    }
                }

            case .accountAlreadyImported:
                state.isImportingAccount = false
                return .none

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
