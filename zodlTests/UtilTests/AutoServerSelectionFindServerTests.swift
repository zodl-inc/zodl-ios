import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `findBestServer` after the SDK-side decision move: the app only checks the Automatic flag,
// filters candidates by migration pinning, and delegates the switch decision to the SDK.
@Suite struct AutoServerSelectionFindServerTests {
    private final class Recorder: @unchecked Sendable {
        var callCount = 0
        var current: LightWalletEndpoint?
        var candidates: [LightWalletEndpoint] = []
        var fetchThreshold: Double?
        var nBlocks: UInt64?
    }

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    private func runFind(
        flag: Bool?,
        current: LightWalletEndpoint,
        sdkDecision: LightWalletEndpoint?,
        recorder: Recorder
    ) async -> LightWalletEndpoint? {
        await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { flag }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.sdkSynchronizer.evaluateServerSwitch = { current, candidates, fetchThreshold, nBlocks, _ in
                recorder.callCount += 1
                recorder.current = current
                recorder.candidates = candidates
                recorder.fetchThreshold = fetchThreshold
                recorder.nBlocks = nBlocks
                return sdkDecision
            }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }
    }

    @Test func flagOffShortCircuitsWithoutBenchmark() async {
        let recorder = Recorder()
        let result = await runFind(flag: false, current: endpoint("zec.rocks"), sdkDecision: endpoint("na.zec.rocks"), recorder: recorder)
        #expect(result == nil)
        #expect(recorder.callCount == 0)
    }

    @Test func nilDecisionMeansStay() async {
        let recorder = Recorder()
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), sdkDecision: nil, recorder: recorder)
        #expect(result == nil)
        #expect(recorder.callCount == 1)
    }

    @Test func decisionPropagatesAsCandidate() async {
        let recorder = Recorder()
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), sdkDecision: endpoint("na.zec.rocks"), recorder: recorder)
        #expect(result?.host == "na.zec.rocks")
    }

    @Test func delegatesCurrentAllCandidatesAndConstants() async {
        let recorder = Recorder()
        let current = endpoint("zec.rocks")
        _ = await runFind(flag: true, current: current, sdkDecision: nil, recorder: recorder)
        #expect(recorder.current?.host == "zec.rocks")
        #expect(recorder.candidates.count == ZcashSDKEnvironment.endpoints(for: .mainnet).count)
        #expect(recorder.fetchThreshold == AutoServerSelectionConstants.evaluationTimeoutSeconds)
        #expect(recorder.nBlocks == AutoServerSelectionConstants.blocksToDownload)
    }
}
