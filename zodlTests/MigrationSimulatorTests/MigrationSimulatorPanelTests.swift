//
//  MigrationSimulatorPanelTests.swift
//  zodlTests
//
//  Covers the MigrationSimulatorPanel reducer
//  (Features/MigrationSimulatorPanel/MigrationSimulatorPanelStore.swift, MOB-1480): the default
//  seed values, every control action calling its matching `MigrationSimulatorClient`/
//  `MigrationManagerClient`/`WalletStorageClient` closure and then re-sending `.refresh`, the
//  preset-specific `resetPersistedFlags` -> `applyPreset` ordering for `.complete`/
//  `.completeWithDust` (asserted via a shared call-log spy), the always-on
//  `setManualDelivery(preset.requiresManualDelivery)` call for every preset, and the
//  `runBackgroundSession`/`openMigrationFlow` delegate emissions. Spy closures only -> no
//  shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSimulatorPanelTests {
    private static func makeReadout(isActive: Bool = true) -> SimulatorReadout {
        SimulatorReadout(
            isActive: isActive,
            state: MigrationState.notStarted,
            mode: MigrationMode.privateScheduled,
            orchardBalance: Zatoshi(1_245_800_000),
            timeOffset: 0,
            rows: [],
            signedBatchCount: 0,
            armedResultDescription: nil,
            isSplitPending: false,
            lastBackgroundRunSummary: nil,
            dustRemainder: Zatoshi.zero,
            isDustLocked: false
        )
    }

    // MARK: - Default state

    @MainActor @Test func defaultStateHasExpectedSeedValues() async {
        let state = MigrationSimulatorPanel.State()

        #expect(state.orchardZec == "12.458")
        #expect(state.noteCount == 1)
        #expect(state.readout == nil)
        #expect(state.isActive == false)
    }

    // MARK: - onAppear / refresh

    @MainActor @Test func onAppearLoadsReadout() async {
        let readout = Self.makeReadout(isActive: false)
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.onAppear)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }
    }

    @MainActor @Test func refreshLoadsReadout() async {
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }
    }

    // MARK: - activeToggled

    @MainActor @Test func activeToggledCallsSetActiveThenRefreshes() async {
        let setActiveCalls = LockIsolated<[Bool]>([])
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.setActive = { value in setActiveCalls.withValue { $0.append(value) } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.activeToggled(true))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(setActiveCalls.value == [true])
    }

    // MARK: - Simulation section

    @MainActor @Test func resetSimulationTappedCallsResetThenRefreshes() async {
        let resetCalls = LockIsolated<Int>(0)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.reset = { resetCalls.withValue { $0 += 1 } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.resetSimulationTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(resetCalls.value == 1)
    }

    @MainActor @Test func resetAppFlagsTappedCallsResetPersistedFlagsThenRefreshes() async {
        let resetFlagsCalls = LockIsolated<Int>(0)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationManager.resetPersistedFlags = { resetFlagsCalls.withValue { $0 += 1 } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.resetAppFlagsTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(resetFlagsCalls.value == 1)
    }

    @MainActor @Test func resetTorFlagTappedCallsImportTorSetupFlagFalse() async {
        let torFlagCalls = LockIsolated<[Bool]>([])
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.importTorSetupFlag = { value in torFlagCalls.withValue { $0.append(value) } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.resetTorFlagTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(torFlagCalls.value == [false])
    }

    // MARK: - Seed section

    @MainActor @Test func applySeedTappedParsesOrchardZecAndCallsSeedThenRefreshes() async {
        let capturedOrchard = LockIsolated<Zatoshi?>(nil)
        let capturedNoteCount = LockIsolated<Int?>(nil)
        let readout = Self.makeReadout()
        var state = MigrationSimulatorPanel.State()
        state.orchardZec = "1.5"
        state.noteCount = 3
        let store = TestStore(initialState: state) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.seed = { orchard, noteCount in
                capturedOrchard.setValue(orchard)
                capturedNoteCount.setValue(noteCount)
            }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.applySeedTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(capturedOrchard.value == Zatoshi(150_000_000))
        #expect(capturedNoteCount.value == 3)
    }

    // MARK: - Presets

    @MainActor @Test func presetTappedManualDeliveryCallsApplyPresetThenSetManualDeliveryTrue() async {
        let callLog = LockIsolated<[String]>([])
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.applyPreset = { preset in
                callLog.withValue { $0.append("applyPreset(\(preset.rawValue))") }
            }
            $0.migrationManager.setManualDelivery = { isManual in
                callLog.withValue { $0.append("setManualDelivery(\(isManual))") }
            }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.presetTapped(.transferReadyManual))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(callLog.value == ["applyPreset(transferReadyManual)", "setManualDelivery(true)"])
    }

    @MainActor @Test func presetTappedCompleteResetsFlagsBeforeApplyPresetAndSetsManualDeliveryFalse() async {
        let callLog = LockIsolated<[String]>([])
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationManager.resetPersistedFlags = { callLog.withValue { $0.append("resetPersistedFlags") } }
            $0.migrationSimulator.applyPreset = { _ in callLog.withValue { $0.append("applyPreset") } }
            $0.migrationManager.setManualDelivery = { isManual in
                callLog.withValue { $0.append("setManualDelivery(\(isManual))") }
            }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.presetTapped(.complete))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(callLog.value == ["resetPersistedFlags", "applyPreset", "setManualDelivery(false)"])
    }

    @MainActor @Test func presetTappedCompleteWithDustAlsoResetsFlagsBeforeApplyPreset() async {
        let callLog = LockIsolated<[String]>([])
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationManager.resetPersistedFlags = { callLog.withValue { $0.append("resetPersistedFlags") } }
            $0.migrationSimulator.applyPreset = { _ in callLog.withValue { $0.append("applyPreset") } }
            $0.migrationManager.setManualDelivery = { isManual in
                callLog.withValue { $0.append("setManualDelivery(\(isManual))") }
            }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.presetTapped(.completeWithDust))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(callLog.value == ["resetPersistedFlags", "applyPreset", "setManualDelivery(false)"])
    }

    @MainActor @Test func presetTappedNonSpecialPresetSkipsResetPersistedFlags() async {
        let resetFlagsCalls = LockIsolated<Int>(0)
        let callLog = LockIsolated<[String]>([])
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationManager.resetPersistedFlags = { resetFlagsCalls.withValue { $0 += 1 } }
            $0.migrationSimulator.applyPreset = { _ in callLog.withValue { $0.append("applyPreset") } }
            $0.migrationManager.setManualDelivery = { isManual in
                callLog.withValue { $0.append("setManualDelivery(\(isManual))") }
            }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.presetTapped(.splitting))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(resetFlagsCalls.value == 0)
        #expect(callLog.value == ["applyPreset", "setManualDelivery(false)"])
    }

    // MARK: - Drive section

    @MainActor @Test(arguments: [1, 6])
    func advanceTimeTappedConvertsHoursToSecondsAndCallsAdvanceTime(_ hours: Int) async {
        let capturedInterval = LockIsolated<TimeInterval?>(nil)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.advanceTime = { capturedInterval.setValue($0) }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.advanceTimeTapped(hours: hours))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(capturedInterval.value == TimeInterval(hours * 3600))
    }

    @MainActor @Test func makeNextDueNowTappedCallsClientThenRefreshes() async {
        let calls = LockIsolated<Int>(0)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.makeNextTransferDueNow = { calls.withValue { $0 += 1 } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.makeNextDueNowTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(calls.value == 1)
    }

    @MainActor @Test func confirmSplitNowTappedCallsClientThenRefreshes() async {
        let calls = LockIsolated<Int>(0)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.confirmSplitNow = { calls.withValue { $0 += 1 } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.confirmSplitNowTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(calls.value == 1)
    }

    @MainActor @Test func runBackgroundSessionTappedEmitsDelegate() async {
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        }

        await store.send(.runBackgroundSessionTapped)
        await store.receive(.delegate(.runBackgroundSession))
    }

    // MARK: - Arm next result

    @MainActor @Test(
        arguments: [
            MigrationTransferResult.success(txId: ""),
            MigrationTransferResult.networkError(retryable: true),
            MigrationTransferResult.invalidNote,
            MigrationTransferResult.expired
        ]
    )
    func armResultTappedPassesResultThrough(_ result: MigrationTransferResult) async {
        let capturedResult = LockIsolated<MigrationTransferResult?>(nil)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.armTransferResult = { capturedResult.setValue($0) }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.armResultTapped(result))
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(capturedResult.value == result)
    }

    @MainActor @Test func armSplitFailureTappedCallsClientThenRefreshes() async {
        let calls = LockIsolated<Int>(0)
        let readout = Self.makeReadout()
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        } withDependencies: {
            $0.migrationSimulator.armSplitFailure = { calls.withValue { $0 += 1 } }
            $0.migrationSimulator.readout = { readout }
        }

        await store.send(.armSplitFailureTapped)
        await store.receive(\.refresh)
        await store.receive(\.readoutLoaded) {
            $0.readout = readout
        }

        #expect(calls.value == 1)
    }

    // MARK: - Flow section

    @MainActor @Test func openMigrationFlowTappedEmitsDelegate() async {
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        }

        await store.send(.openMigrationFlowTapped)
        await store.receive(.delegate(.openMigrationFlow))
    }

    // MARK: - Delegate

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationSimulatorPanel.State()) {
            MigrationSimulatorPanel()
        }

        await store.send(.delegate(.openMigrationFlow))
    }
}
