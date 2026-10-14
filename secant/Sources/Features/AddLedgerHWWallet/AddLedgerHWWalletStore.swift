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
@preconcurrency import ZODLSwiftWalletSDK

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
        /// device already ran the app, and on every other screen this reducer drives. Consumed
        /// (set back to `false`) the moment step 3 actually starts opening the app, so a later
        /// reappearance -- Back from step 4 -- never re-triggers it; only Continue can from then on.
        var autoOpenZcashApp = false

        /// Set only on the copy of the picker's state pushed as step 3 (`.ledgerOpenApp`) --
        /// mirrors `isApproveScreen`'s role but for `LedgerOpenAppView`'s own retry: distinguishes
        /// this reducer's THIRD screen from the picker (bond again) and the approve screen
        /// (reconnect) in `issuePrimaryTapped`.
        var isOpenAppScreen = false

        /// Whether step 3 is currently asking the device to open the Zcash app.
        var isOpeningApp = false

        /// Whether the picker can offer its own Try again button below the (now empty) device
        /// list: there is a failure showing, and nothing else is already in flight or selected.
        var canRescan: Bool { issue != nil && !isScanning && !isConnecting && !isPairing && selectedDevice == nil }

        /// Whether the picker should show "Searching for Devices" copy rather than the
        /// no-selection copy: true only while the scan is still running and no device has turned
        /// up yet, so a scan that has failed or timed out with none found reads the same as one
        /// that was never started. The skeleton rows themselves stay keyed off `devices.isEmpty`
        /// alone -- they already stop shimmering once the scan stops.
        var isShowingSearchingCopy: Bool { isScanning && devices.isEmpty }

        /// MOB-2020: the "Advanced options" card's own account index field, raw user input.
        /// Defaults to "0" for a fresh pairing; seeded from the repair target's stored binding
        /// instead when pairing an account again (ConnectHWWalletCoordFlowCoordinator, which
        /// alone knows the target).
        var accountIndexText = "0"

        /// Whether the "Advanced options" card is expanded. Defaults to collapsed; the
        /// coordinator expands it up front when the repair prefill above isn't "0", and
        /// `advancedOptionsToggleTapped` refuses to collapse it while `selectedAccountIndex`
        /// is `nil`, so the reason Connect is disabled stays in view.
        var isAdvancedOptionsExpanded = false

        /// The ZIP 32 account index `accountIndexText` names, when it is a whole number from 0
        /// to `Self.maxAccountIndex` inclusive: digits only, so an empty string, a sign or a
        /// separator (`"1.5"`) is invalid, same as a value outside that range. `nil` while
        /// invalid -- `connectDeviceTapped` reads this instead of hard-coding account 0, and the
        /// view disables Connect and refuses to collapse the card while it's `nil`.
        var selectedAccountIndex: Zip32AccountIndex? {
            guard !accountIndexText.isEmpty, accountIndexText.allSatisfy({ ("0"..."9").contains($0) }) else {
                return nil
            }
            guard let value = UInt32(accountIndexText), value <= Self.maxAccountIndex else {
                return nil
            }
            return Zip32AccountIndex(value)
        }

        /// pczt_ledger's `MAX_BIP44_ACCOUNT`, the highest account index the Ledger Zcash app
        /// derives.
        static let maxAccountIndex: UInt32 = 100

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
        /// MOB-2020: the "Advanced options" card's header -- expands or collapses it, but refuses
        /// to collapse while `selectedAccountIndex` is `nil` (Android's own
        /// `LedgerDeviceScanVM.onAdvancedOptionsToggle`).
        case advancedOptionsToggleTapped
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
        /// carries the device that was bonded (never read off `selectedDevice`: a tap on another
        /// row while the bond was running could otherwise have changed it), the account index
        /// `approveOnDeviceTapped` snapshotted the same way (an edit to the field while the bond
        /// ran must not change what gets paired), and whether the device already runs the Zcash
        /// app, which ConnectHWWalletCoordFlowCoordinator reads to decide what it pushes next.
        case deviceBonded(device: LedgerBluetoothDevice, accountIndex: Zip32AccountIndex, isZcashAppRunning: Bool)
        case deviceTapped(LedgerBluetoothDevice)
        case devicesUpdated([LedgerBluetoothDevice])
        case forgetThisDeviceTapped
        case helpSheetRequested
        case issuePrimaryTapped
        case loadedWalletAccounts([WalletAccount], AccountUUID)
        case nextTapped
        case onAppear
        /// MOB-2020 (Android 8cf16518): step 3's Continue -- and, in auto mode, its own first
        /// appearance -- asking the bonded device to open the Zcash app.
        case openZcashAppTapped
        /// MOB-2020: `openZcashAppTapped`'s request failed or ran out of time; carries the issue
        /// the shared sheet shows.
        case openingZcashAppFailed(LedgerIssue)
        case pairingFailed(issue: LedgerIssue, connectionLost: Bool)
        case pairingSucceeded(LedgerPairing)
        case scanFailed(LedgerIssue)
        case scanTimedOut
        case setBirthdayTapped
        case startScanning
        case stopScanning
        case unlockTapped(BlockHeight?)
        /// MOB-2020: `openZcashAppTapped`'s request succeeded -- ConnectHWWalletCoordFlowCoordinator
        /// reacts to this to push step 4, which starts pairing.
        case zcashAppOpened
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

    /// `openZcashAppTapped`'s outcome once its request and the approval-timeout race
    /// (`LedgerIssue.racingApprovalTimeout`) have settled.
    private enum OpenZcashAppOutcome: Sendable {
        case opened
        case failed(LedgerIssue)
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
                state.selectedDevice = nil
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
                // selection follows the same device's latest value; a batch that no longer lists
                // it drops the selection instead of keeping a stale one around (Android
                // LedgerDeviceScanVM.kt:446-450).
                state.selectedDevice = state.selectedDevice.flatMap { selected in devices.first { $0.id == selected.id } }
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
                // MOB-2020: ignored while a bond from an earlier tap is still running -- Android
                // disables the rows for the same reason. Without this guard, a tap mid-bond swaps
                // `selectedDevice` out from under `approveOnDeviceTapped`'s in-flight bond, and
                // `.deviceBonded` would then report a device nothing here ever selected.
                guard !state.isConnecting else { return .none }
                state.selectedDevice = device
                state.issue = nil
                state.isIssueSheetPresented = false
                return .none

            case .advancedOptionsToggleTapped:
                // MOB-2020: an invalid index keeps the card open, so the reason Connect is
                // disabled stays visible instead of collapsing out of view.
                if state.isAdvancedOptionsExpanded && state.selectedAccountIndex == nil {
                    return .none
                }
                state.isAdvancedOptionsExpanded.toggle()
                return .none

            case .approveOnDeviceTapped:
                // MOB-2020 (Android 48b8d5bc, 6c9491c7, e3480698): bonds right here, on the
                // picker, instead of pushing first -- a first Bluetooth pairing with the Zcash
                // app already open freezes the device on its pairing screen, so nothing opens the
                // app until the bond (and this device's already-running-app answer) is in.
                // MOB-2020: the picker's own Connect is already disabled while
                // `selectedAccountIndex` is `nil` (Android's own `onConnectClick`), checked again
                // here rather than trusting the view alone. Snapshotted into `accountIndex` right
                // here, the same as `device` -- the field stays editable (though disabled once
                // `isConnecting`) while the bond below runs, and a late edit must not change what
                // eventually gets paired.
                guard let device = state.selectedDevice,
                      let accountIndex = state.selectedAccountIndex,
                      !state.isConnecting,
                      !state.isPairing
                else {
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
                            await send(.deviceBonded(device: device, accountIndex: accountIndex, isZcashAppRunning: isZcashAppRunning))
                        } catch {
                            let issue = LedgerIssue(error, in: .pairing)
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

            case .openZcashAppTapped:
                // MOB-2020 (Android 8cf16518, b8175064): step 3's Continue, and its own auto
                // mode's first appearance (LedgerOpenAppView's `onAppear`, gated on
                // `autoOpenZcashApp`). The request runs on its own only once: consuming the flag
                // here means a later reappearance -- Back from step 4 -- leaves the screen idle
                // until Continue is tapped again.
                guard let device = state.selectedDevice, !state.isOpeningApp else {
                    return .none
                }
                state.autoOpenZcashApp = false
                state.isOpeningApp = true
                state.issue = nil
                state.isIssueSheetPresented = false
                return .run { send in
                    let outcome = await LedgerIssue.racingApprovalTimeout(clock: clock) { () -> OpenZcashAppOutcome in
                        do {
                            try await ledgerClient.openZcashApp(device)
                            return .opened
                        } catch {
                            return .failed(LedgerIssue(error, in: .connect))
                        }
                    }
                    switch outcome {
                    case .completed(.opened):
                        await send(.zcashAppOpened)
                    case let .completed(.failed(issue)):
                        await send(.openingZcashAppFailed(issue))
                    case .timedOut:
                        // MOB-2020: unlike connectDeviceTapped's connect()+pairAccount() pair,
                        // ledgerClient.openZcashApp closes its own transport on every exit --
                        // cancellation included (LedgerSession.openZcashApp's own `defer`) -- so
                        // nothing here needs an explicit disconnect.
                        await send(.openingZcashAppFailed(.disconnected))
                    case .cancelled:
                        // MOB-2020: the step was left (`cancelTapped`), not timed out -- there's
                        // no issue to show, and openZcashApp closes its own transport.
                        break
                    }
                }
                // MOB-2020: step 3's back arrow sends the same `cancelTapped` the approve screen's
                // does, which already cancels this id.
                .cancellable(id: CancelId.connectAndPair, cancelInFlight: true)

            case .zcashAppOpened:
                // ConnectHWWalletCoordFlowCoordinator's own arm for this action does the actual
                // pushing (coordinatorReduce() runs before this reducer) -- nothing else to do
                // with it here.
                state.isOpeningApp = false
                return .none

            case let .openingZcashAppFailed(issue):
                state.isOpeningApp = false
                state.issue = issue
                state.isIssueSheetPresented = true
                return .none

            case .connectDeviceTapped:
                // MOB-2020 (Android aac01e65, 4f7b031e, e838559b): the approve element's own
                // Connect/auto-start -- pairs on a fresh connection of its own (`pairDevice`)
                // instead of the old connect()-then-pairAccount() pair. One atomic call, so
                // there is no separate "connected" checkpoint to report mid-flight any more.
                guard let device = state.selectedDevice, !state.isConnecting, !state.isPairing else {
                    return .none
                }
                // MOB-2020: unreachable now that `.approveOnDeviceTapped` snapshots the index and
                // carries it through `.deviceBonded`/`.zcashAppOpened` the way `device` is --
                // presented as an issue, the same way a pairing failure already is, rather than a
                // silent no-op that would strand this screen with nowhere to go, in case a future
                // caller ever reaches it without a snapshot.
                guard let accountIndex = state.selectedAccountIndex else {
                    state.issue = LedgerIssue(ZcashError.ledgerInvalidInput("no account index"), in: .pairing)
                    state.isIssueSheetPresented = true
                    return .none
                }
                state.isPairing = true
                state.issue = nil
                state.isIssueSheetPresented = false
                return .run { send in
                    let outcome = await LedgerIssue.racingApprovalTimeout(clock: clock) { () -> ConnectAndPairOutcome in
                        do {
                            let pairing = try await ledgerClient.pairDevice(device, accountIndex)
                            return .paired(pairing)
                        } catch {
                            // MOB-2020: classified as setup, not bonding -- the picker's own
                            // `bond` already handled that phase before this screen ever runs.
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
                        // MOB-2020: unlike the old connect()+pairAccount() pair, ledgerClient.pairDevice
                        // closes every transport it held on every exit, cancellation included
                        // (LedgerSession.pairDevice's own `defer`) -- nothing here needs an
                        // explicit disconnect.
                        await send(.pairingFailed(issue: .disconnected, connectionLost: true))
                    case .cancelled:
                        // MOB-2020: the ceremony was torn down, not timed out --
                        // nothing to clean up here; whichever teardown site cancelled this effect
                        // already does its own.
                        break
                    }
                }
                // MOB-2020: the Approve on Your Device screen's Cancel and back arrow cancel
                // this same effect (`CancelId.connectAndPair`) -- today it was not cancellable,
                // so leaving mid-pairing left it running to completion in the background.
                .cancellable(id: CancelId.connectAndPair, cancelInFlight: true)

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
                // Step 3 (`isOpenAppScreen`) re-asks the device to open the app. The picker
                // itself bonds on Connect, so ITS retry needs telling apart too: a kept selection
                // (a bond failure) bonds that same device again; no selection (a plain scan
                // failure) rescans, as before.
                if state.isApproveScreen {
                    return .send(.connectDeviceTapped)
                } else if state.isOpenAppScreen {
                    return .send(.openZcashAppTapped)
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
