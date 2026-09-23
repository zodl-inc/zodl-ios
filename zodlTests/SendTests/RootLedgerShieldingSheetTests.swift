//
//  RootLedgerShieldingSheetTests.swift
//  zodlTests
//
//  MOB-2020 UI round 2: coverage for `RootCoordinator`'s `.signWithKeystoneRequested` vendor
//  branch and the `LedgerSignSheetView` <-> Keystone-popover handoff it drives for shielding
//  (Features/Root/RootCoordinator.swift, Features/Root/RootView.swift). A Ledger account
//  presents the Ledger sheet instead of the popover (`SignWithKeystoneCoordFlowView`'s root is a
//  blank placeholder for that vendor), and the popover only opens once the sheet's dismissal
//  (`.ledgerShieldingSheetDismissed`) finds `.sending` or `.preSendingFailure` already pushed onto
//  the coord flow's own path -- a cancel (empty path) leaves it closed. Mirrors
//  `RootTransactionsTests/RootSendCompletionRefreshTests.swift`'s established pattern: `Root.State`
//  is not `Equatable`, so these tests drive a plain `Store` and poll for the expected outcome, plus
//  its own file-private `baseNoOpDependencies` baseline and `.serialized` (Root.State touches the
//  process-global `@Shared(.inMemory(...))` keys).
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct RootLedgerShieldingSheetTests {
    private static func ledgerAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0E, count: 16)),
                name: "Ledger",
                keySource: "ledger",
                seedFingerprint: nil,
                hdAccountIndex: nil,
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func keystoneAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0F, count: 16)),
                name: "Keystone",
                keySource: "keystone",
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// A validated `LedgerDeviceIdentity`: `tpk0-` plus 64 lowercase hex digits, the same
    /// well-formed, non-secret placeholder `WalletStorageLedgerBindingTests.swift` uses.
    private static func ledgerAccountBinding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    /// A Ledger account requesting the shielding popover instead gets `.confirmWithLedgerTapped`
    /// routed to `sendConfirmationState` -- presenting `LedgerSignSheetView`'s sheet, not
    /// `signWithKeystoneCoordFlowBinding`'s popover. The dependency recipe (a resolvable proposal,
    /// `createPCZTFromProposal`/`exportLedgerBinding` both succeeding, a no-op `ledgerClient`)
    /// mirrors `SendConfirmationLedgerSigningTests.confirmWithLedgerTappedPresentsTheSheetAndResolvesThePcztOnce`
    /// -- it is what keeps `isLedgerSignSheetPresented` settled at `true` rather than bouncing back
    /// to `false` through a `pcztSendFailed` a missing dependency would otherwise trigger.
    @Test func aLedgerShieldingRequestPresentsTheSheetNotThePopover() async throws {
        let account = Self.ledgerAccount()
        let binding = try Self.ledgerAccountBinding()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.signWithKeystoneCoordFlowState.sendConfirmationState.proposal = .testOnlyFakeProposal(totalFee: 10_000)

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.walletStorage.exportLedgerBinding = { _ in binding }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in Pczt([0x06]) }
            $0.ledgerClient = .noOp
        }

        store.send(.signWithKeystoneRequested)

        await waitForRootState {
            store.state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented
        }

        #expect(store.state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented == true)
        #expect(store.state.signWithKeystoneCoordFlowBinding == false)
    }

    /// Regression guard: a Keystone account must keep opening the popover exactly as before, with
    /// `.resolvePCZT` sent the same way it always was.
    @Test func aKeystoneShieldingRequestStillPresentsThePopover() async throws {
        let account = Self.keystoneAccount()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.signWithKeystoneRequested)

        await waitForRootState { store.state.signWithKeystoneCoordFlowBinding }

        #expect(store.state.signWithKeystoneCoordFlowBinding == true)
        #expect(store.state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented == false)
    }

    /// The Ledger sheet's `onDismiss` finding `.sending` already on the coord flow's path (the
    /// ceremony finished and the coordinator pushed the Sending screen) presents the popover
    /// straight on that screen.
    @Test func theSheetClosingAfterTheSignaturePresentsThePopover() async throws {
        var initialState = Root.State.initial
        initialState.signWithKeystoneCoordFlowState.path.append(.sending(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.ledgerShieldingSheetDismissed)

        await waitForRootState { store.state.signWithKeystoneCoordFlowBinding }

        #expect(store.state.signWithKeystoneCoordFlowBinding == true)
    }

    /// "Cancel Transaction" closes the sheet with nothing pushed onto the coord flow's path -- the
    /// popover must stay closed and the user stays where they were.
    @Test func theSheetClosingAfterCancelLeavesThePopoverClosed() async throws {
        let initialState = Root.State.initial

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.ledgerShieldingSheetDismissed)

        // No positive signal to wait for -- give a wrongly-firing popover a brief moment to land,
        // then confirm it didn't.
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(store.state.signWithKeystoneCoordFlowBinding == false)
    }

    /// Today nothing closes the shielding popover from its pre-signing-failure screen, for either
    /// vendor -- `RootCoordinator`'s new arm makes "Close" there actually dismiss it.
    @Test func closingAPreSendingFailureClosesThePopover() async throws {
        var initialState = Root.State.initial
        initialState.signWithKeystoneCoordFlowBinding = true
        initialState.signWithKeystoneCoordFlowState.path.append(.preSendingFailure(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        let elementId = try #require(store.state.signWithKeystoneCoordFlowState.path.ids.first)
        store.send(.signWithKeystoneCoordFlow(.path(.element(id: elementId, action: .preSendingFailure(.backFromPCZTFailureTapped)))))

        await waitForRootState { !store.state.signWithKeystoneCoordFlowBinding }

        #expect(store.state.signWithKeystoneCoordFlowBinding == false)
    }

    // MARK: - Audit follow-up: Root's other safety gates (MOB-2020)

    /// `isSensitiveFlowActive`/`canApplyAutoServerSwitch` are pure computed properties over
    /// `Root.State` -- no store or reducer drive needed, just constructing the state directly.
    /// Only the flag-on -> `canApplyAutoServerSwitch == false` direction is asserted: with the
    /// flag off, `canApplyAutoServerSwitch` also depends on unrelated terms (e.g.
    /// `isSynchronizerIdleForSwitch`, `nil` on a fresh `.initial`) that are not this test's
    /// concern -- `isSensitiveFlowActive` alone is asserted both ways.
    @Test func theLedgerShieldingSheetCountsAsASensitiveFlow() {
        var state = Root.State.initial
        state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented = true

        #expect(state.isSensitiveFlowActive == true)
        #expect(state.canApplyAutoServerSwitch == false)

        state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented = false

        #expect(state.isSensitiveFlowActive == false)
    }

    /// `canPresentIronwoodAnnouncement` is likewise pure. The state is built the way
    /// `UtilTests/RootIronwoodAnnouncementGateTests.swift`'s `makeState()` builds one where the
    /// gate would otherwise read `true` (`destinationState.destination = .home`,
    /// `splashAppeared = true`, every other term left at its `.initial` default).
    @Test func theLedgerShieldingSheetHoldsBackTheIronwoodAnnouncement() {
        var state = Root.State.initial
        state.destinationState.destination = .home
        state.splashAppeared = true

        state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented = true
        #expect(state.canPresentIronwoodAnnouncement == false)

        state.signWithKeystoneCoordFlowState.sendConfirmationState.isLedgerSignSheetPresented = false
        #expect(state.canPresentIronwoodAnnouncement == true)
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way
/// `RootTransactionsTests/RootSendCompletionRefreshTests.swift` keeps its own private
/// `baseNoOpDependencies` local to that file.
@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.audioServices = AudioServicesClient(systemSoundVibrate: { })
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}

/// Polling helper mirroring `SendTests/SignWithKeystoneCoordFlowLedgerTests.swift`'s
/// `waitForCoordFlowStore`: `Root.State` is not `Equatable`, so a plain `Store`'s effects can only
/// be observed by polling state rather than awaiting a `TestStore` assertion.
@MainActor
private func waitForRootState(
    timeoutNanoseconds: UInt64 = 60_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for Root store state", sourceLocation: sourceLocation)
}
