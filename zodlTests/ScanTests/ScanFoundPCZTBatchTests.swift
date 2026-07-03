//
//  ScanFoundPCZTBatchTests.swift
//  zodlTests
//
//  Covers the new `.foundPCZTBatch([Pczt])` action on the shared `Scan` reducer
//  (Features/Scan/ScanStore.swift), added for MOB-1468 migration Keystone batch signing: reaching
//  it sets `isAnythingFound`/`progress` exactly like the sibling `.foundPCZT`/
//  `.foundVotingDelegationPCZT` cases, additive and otherwise inert (`.none`).
//
//  `KeystoneMigrationBatchScanChecker.checkQRCode` (ScanChecker.swift) is NOT unit-testable here:
//  `KeystoneSDK.DecodeResult`'s only initializer is `internal` to the `KeystoneSDK` module, so a
//  `DecodeResult` carrying a real `UR` (the 100%-progress, parse-ready case) cannot be constructed
//  from this test target — only `KeystoneSDK().decodeQR(_:)` driven by real animated-QR fragment
//  strings can produce one. The checker's accumulate→parse→action path is exercised by the
//  MigrationCoordFlowTests Keystone-signing block instead (same PR), with
//  `sdkSynchronizer.parseMigrationPCZTBatch` stubbed. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ScanFoundPCZTBatchTests {
    @MainActor @Test func foundPCZTBatchSetsAnythingFoundAndClearsProgress() async {
        let store = TestStore(initialState: Scan.State(info: "scanning")) {
            Scan()
        }

        // Simulate the accumulate-with-progress phase having reported a mid-scan percentage
        // before the completed batch UR resolved — the same sequence a real scan produces.
        await store.send(.animatedQRProgress(42, 3, 5)) {
            $0.reportedPart = 3
            $0.reportedParts = 1
            $0.expectedParts = 8
            $0.progress = 42
        }

        await store.send(.foundPCZTBatch([Pczt(), Pczt()])) {
            $0.isAnythingFound = true
            $0.progress = nil
        }
    }
}
