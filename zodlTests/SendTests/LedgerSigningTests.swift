//
//  LedgerSigningTests.swift
//  zodlTests
//
//  MOB-2020 Phase 3.2: covers `LedgerSigning` in isolation -- scanning (including the no-devices
//  timeout), auto-connect vs. device picker, a sign request arriving before the device is
//  connected, every progress stage on a successful ceremony, and the LedgerIssue/connection-lost
//  split on failure (Features/SendConfirmation/LedgerSigningStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `.timeLimit` is SignalledClock's own backstop (TestSupport/SignalledClock.swift): a wait that
// genuinely never fires is recorded as a failure here instead of hanging the run.
@Suite(.timeLimit(.minutes(1))) struct LedgerSigningTests {
    @MainActor @Test func onAppearStartsScanning() async throws {
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.phase = .failed
        state.issue = .disconnected
        state.hasOpenedSettings = true
        state.isConnectionLost = true
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
        }

        await store.send(.onAppear) {
            $0 = LedgerSigning.State()
            $0.request = request
        }
        await store.receive(\.startScanning)
        await store.finish()
    }

    @MainActor @Test func aSingleDeviceIsConnectedAutomatically() async {
        let device = Self.device(name: "Nano X")
        let store = TestStore(initialState: LedgerSigning.State()) {
            LedgerSigning()
        } withDependencies: {
            // MOB-2020: `.connect` now races this against the approval-timeout cap; un-advanced,
            // the cap never wins, and the auto-connect below is unaffected by it.
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            $0.ledgerClient.connect = { _, _ in }
        }

        await store.send(.devicesUpdated([device])) {
            $0.devices = [device]
            $0.selectedDevice = device
        }
        await store.receive(\.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.deviceConnected) {
            $0.phase = .connected
        }
        // No `request` yet -- `startSigningIfReady`'s guard fails and nothing further happens.
        await store.receive(\.startSigningIfReady)
        await store.finish()
    }

    // MOB-2020: before this commit, a connect that never answered (the on-device "Open Zcash?"
    // prompt going unanswered) left the sheet on `.connecting` indefinitely -- the
    // approval-timeout cap now wins after five minutes and disconnects.
    @MainActor @Test func connectTimesOutAfterFiveMinutesAndDisconnects() async throws {
        let device = Self.device(name: "Nano X")
        let clock = SignalledClock()
        let disconnectCallCount = LockIsolated(0)
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = clock
            $0.ledgerClient = .noOp
            // Never answers -- the on-device "Open Zcash?" prompt is what the cap is timing.
            $0.ledgerClient.connect = { _, _ in try await Task.sleep(for: .seconds(999)) }
            $0.ledgerClient.disconnect = { disconnectCallCount.withValue { $0 += 1 } }
        }

        await store.send(.connect) {
            $0.phase = .connecting
        }
        // The timer's sleep is parked (and only then recorded) before advancing to it, so this
        // advance is guaranteed to resume the timer and not race its start.
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.approvalTimeout)
        await store.receive(.connectionFailed(.disconnected)) {
            $0.phase = .failed
            $0.issue = .disconnected
            $0.isConnectionLost = true
        }
        await store.finish()

        #expect(disconnectCallCount.value == 1)
    }

    @MainActor @Test func severalDevicesWaitForATap() async {
        let deviceA = Self.device(name: "Nano X A")
        let deviceB = Self.device(name: "Nano X B")
        // No `connect`/`signPCZT` override beyond `.noOp`: reaching either would trip "has no
        // test implementation" and fail the test -- proving nothing auto-connects here.
        let store = TestStore(initialState: LedgerSigning.State()) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
        }

        await store.send(.devicesUpdated([deviceA, deviceB])) {
            $0.devices = [deviceA, deviceB]
            $0.phase = .selectingDevice
        }
        await store.finish()
    }

    // MOB-2020: before this commit, every device dropping out of range while the picker was up
    // left `phase == .selectingDevice` forever -- there was no timer at all once past `.scanning`.
    @MainActor @Test func anEmptiedPickerFailsWithNoDevicesAfterTheTimeout() async throws {
        let device = Self.device(name: "Nano X")
        let clock = SignalledClock()
        var state = LedgerSigning.State()
        state.phase = .selectingDevice
        state.devices = [device]

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = clock
            $0.ledgerClient = .noOp
        }

        await store.send(.devicesUpdated([])) {
            $0.devices = []
        }
        // The timer's sleep is parked (and only then recorded) before advancing to it, so this
        // advance is guaranteed to resume the timer and not race its start.
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.noDevicesFoundTimeout)
        await store.receive(\.scanTimedOut) {
            $0.phase = .failed
            $0.issue = .noDevicesFound
            $0.isConnectionLost = true
        }
        await store.finish()
    }

    @MainActor @Test func aDeviceAppearingBeforeThePickerTimeoutCancelsIt() async throws {
        let deviceA = Self.device(name: "Nano X A")
        let deviceB = Self.device(name: "Nano X B")
        let clock = SignalledClock()
        var state = LedgerSigning.State()
        state.phase = .selectingDevice
        state.devices = [deviceA]

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = clock
            $0.ledgerClient = .noOp
        }

        await store.send(.devicesUpdated([])) {
            $0.devices = []
        }
        await clock.sleepDeadlines.countReached(1)

        // The device is back before the timer fires -- this cancels it instead of letting the
        // picker fail out from under the user.
        await store.send(.devicesUpdated([deviceA, deviceB])) {
            $0.devices = [deviceA, deviceB]
        }
        await store.finish()
    }

    @MainActor @Test func scanTimeoutShowsNoDevicesFound() async {
        let clock = SignalledClock()
        let (scanStream, scanContinuation) = AsyncThrowingStream<[LedgerBluetoothDevice], Error>.makeStream()
        let store = TestStore(initialState: LedgerSigning.State()) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = clock
            $0.ledgerClient = .noOp
            $0.ledgerClient.scanDevices = { scanStream }
        }

        // `LedgerSigning.State()`'s defaults already match everything `.startScanning` sets
        // (`phase == .scanning`, `issue == nil`, `hasOpenedSettings == false`, `devices == []`),
        // so there is no observable change to assert here.
        await store.send(.startScanning)
        // The timer's sleep is parked (and only then recorded) before advancing to it, so this
        // advance is guaranteed to resume the timer and not race its `addTask`.
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.noDevicesFoundTimeout)
        await store.receive(\.scanTimedOut) {
            $0.phase = .failed
            $0.issue = .noDevicesFound
            $0.isConnectionLost = true
        }
        // The timed-out state above already returns `.cancel`, which ends the still-parked scan
        // task's `for await` on its own (a cancelled consumer's iteration ends the sequence).
        // Finishing the continuation here too is redundant but harmless, and avoids leaving it
        // dangling once the test's scope ends.
        scanContinuation.finish()
        await store.finish()
    }

    @MainActor @Test func aSignRequestBeforeTheConnectionWaitsUntilConnected() async throws {
        let request = try Self.signRequest()
        let signPCZTCallCount = LockIsolated(0)
        // MOB-2020: `.deviceConnected` is now guarded on `phase == .connecting` (a late result
        // from the non-cancellable `connect` effect must not resurrect a ceremony that already
        // failed), so this starts mid-connect rather than at the default `.scanning`.
        var initialState = LedgerSigning.State()
        initialState.phase = .connecting
        let store = TestStore(initialState: initialState) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                signPCZTCallCount.withValue { $0 += 1 }
                return AsyncThrowingStream { $0.finish() }
            }
        }

        await store.send(.signRequested(request)) {
            $0.request = request
        }
        // Still `.connecting` -- `startSigningIfReady`'s guard must not let signing start before
        // a device is connected.
        await store.receive(\.startSigningIfReady)
        #expect(signPCZTCallCount.value == 0)

        await store.send(.deviceConnected) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.finish()

        #expect(signPCZTCallCount.value == 1)
    }

    @MainActor @Test func aConnectedDeviceWithARequestSignsAndReportsEveryStage() async throws {
        let request = try Self.signRequest()
        let signedPczt = Pczt([0xAB])
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.progress(.identifyingDevice))
                    continuation.yield(.progress(.streaming(sent: 0, total: 2)))
                    continuation.yield(.progress(.awaitingReviewOnDevice))
                    continuation.yield(.progress(.signing))
                    continuation.yield(.progress(.complete))
                    continuation.yield(.signed(signedPczt))
                    continuation.finish()
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        // `startSigningIfReady` already optimistically set `.identifyingDevice` above, so this
        // first progress event (the same stage) makes no further observable change.
        await store.receive(\.signingProgressed)
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.streaming(sent: 0, total: 2))
        }
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.awaitingReviewOnDevice)
        }
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.signing)
        }
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.complete)
        }
        await store.receive(.signed(signedPczt)) {
            $0.phase = .signed
        }
        await store.finish()
    }

    @MainActor @Test func aDeviceRejectionIsRestartableAndKeepsTheRequest() async throws {
        let request = try Self.signRequest()
        let signPCZTCallCount = LockIsolated(0)
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                signPCZTCallCount.withValue { $0 += 1 }
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerUserRejected)
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .requestRejected, connectionLost: false)) {
            $0.phase = .failed
            $0.issue = .requestRejected
            $0.isConnectionLost = false
        }
        #expect(signPCZTCallCount.value == 1)
        // The request is still there -- Try Again can resume signing without asking again.
        #expect(store.state.request == request)

        await store.send(.tryAgainTapped) {
            $0.phase = .connected
            $0.issue = nil
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .requestRejected, connectionLost: false)) {
            $0.phase = .failed
            $0.issue = .requestRejected
        }
        await store.finish()

        #expect(signPCZTCallCount.value == 2)
    }

    // MOB-2020: before this commit, `.deviceLocked` while signing reused `isConnectionLost ==
    // false` (same as `.connect`) and Try again went straight back to signing on the old link --
    // never calling `ledgerClient.connect` again, so a device that needed the Zcash app reopened
    // could never get there. `retryNeedsNewConnection(in: .sign)` now says otherwise for
    // `.deviceLocked`, so Try again rescans and reconnects instead.
    @MainActor @Test func aLockedLedgerWhileSigningReconnectsOnTryAgain() async throws {
        let device = Self.device(name: "Nano X")
        let request = try Self.signRequest()
        let connectCallCount = LockIsolated(0)
        let signPCZTCallCount = LockIsolated(0)
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            $0.ledgerClient.connect = { _, _ in connectCallCount.withValue { $0 += 1 } }
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.yield([device])
                    continuation.finish()
                }
            }
            $0.ledgerClient.signPCZT = { _, _, _ in
                signPCZTCallCount.withValue { $0 += 1 }
                return AsyncThrowingStream { continuation in
                    // A transient device refusal -- e.g. the Ledger is locked -- shares
                    // `.deviceLocked`'s copy with `ledgerWrongApp` (see `LedgerIssue.init`).
                    continuation.finish(throwing: ZcashError.ledgerDeviceRefused(0x5515, true))
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .deviceLocked, connectionLost: true)) {
            $0.phase = .failed
            $0.issue = .deviceLocked
            $0.isConnectionLost = true
        }

        // Try again now rescans -- a fresh connection reopens the Zcash app -- instead of
        // retrying on the held transport.
        await store.send(.tryAgainTapped) {
            $0.devices = []
            $0.selectedDevice = nil
            $0.phase = .scanning
        }
        await store.receive(\.startScanning) {
            $0.issue = nil
        }
        await store.receive(\.devicesUpdated) {
            $0.devices = [device]
            $0.selectedDevice = device
        }
        await store.receive(\.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.deviceConnected) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .deviceLocked, connectionLost: true)) {
            $0.phase = .failed
            $0.issue = .deviceLocked
        }
        await store.finish()

        #expect(connectCallCount.value == 1)
        #expect(signPCZTCallCount.value == 2)
    }

    @MainActor @Test func aLostConnectionRescansOnTryAgain() async throws {
        let device = Self.device(name: "Nano X")
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerTransportClosed)
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .disconnected, connectionLost: true)) {
            $0.phase = .failed
            $0.issue = .disconnected
            $0.isConnectionLost = true
        }

        await store.send(.tryAgainTapped) {
            $0.devices = []
            $0.selectedDevice = nil
            $0.phase = .scanning
        }
        await store.receive(\.startScanning) {
            $0.issue = nil
        }
        await store.finish()
    }

    // MOB-2020: before this commit, a lone device on the retry scan auto-connected silently even
    // right after that same device was rejected as the wrong Ledger. Now the picker shows it
    // instead, and only an explicit tap connects (and clears the flag).
    @MainActor @Test func aWrongLedgerRetryShowsThePickerForALoneDeviceAndTappingItConnects() async throws {
        let device = Self.device(name: "Nano X")
        let request = try Self.signRequest()
        let connectCallCount = LockIsolated(0)
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            $0.ledgerClient.connect = { _, _ in connectCallCount.withValue { $0 += 1 } }
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.yield([device])
                    continuation.finish()
                }
            }
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerDeviceMismatch)
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .deviceMismatch, connectionLost: true)) {
            $0.phase = .failed
            $0.issue = .deviceMismatch
            $0.isConnectionLost = true
            $0.isPickerRequired = true
        }

        await store.send(.tryAgainTapped) {
            $0.devices = []
            $0.selectedDevice = nil
            $0.phase = .scanning
        }
        await store.receive(\.startScanning) {
            $0.issue = nil
        }
        // The retry scan finds the very same lone device, but the wrong-Ledger flag keeps it
        // from auto-connecting -- the picker shows it instead.
        await store.receive(\.devicesUpdated) {
            $0.devices = [device]
            $0.phase = .selectingDevice
        }
        #expect(connectCallCount.value == 0)

        // Tapping the device answers "is this the right Ledger" -- it clears the flag and
        // connects.
        await store.send(.deviceTapped(device)) {
            $0.selectedDevice = device
            $0.isPickerRequired = false
        }
        await store.receive(\.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.deviceConnected) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .deviceMismatch, connectionLost: true)) {
            $0.phase = .failed
            $0.issue = .deviceMismatch
            $0.isPickerRequired = true
        }
        await store.finish()

        #expect(connectCallCount.value == 1)
    }

    @MainActor @Test func aNotSignableTransactionIsNotRestartable() async throws {
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerTransactionNotSignable("some SDK reason"))
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(.signingFailed(issue: .transactionNotSignable, connectionLost: false)) {
            $0.phase = .failed
            $0.issue = .transactionNotSignable
            $0.isConnectionLost = false
        }
        // `.transactionNotSignable`'s `.sign`-context primary action is `.none` -- no retry
        // button, matching the "not restartable" classification this test's name describes.
        #expect(store.state.failedPrimaryAction == .none)
        await store.finish()
    }

    @MainActor @Test func openingSettingsTurnsThePrimaryActionIntoTryAgain() async {
        var state = LedgerSigning.State()
        state.phase = .failed
        state.issue = .bluetoothUnauthorized

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
        }

        #expect(store.state.failedPrimaryAction == .openSettings)

        await store.send(.openSettingsTapped) {
            $0.hasOpenedSettings = true
        }

        #expect(store.state.failedPrimaryAction == .tryAgain)
        await store.finish()
    }

    @MainActor @Test func pairingMissingFailsOnNotPairedAndIgnoresALateConnect() async {
        let device = Self.device(name: "Nano X")
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device
        state.phase = .connecting

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
        }

        await store.send(.pairingMissing) {
            $0.phase = .failed
            $0.issue = .notPaired
            $0.isConnectionLost = false
        }
        // MOB-2020 (Android e36fedb2/ebc98b38): `.notPaired`'s `.sign`-context primary action is
        // now Pair Ledger, not the "no retry" `.none` this asserted before.
        #expect(store.state.failedPrimaryAction == .pairLedger)

        // A late result from the non-cancellable `connect` effect must not overwrite the ceremony
        // that already failed above -- both are no-ops now that `phase` is `.failed`.
        await store.send(.deviceConnected)
        await store.send(.connectionFailed(.disconnected))
        // MOB-2020: same reasoning -- a late `.openingZcashApp` report must not resurrect the
        // ceremony either. This is exactly why that action's own guard checks `phase == .connecting`.
        await store.send(.openingZcashApp)
        await store.finish()
    }

    // MOB-2020: `LedgerSession.connect`'s own report that it is about to ask the device to open
    // the Zcash app moves `.connecting` to `.openingZcashApp`; connect's success then signs
    // exactly as it did before this state existed.
    @MainActor @Test func theOpeningZcashAppReportMovesThePhaseAndSigningStartsOnSuccess() async throws {
        let device = Self.device(name: "Nano X")
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            $0.ledgerClient.connect = { _, report in await report() }
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { $0.finish() }
            }
        }

        await store.send(.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.openingZcashApp) {
            $0.phase = .openingZcashApp
        }
        await store.receive(\.deviceConnected) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.finish()
    }

    // MOB-2020: a failure while the device is showing the "Open Zcash?" prompt (e.g. the user
    // declines it) shows the same failure sheet any other connect-step failure does.
    @MainActor @Test func aFailureWhileOpeningTheZcashAppShowsTheFailureSheet() async throws {
        let device = Self.device(name: "Nano X")
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            $0.ledgerClient.connect = { _, report in
                await report()
                throw ZcashError.ledgerAppOpenRejected
            }
        }

        await store.send(.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.openingZcashApp) {
            $0.phase = .openingZcashApp
        }
        await store.receive(.connectionFailed(.openAppRejected)) {
            $0.phase = .failed
            $0.issue = .openAppRejected
            $0.isConnectionLost = true
        }
        await store.finish()
    }

    // MOB-2020: when the device already runs the Zcash app, `LedgerSession.connect` never
    // reports -- the phase goes straight from `.connecting` to `.connected`, same as before this
    // state existed.
    @MainActor @Test func noReportMeansThePhaseGoesStraightFromConnectingToConnected() async throws {
        let device = Self.device(name: "Nano X")
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient = .noOp
            // Never calls its second argument -- as if the device were already running the Zcash
            // app, so `LedgerSession.connect` never reports.
            $0.ledgerClient.connect = { _, _ in }
        }

        await store.send(.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.deviceConnected) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady)
        await store.finish()
    }

    // MOB-2020: the sign sheet's description switches from the "before review" copy to the final
    // confirm copy once the ceremony has reached (or passed) on-device review (Figma annotation
    // 1638:268) -- covers every `Phase`/`LedgerSigningProgress` case.
    @Test func hasReachedReviewIsTrueOnlyFromReviewOnward() {
        var state = LedgerSigning.State()

        state.phase = .scanning
        #expect(!state.hasReachedReview)

        state.phase = .selectingDevice
        #expect(!state.hasReachedReview)

        state.phase = .connecting
        #expect(!state.hasReachedReview)

        state.phase = .openingZcashApp
        #expect(!state.hasReachedReview)

        state.phase = .connected
        #expect(!state.hasReachedReview)

        state.phase = .signing(.identifyingDevice)
        #expect(!state.hasReachedReview)

        state.phase = .signing(.streaming(sent: 1, total: 2))
        #expect(!state.hasReachedReview)

        state.phase = .signing(.awaitingReviewOnDevice)
        #expect(state.hasReachedReview)

        state.phase = .signing(.signing)
        #expect(state.hasReachedReview)

        state.phase = .signing(.complete)
        #expect(state.hasReachedReview)

        state.phase = .signed
        #expect(state.hasReachedReview)

        state.phase = .failed
        #expect(!state.hasReachedReview)
    }

    // MARK: - Fixtures

    private static func device(name: String) -> LedgerBluetoothDevice {
        LedgerBluetoothDevice(id: UUID(), name: name, model: .nanoX, rssi: -40)
    }

    /// A validated `LedgerDeviceIdentity`: `tpk0-` plus 64 lowercase hex digits, the same
    /// well-formed, non-secret placeholder `WalletStorageLedgerBindingTests.swift` and
    /// `LedgerSessionTests.swift` use.
    private static func ledgerAccountBinding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    private static func signRequest() throws -> LedgerSigning.State.SignRequest {
        LedgerSigning.State.SignRequest(
            pczt: Pczt([0x01]),
            accountUUID: AccountUUID(id: [UInt8](repeating: 0xAB, count: 16)),
            binding: try ledgerAccountBinding()
        )
    }
}
