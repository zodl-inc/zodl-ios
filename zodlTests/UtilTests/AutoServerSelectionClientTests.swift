import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

final class AutoServerSelectionClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var switchedTo: LightWalletEndpoint?
        var persisted: UserPreferencesStorage.ServerConfig?
    }

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    // MARK: - findBestServer

    /// Runs `findBestServer` with controlled dependencies.
    private func runFind(
        flag: Bool?,
        current: LightWalletEndpoint,
        best: LightWalletEndpoint?
    ) async -> LightWalletEndpoint? {
        await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { flag }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in best.map { [$0] } ?? [] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }
    }

    func testFindNoOpWhenFlagOff() async {
        let result = await runFind(flag: false, current: endpoint("zec.rocks"), best: endpoint("na.zec.rocks"))
        XCTAssertNil(result)
    }

    func testFindNilWhenBestEqualsCurrent() async {
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), best: endpoint("zec.rocks"))
        XCTAssertNil(result)
    }

    func testFindNilWhenBenchmarkEmpty() async {
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), best: nil)
        XCTAssertNil(result)
    }

    func testFindReturnsCandidateWhenDifferent() async {
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), best: endpoint("na.zec.rocks"))
        XCTAssertEqual(result?.host, "na.zec.rocks")
    }

    // MARK: - applySwitch

    /// Runs `applySwitch` with controlled dependencies and returns (didSwitch, recorder).
    private func runApply(
        flag: Bool?,
        current: LightWalletEndpoint,
        candidate: LightWalletEndpoint,
        guardBusy: Bool = false
    ) async -> (didSwitch: Bool, recorder: Recorder) {
        let recorder = Recorder()
        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { flag }
            $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.sdkSynchronizer.switchToEndpoint = { recorder.switchedTo = $0 }
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                tryAcquire: { !guardBusy },
                release: {}
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(candidate)
        }
        return (didSwitch, recorder)
    }

    func testApplySwitchesAndPersists() async {
        let (didSwitch, r) = await runApply(flag: true, current: endpoint("zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(r.switchedTo?.host, "na.zec.rocks")
        XCTAssertEqual(r.persisted?.host, "na.zec.rocks")
        XCTAssertEqual(r.persisted?.isCustom, false)
    }

    func testApplySkipsWhenGuardBusy() async {
        let (didSwitch, r) = await runApply(
            flag: true,
            current: endpoint("zec.rocks"),
            candidate: endpoint("na.zec.rocks"),
            guardBusy: true
        )
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyNoOpWhenFlagTurnedOff() async {
        // The user may flip to Manual while a candidate sits deferred.
        let (didSwitch, r) = await runApply(flag: false, current: endpoint("zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyNoOpWhenCandidateEqualsCurrent() async {
        // A manual switch may have landed on the candidate while it sat deferred.
        let (didSwitch, r) = await runApply(flag: true, current: endpoint("na.zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyReturnsFalseWhenSwitchThrows() async {
        let recorder = Recorder()
        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0) }
            $0.sdkSynchronizer.switchToEndpoint = { _ in throw URLError(URLError.Code.timedOut) }
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                tryAcquire: { true },
                release: {}
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            )
        }
        XCTAssertFalse(didSwitch)
        XCTAssertNil(recorder.persisted)
    }
}
