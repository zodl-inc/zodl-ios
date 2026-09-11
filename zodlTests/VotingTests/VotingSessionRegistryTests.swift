#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// The registry's bookkeeping, exercised without a live session.
///
/// A `VotingRoundSession` can only be made by the SDK — the backend call that
/// builds one is internal to it — so the registry takes its factory as an
/// injected closure and these tests give it one that refuses. That covers every
/// path that does not need a session in hand: the empty registry, a refused
/// open, and the two teardown calls.
@Suite struct VotingSessionRegistryTests {
    private let roundId = "a1b2c3"

    @Test func sessionForAnUnopenedRoundThrowsNotOpen() async throws {
        let registry = makeRegistry()

        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    @Test func aRefusedOpenSurfacesTheFactoryErrorAndLeavesTheRegistryEmpty() async throws {
        let registry = makeRegistry()

        let error = await #expect(throws: VotingError.self) {
            _ = try await registry.open(
                inputs: VotingSessionRegistryTests.inputs(roundId: roundId),
                binding: VotingSessionBinding(roster: []),
                route: .direct,
                epoch: 0
            )
        }

        #expect(error?.kind == .internal)
        #expect(await registry.openRoundIds.isEmpty)
        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    @Test func closingARoundThatWasNeverOpenedLeavesItUnopened() async throws {
        let registry = makeRegistry()

        await registry.close(roundId)

        #expect(await registry.openRoundIds.isEmpty)
        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    @Test func closeAllEmptiesTheRegistryAndMovesTheGenerationOn() async throws {
        let registry = makeRegistry()
        let before = await registry.generation

        await registry.closeAll()

        #expect(await registry.openRoundIds.isEmpty)
        #expect(await registry.generation == before + 1)
    }

    /// A registry whose factory is the app's own wiring — the synchronizer
    /// dependency's session factory — backed by the no-op client, which refuses
    /// rather than reaching the SDK.
    private func makeRegistry() -> VotingSessionRegistry {
        let synchronizer = SDKSynchronizerClient.noOp
        let backend = VotingRustBackend()

        return VotingSessionRegistry { inputs, binding, route, epoch in
            try await synchronizer.makeVotingRoundSession(backend, inputs, binding, route, epoch)
        }
    }

    private static func inputs(roundId: String) -> VotingSessionInputs {
        VotingSessionInputs(
            accountUUID: "11111111-1111-1111-1111-111111111111",
            walletDbPath: "/dev/null",
            roundParams: VotingRoundParameters(
                voteRoundId: roundId,
                snapshotHeight: 4_200_000,
                eaPk: Data(repeating: 0x01, count: 32),
                ncRoot: Data(repeating: 0x02, count: 32),
                nullifierImtRoot: Data(repeating: 0x03, count: 32)
            ),
            roundName: "registry test round",
            anchorTreeState: Data(),
            chainEndpoints: [],
            voteTreeNodeUrls: [],
            helperUrls: [],
            pirEndpoints: [],
            pirLayout: VotingPirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: 2048)
        )
    }
}
#endif
