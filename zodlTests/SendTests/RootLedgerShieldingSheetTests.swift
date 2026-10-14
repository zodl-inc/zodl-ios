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
@testable @preconcurrency import ZODLSwiftWalletSDK
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
            // `.confirmWithLedgerTapped` starts the Ledger ceremony (`.ledgerSigning(.onAppear)`
            // -> `.startScanning`), which now also arms a no-devices timer alongside the scan.
            $0.continuousClock = SignalledClock()
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

    // MARK: - Pair Ledger from the sign sheet (MOB-2020, Android e36fedb2/ebc98b38/d1506d0d)

    /// `sendCoordFlow`'s `sendConfirmation` path element: Pair Ledger stages the connect flow for
    /// the selected account (target set, path started at `.addLedgerHWWallet`) without touching
    /// `path` yet, then the sheet's dismissal (once it has actually finished closing) switches
    /// `path` to `.connectHWWalletCoordFlow` -- one assignment closes sendCoordFlow and opens the
    /// connect flow at once.
    @Test func pairLedgerFromSendConfirmationStagesRepairThenOpensConnectFlowOnDismissal() async throws {
        let account = Self.ledgerAccount()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))
        let elementId = try #require(initialState.sendCoordFlowState.path.ids.first)
        initialState.path = .sendCoordFlow

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.pairLedgerTapped)))))

        // Staged, but the switch waits for the sheet to actually finish closing.
        #expect(store.state.path == .sendCoordFlow)
        #expect(store.state.connectHWWalletCoordFlowState.ledgerRepairTarget == account.id)
        #expect(store.state.connectHWWalletCoordFlowState.path.count == 1)
        #expect(store.state.connectHWWalletCoordFlowState.path.last?.is(\.addLedgerHWWallet) == true)

        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.ledgerSignSheetDismissed)))))

        await waitForRootState { store.state.path == .connectHWWalletCoordFlow }

        #expect(store.state.path == .connectHWWalletCoordFlow)
        #expect(store.state.isLedgerRepairAwaitingSheetDismissal == false)
        // The target survives the switch -- the connect flow still needs it once it opens.
        #expect(store.state.connectHWWalletCoordFlowState.ledgerRepairTarget == account.id)
    }

    /// `scanCoordFlow`'s `requestZecConfirmation` path element -- the second host/element pairing
    /// the first test doesn't cover.
    @Test func pairLedgerFromRequestZecOnScanStagesRepairThenOpensConnectFlowOnDismissal() async throws {
        let account = Self.ledgerAccount()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.scanCoordFlowState.path.append(.requestZecConfirmation(SendConfirmation.State.initial))
        let elementId = try #require(initialState.scanCoordFlowState.path.ids.first)
        initialState.path = .scanCoordFlow

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.scanCoordFlow(.path(.element(id: elementId, action: .requestZecConfirmation(.pairLedgerTapped)))))

        #expect(store.state.path == .scanCoordFlow)
        #expect(store.state.connectHWWalletCoordFlowState.ledgerRepairTarget == account.id)

        store.send(.scanCoordFlow(.path(.element(id: elementId, action: .requestZecConfirmation(.ledgerSignSheetDismissed)))))

        await waitForRootState { store.state.path == .connectHWWalletCoordFlow }

        #expect(store.state.path == .connectHWWalletCoordFlow)
    }

    /// `swapAndPayCoordFlow`'s `ledgerConfirmation` -- a scoped child, not a path element.
    @Test func pairLedgerFromSwapLedgerConfirmationStagesRepairThenOpensConnectFlowOnDismissal() async throws {
        let account = Self.ledgerAccount()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.path = .swapAndPayCoordFlow

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.swapAndPayCoordFlow(.ledgerConfirmation(.pairLedgerTapped)))

        #expect(store.state.path == .swapAndPayCoordFlow)
        #expect(store.state.connectHWWalletCoordFlowState.ledgerRepairTarget == account.id)

        store.send(.swapAndPayCoordFlow(.ledgerConfirmation(.ledgerSignSheetDismissed)))

        await waitForRootState { store.state.path == .connectHWWalletCoordFlow }

        #expect(store.state.path == .connectHWWalletCoordFlow)
    }

    /// `signWithKeystoneCoordFlow`'s `sendConfirmation` -- the shielding host, whose sheet Root
    /// presents itself directly over Home (`path` stays `nil` the whole time until the switch).
    /// The existing `.ledgerShieldingSheetDismissed` arm also fires from the same dismissal and
    /// stays a no-op here: `signWithKeystoneCoordFlowState.path` is empty because Pair Ledger, like
    /// Cancel, never pushes anything onto it.
    @Test func pairLedgerFromShieldingStagesRepairThenOpensConnectFlowOnDismissal() async throws {
        let account = Self.ledgerAccount()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        store.send(.signWithKeystoneCoordFlow(.sendConfirmation(.pairLedgerTapped)))

        #expect(store.state.path == nil)
        #expect(store.state.connectHWWalletCoordFlowState.ledgerRepairTarget == account.id)

        store.send(.signWithKeystoneCoordFlow(.sendConfirmation(.ledgerSignSheetDismissed)))

        await waitForRootState { store.state.path == .connectHWWalletCoordFlow }

        #expect(store.state.path == .connectHWWalletCoordFlow)
        #expect(store.state.signWithKeystoneCoordFlowBinding == false)
    }

    /// An ordinary dismissal -- nothing staged a repair -- must leave `path` untouched, the same
    /// "no positive signal to wait for" shape `theSheetClosingAfterCancelLeavesThePopoverClosed`
    /// above uses for the existing shielding-only mechanism.
    @Test func anOrdinaryDismissalWithNoPendingRepairLeavesPathUntouched() async throws {
        var initialState = Root.State.initial
        initialState.sendCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))
        let elementId = try #require(initialState.sendCoordFlowState.path.ids.first)
        initialState.path = .sendCoordFlow

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.ledgerClient = .noOp
        }

        // No preceding `.pairLedgerTapped` -- e.g. Cancel Transaction's own dismissal.
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.ledgerSignSheetDismissed)))))

        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(store.state.path == .sendCoordFlow)
        #expect(store.state.connectHWWalletCoordFlowState.ledgerRepairTarget == nil)
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
