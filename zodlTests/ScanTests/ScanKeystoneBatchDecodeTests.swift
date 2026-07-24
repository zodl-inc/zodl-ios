//
//  ScanKeystoneBatchDecodeTests.swift
//  zodlTests
//
//  MOB-1513: covers the shared `Scan` reducer's Keystone migration-batch decode wiring
//  (Features/Scan/ScanStore.swift) — the real SDK batch-signing bridge replacing the pre-real-SDK
//  `.foundPCZTBatch([Pczt])` shape (see `ScanFoundPCZTBatchTests.swift`'s former header for that old
//  shape's own rationale, now obsolete). `KeystoneMigrationBatchScanChecker` can't await
//  `decodeKeystoneSignBatchPart` itself (`ScanChecker.checkQRCode` is synchronous), so it always
//  matches and hands the raw frame back as `.keystoneBatchPartScanned`; this reducer runs the actual
//  decode as an effect and reports progress/completion/failure from there. Also covers the
//  `resetKeystoneSignBatchDecoder()` calls on scan-screen entry/exit, gated on the migration-batch
//  checker actually being configured for the session, and `countedProgress`'s direct-progress
//  override. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ScanKeystoneBatchDecodeTests {
    // MARK: - KeystoneMigrationBatchScanChecker: always matches, never inspects content

    @Test func keystoneMigrationBatchScanCheckerAlwaysReturnsPartScannedAction() {
        let checker = KeystoneMigrationBatchScanChecker()

        #expect(checker.checkQRCode("UR:BYTES/1-3/ANYTHING") == .keystoneBatchPartScanned("UR:BYTES/1-3/ANYTHING"))
        #expect(checker.checkQRCode("") == .keystoneBatchPartScanned(""))
    }

    // MARK: - keystoneBatchPartScanned: decode progress / completion / failure

    /// A non-complete decode result updates `progress`/`keystoneBatchDirectProgress` and does NOT
    /// proceed — `isAnythingFound` stays `false`, so the scan session keeps accepting frames.
    @MainActor @Test func keystoneBatchPartScannedWithIncompleteDecodeUpdatesProgressAndDoesNotProceed() async {
        let decodeCalls = LockIsolated<[(part: String, requestId: Data)]>([])
        let requestId = Data([0x01, 0x02, 0x03])
        var state = Scan.State.initial
        state.checkers = [.keystoneMigrationBatchScanChecker]
        state.keystoneBatchRequestId = requestId
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.decodeKeystoneSignBatchPart = { part, expectedRequestId in
                decodeCalls.withValue { $0.append((part, expectedRequestId)) }
                return KeystoneBatchDecodeResult(complete: false, progress: 42, data: nil, firmwareVersion: nil)
            }
        }

        await store.send(.keystoneBatchPartScanned("FRAME1"))
        await store.receive(.keystoneBatchDecodeProgress(42)) {
            $0.keystoneBatchDirectProgress = 42
            $0.progress = 42
        }

        #expect(decodeCalls.value.count == 1)
        #expect(decodeCalls.value.first?.part == "FRAME1")
        #expect(decodeCalls.value.first?.requestId == requestId)
        #expect(store.state.isAnythingFound == false)
    }

    /// The completed decode session reports the batch-signature response and firmware version —
    /// `isAnythingFound` flips (so further scans are ignored, matching every sibling `.found*`
    /// case) and the in-flight progress display clears.
    @MainActor @Test func keystoneBatchPartScannedWithCompleteDecodeEmitsFoundSignaturesAndClearsProgress() async {
        let responseData = Data([0xAA, 0xBB, 0xCC])
        let firmwareVersion = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2)
        var state = Scan.State.initial
        state.progress = 80
        state.keystoneBatchDirectProgress = 80
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.decodeKeystoneSignBatchPart = { _, _ in
                KeystoneBatchDecodeResult(complete: true, progress: 100, data: responseData, firmwareVersion: firmwareVersion)
            }
        }

        await store.send(.keystoneBatchPartScanned("FRAMELAST"))
        await store.receive(.foundKeystoneBatchSignatures(data: responseData, firmwareVersion: firmwareVersion)) {
            $0.isAnythingFound = true
            $0.progress = nil
            $0.keystoneBatchDirectProgress = nil
        }
    }

    /// A completed decode whose envelope reported NO firmware version still reaches
    /// `.foundKeystoneBatchSignatures` with `firmwareVersion == nil` — the coordinator's minimum-
    /// firmware gate is what treats that as a failure, not this reducer.
    @MainActor @Test func keystoneBatchPartScannedWithCompleteDecodeAndNilFirmwareStillReportsFound() async {
        let responseData = Data([0x01])
        let store = TestStore(initialState: Scan.State.initial) {
            Scan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.decodeKeystoneSignBatchPart = { _, _ in
                KeystoneBatchDecodeResult(complete: true, progress: 100, data: responseData, firmwareVersion: nil)
            }
        }

        await store.send(.keystoneBatchPartScanned("FRAMELAST"))
        await store.receive(.foundKeystoneBatchSignatures(data: responseData, firmwareVersion: nil)) {
            $0.isAnythingFound = true
        }
    }

    /// `decodeKeystoneSignBatchPart` throwing (a request-id mismatch at completion, or any other
    /// decode failure) reports `.keystoneBatchDecodeFailed` — the initiating coordinator abandons the
    /// ceremony (`keystoneScanAbandoned` semantics) on observing this, treated like a rejected scan.
    @MainActor @Test func keystoneBatchPartScannedDecodeThrowEmitsDecodeFailed() async {
        struct DecodeFailure: Error { }
        let store = TestStore(initialState: Scan.State.initial) {
            Scan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.decodeKeystoneSignBatchPart = { _, _ in throw DecodeFailure() }
        }

        await store.send(.keystoneBatchPartScanned("BADFRAME"))
        await store.receive(.keystoneBatchDecodeFailed)

        #expect(store.state.isAnythingFound == false)
    }

    // MARK: - resetKeystoneSignBatchDecoder(): entry/exit, gated on the migration-batch checker

    /// Scan-screen entry resets the SDK's process-wide decode session when this session IS a
    /// Keystone migration-batch scan — a fresh attempt always starts from a clean slate.
    @MainActor @Test func onAppearResetsKeystoneBatchDecoderWhenMigrationBatchCheckerConfigured() async {
        let resetCalls = LockIsolated<Int>(0)
        var state = Scan.State.initial
        state.checkers = [.keystoneMigrationBatchScanChecker]
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.captureDevice = .noOp
            $0.captureDevice.isAuthorized = { true }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.resetKeystoneSignBatchDecoder = { resetCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.finish()

        #expect(resetCalls.value == 1)
    }

    /// Scan-screen exit ALSO resets — regardless of how the previous attempt ended (cancel, back
    /// button, mid-stream decode failure), so the next entry starts clean.
    @MainActor @Test func onDisappearResetsKeystoneBatchDecoderWhenMigrationBatchCheckerConfigured() async {
        let resetCalls = LockIsolated<Int>(0)
        var state = Scan.State.initial
        state.checkers = [.keystoneMigrationBatchScanChecker]
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.resetKeystoneSignBatchDecoder = { resetCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.onDisappear)
        await store.finish()

        #expect(resetCalls.value == 1)
    }

    /// Every OTHER scan use case (address, request-zec, the single-PCZT Keystone flows, swap,
    /// voting) never touches this decoder — entry must not reset it. `sdkSynchronizer` is left at
    /// its default `.testValue`: any unexpected call to any of its members traps the test.
    @MainActor @Test func onAppearNeverTouchesKeystoneBatchDecoderWhenMigrationBatchCheckerAbsent() async {
        var state = Scan.State.initial
        state.checkers = [.zcashAddressScanChecker]
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.captureDevice = .noOp
            $0.captureDevice.isAuthorized = { true }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.finish()
    }

    /// Twin of the above for exit.
    @MainActor @Test func onDisappearNeverTouchesKeystoneBatchDecoderWhenMigrationBatchCheckerAbsent() async {
        var state = Scan.State.initial
        state.checkers = [.zcashAddressScanChecker]
        let store = TestStore(initialState: state) {
            Scan()
        }
        store.exhaustivity = .off

        await store.send(.onDisappear)
        await store.finish()
    }

    // MARK: - countedProgress: direct-progress override

    @Test func countedProgressPrefersDirectProgressWhenSet() {
        var state = Scan.State.initial
        state.keystoneBatchDirectProgress = 55
        #expect(state.countedProgress == 55)

        state.keystoneBatchDirectProgress = 0
        #expect(state.countedProgress == 0)

        // Clamped like the reportedParts/expectedParts formula below it.
        state.keystoneBatchDirectProgress = 150
        #expect(state.countedProgress == 99)
    }

    @Test func countedProgressFallsBackToReportedPartsFormulaWhenDirectProgressIsNil() {
        var state = Scan.State.initial
        state.keystoneBatchDirectProgress = nil
        state.reportedParts = 4
        state.expectedParts = 8

        #expect(state.countedProgress == 50)
    }
}
