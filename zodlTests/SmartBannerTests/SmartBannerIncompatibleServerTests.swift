//
//  SmartBannerIncompatibleServerTests.swift
//  zodlTests
//
//  Covers the Syncing Error sheet's incompatible-server route (#1948): `.synchronizerStateChanged`
//  classifying the sync failure into `lastKnownErrorIsIncompatibleServer`, which gates the
//  "Switch server" ActionRow in SmartBannerHelpSheet, and `.serverSwitchRequested` dismissing
//  whichever sheet it was triggered from.
//
//  The error classification itself lives in UtilTests/IncompatibleServerDiagnosticsTests.swift.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `SmartBanner.State` carries TCA `@Shared` state (`selectedWalletAccount`, `walletStatus`),
// i.e. process-global storage — serialized per repo convention, matching the sibling suites.
@Suite(.serialized) @MainActor struct SmartBannerIncompatibleServerTests {
    private static let incompatibleServerError = ZcashError.compactBlockProcessorWrongConsensusBranchId(
        ConsensusBranchID(1_412_952_880),   // NU6.2
        ConsensusBranchID(933_566_043)      // NU6.3 (Ironwood)
    )

    private static func syncState(_ status: SyncStatus) -> RedactableSynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = status
        return state.redacted
    }

    private func makeStore() -> TestStore<SmartBanner.State, SmartBanner.Action> {
        let store = TestStore(initialState: SmartBanner.State()) {
            SmartBanner()
        } withDependencies: {
            $0.mainQueue = .immediate
            // Reached through `SyncStatusSnapshot.snapshotFor` -> `incompatibleServerMessage`, which
            // names the server in the message an incompatible-server failure produces.
            $0.zcashSDKEnvironment.serverConfig = {
                UserPreferencesStorage.ServerConfig(host: "outdated.example.com", port: 443, isCustom: false)
            }
            // `.reportPrepared` calls `SupportDataGenerator.generate()`, which reads the Tor setup
            // flag from the keychain — an unimplemented closure by default.
            $0.walletStorage = .noOp
        }
        store.exhaustivity = .off
        return store
    }

    @Test func serverValidationFailureFlagsTheErrorAsIncompatibleServer() async {
        let store = makeStore()

        await store.send(.synchronizerStateChanged(Self.syncState(.error(Self.incompatibleServerError))))

        #expect(store.state.lastKnownErrorIsIncompatibleServer)
        // The sheet's body text is the same string, so it must carry the diagnostics too.
        #expect(store.state.lastKnownErrorMessage.contains("outdated.example.com:443"))
        #expect(store.state.lastKnownErrorMessage.contains("0x5437f330"))
        #expect(store.state.lastKnownErrorMessage.contains("0x37a5165b"))
    }

    /// A generic sync error must NOT offer the server switch — retrying is the right remedy there,
    /// and pointing users at Server Setup for a transient failure would be actively misleading.
    @Test func genericSyncErrorDoesNotFlagIncompatibleServer() async {
        let store = makeStore()

        await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))

        #expect(store.state.lastKnownErrorIsIncompatibleServer == false)
    }

    /// `.unprepared` also routes into the priority-2 branch, but carries no error to classify.
    @Test func unpreparedStatusDoesNotFlagIncompatibleServer() async {
        let store = makeStore()

        await store.send(.synchronizerStateChanged(Self.syncState(.unprepared)))

        #expect(store.state.lastKnownErrorIsIncompatibleServer == false)
    }

    /// Recovering from an incompatible server to an ordinary failure must clear the flag, otherwise
    /// the row would linger on an unrelated error.
    ///
    /// Guards the `isDifferentError` check in the reducer: `SyncStatus.==` treats **any** two
    /// `.error` values as equal (Synchronizer.swift), so a status comparison alone never sees one
    /// error replace another and both this flag and `lastKnownErrorMessage` would go stale.
    @Test func laterGenericErrorClearsTheFlag() async {
        let store = makeStore()

        await store.send(.synchronizerStateChanged(Self.syncState(.error(Self.incompatibleServerError))))
        #expect(store.state.lastKnownErrorIsIncompatibleServer)

        await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
        #expect(store.state.lastKnownErrorIsIncompatibleServer == false)
    }

    /// #1948's second requirement is that the user can *relay* this to Application Support, which
    /// means the diagnostics have to survive into the report body — one hop past
    /// `lastKnownErrorMessage`, where `.reportPrepared` composes it with the generated support data.
    /// Asserted across both branches, since it depends on whether Mail is configured on the host.
    @Test func supportReportCarriesTheServerAndBranchIds() async {
        let store = makeStore()

        await store.send(.synchronizerStateChanged(Self.syncState(.error(Self.incompatibleServerError))))
        await store.send(.reportPrepared)

        let reportBody = store.state.supportData?.message ?? store.state.messageToBeShared ?? ""

        #expect(reportBody.contains("Server: outdated.example.com:443"))
        #expect(reportBody.contains("Expected branch ID: 0x5437f330"))
        #expect(reportBody.contains("Server's branch ID: 0x37a5165b"))
        #expect(reportBody.contains("Error code: ZCBPEO0011"))
    }

    /// The row lives in the Syncing Error sheet (`isSmartBannerSheetPresented`) while the identical
    /// row in the sync-timeout sheet uses `isSyncTimedOutSheetPresented`; navigating to Server Setup
    /// has to dismiss whichever one is up.
    @Test func serverSwitchRequestDismissesEitherSheet() async {
        let store = makeStore()

        // Default state has no `priorityContent`, so tapping the banner falls through to presenting
        // the help sheet (the Syncing Error sheet for priority 2) rather than any special-cased route.
        await store.send(.smartBannerContentTapped)
        #expect(store.state.isSmartBannerSheetPresented)

        await store.send(.serverSwitchRequested)

        #expect(store.state.isSmartBannerSheetPresented == false)
        #expect(store.state.isSyncTimedOutSheetPresented == false)
    }
}
