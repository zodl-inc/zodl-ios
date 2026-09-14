//
//  VotingProvingPromotionTests.swift
//  zodlTests
//

#if VOTING_ENABLED
import Foundation
import Testing
@testable import zodl_internal

/// Covers `VotingProvingPromotion`, which pairs the SDK's scoped interactive proving boost with
/// the speculative proofs of one precompute run: `promote()` arms the promotion and, if a
/// speculative proof is already in flight, starts holding the boost; a speculative proof that
/// starts while armed also holds it; the hold is released when the last in-flight proof ends or
/// when the run is reset. `boost` is injected so these tests can observe begin/end pairing
/// without the real SDK helper — it records "begin", awaits the body, then records "end", the
/// same pairing guarantee `VotingRustBackend.withInteractiveProvingBoost`'s own `defer` gives on
/// every exit path.
@Suite(.timeLimit(.minutes(1)))
struct VotingProvingPromotionTests {
    @Test func promoteWhileASpeculativeProofRunsBeginsTheBoostOnce() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        promotion.speculativeProofStarted()
        promotion.promote()
        promotion.promote()
        await records.countReached(1)
        #expect(records.values == ["begin"])

        promotion.speculativeProofEnded()
        await records.countReached(2)
        #expect(records.values == ["begin", "end"])
    }

    @Test func promoteWithNothingInFlightArmsTheNextSpeculativeProof() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        promotion.promote()
        promotion.speculativeProofStarted()
        await records.countReached(1)
        #expect(records.values == ["begin"])

        promotion.speculativeProofEnded()
        await records.countReached(2)
        #expect(records.values == ["begin", "end"])
    }

    @Test func thePromotionOutlivesConsecutiveSpeculativeProofs() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        promotion.speculativeProofStarted()
        promotion.promote()
        await records.countReached(1)
        #expect(records.values == ["begin"])

        promotion.speculativeProofEnded()
        await records.countReached(2)
        #expect(records.values == ["begin", "end"])

        promotion.speculativeProofStarted()
        await records.countReached(3)
        #expect(records.values == ["begin", "end", "begin"])

        promotion.speculativeProofEnded()
        await records.countReached(4)
        #expect(records.values == ["begin", "end", "begin", "end"])
    }

    @Test func resetDisarmsThePromotion() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        promotion.promote()
        promotion.reset()
        promotion.speculativeProofStarted()
        promotion.speculativeProofEnded()

        promotion.promote()
        promotion.speculativeProofStarted()
        await records.countReached(1)
        #expect(records.values == ["begin"])

        promotion.speculativeProofEnded()
        await records.countReached(2)
        #expect(records.values == ["begin", "end"])
    }

    @Test func endedWithoutPromotionNeverTouchesTheBoost() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        promotion.speculativeProofStarted()
        promotion.speculativeProofEnded()

        promotion.promote()
        promotion.speculativeProofStarted()
        await records.countReached(1)
        #expect(records.values == ["begin"])

        promotion.speculativeProofEnded()
        await records.countReached(2)
        #expect(records.values == ["begin", "end"])
    }

    @Test func releaseBeforeTheHoldRegistersStillEndsTheBoost() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        // No `await` between these three calls: the task `speculativeProofStarted()` spawns to
        // hold the boost cannot have run yet (an unstructured `Task` needs a scheduling hop), so
        // `speculativeProofEnded()`'s release is guaranteed to run before the hold task's own
        // continuation registers — the early-release race.
        promotion.promote()
        promotion.speculativeProofStarted()
        promotion.speculativeProofEnded()

        await records.countReached(2)
        #expect(records.values == ["begin", "end"])
    }
}

/// A `VotingProvingPromotion.Boost` that records "begin", awaits the body, then records "end" —
/// standing in for `VotingRustBackend.withInteractiveProvingBoost`.
private func recordingBoost(_ records: SignalledRecords<String>) -> VotingProvingPromotion.Boost {
    { body in
        records.record("begin")
        await body()
        records.record("end")
    }
}
#endif
