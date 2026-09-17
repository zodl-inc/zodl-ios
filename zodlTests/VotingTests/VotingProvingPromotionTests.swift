//
//  VotingProvingPromotionTests.swift
//  zodlTests
//

#if VOTING_ENABLED
import Foundation
import Testing
import os
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
    @Test func aProofStartingDuringAnEarlyReleaseStillGetsTheBoost() async throws {
        let records = SignalledRecords<String>()
        let gate = ResumableGate()
        // The gate parks the hold task after it has entered the boost but before its
        // continuation registers, holding the early-release window open on purpose.
        let promotion = VotingProvingPromotion(boost: { body in
            records.record("begin")
            await gate.wait()
            await body()
            records.record("end")
        })

        promotion.promote()
        promotion.speculativeProofStarted()
        await records.countReached(1)
        promotion.speculativeProofEnded()
        promotion.speculativeProofStarted()
        gate.open()

        // The parked hold releases and, because a proof is still in flight, a fresh hold begins;
        // the order of that end and the new begin is not fixed, so count them.
        await records.countReached(3)
        #expect(records.values.filter { $0 == "begin" }.count == 2)
        #expect(records.values.filter { $0 == "end" }.count == 1)

        promotion.speculativeProofEnded()
        await records.countReached(4)
        #expect(records.values.filter { $0 == "end" }.count == 2)
    }

    /// A cancelled run's proof keeps running inside native code and reports its end after the
    /// replacement run's proof has started. If the decision to release and the hold's state change
    /// are not one critical section, the replacement can see the old hold still active, skip taking
    /// its own, and then lose the old one: armed, in flight, and unboosted, with nothing left to
    /// notice. The seam starts the replacement exactly at the decision point.
    @Test func aReplacementStartingAtTheReleaseDecisionKeepsTheBoost() async throws {
        let records = SignalledRecords<String>()
        let holdRegistered = ResumableGate()
        let replacement = OSAllocatedUnfairLock<VotingProvingPromotion?>(initialState: nil)
        let replacementStarted = OSAllocatedUnfairLock(initialState: false)
        let promotion = VotingProvingPromotion(
            boost: recordingBoost(records),
            afterHoldRegistered: { holdRegistered.open() },
            afterReleaseDecision: {
                // Only the first decision — the first proof's end — starts the replacement; the
                // replacement's own end must not start a third proof.
                let isFirst = replacementStarted.withLock { started -> Bool in
                    guard !started else { return false }
                    started = true
                    return true
                }
                guard isFirst else { return }
                replacement.withLock { $0 }?.speculativeProofStarted()
            }
        )
        replacement.withLock { $0 = promotion }

        promotion.promote()
        promotion.speculativeProofStarted()
        await records.countReached(1)
        // The hold's continuation is registered: the release will resume it directly rather than
        // taking the early-release path, which re-acquires on its own.
        await holdRegistered.wait()

        // Ends the first proof; the seam starts the replacement between the decision and the
        // resume. The replacement must take a hold of its own, so a second begin joins the first end.
        promotion.speculativeProofEnded()
        await records.countReached(3)
        #expect(records.values.filter { $0 == "begin" }.count == 2)
        #expect(records.values.filter { $0 == "end" }.count == 1)

        promotion.speculativeProofEnded()
        await records.countReached(4)
        #expect(records.values.filter { $0 == "end" }.count == 2)
    }

    /// Every hold the promotion starts is ended, whatever order the events arrive in: a reset
    /// landing while a proof is still in flight, a promote landing after the last proof ended.
    @Test func everyBeginHasAnEndAcrossAScriptedInterleaving() async throws {
        let records = SignalledRecords<String>()
        let promotion = VotingProvingPromotion(boost: recordingBoost(records))

        promotion.speculativeProofStarted()
        promotion.promote()
        await records.countReached(1)
        promotion.speculativeProofStarted()
        promotion.speculativeProofEnded()
        promotion.reset()
        await records.countReached(2)
        #expect(records.values == ["begin", "end"])

        promotion.speculativeProofEnded()
        promotion.promote()
        promotion.speculativeProofStarted()
        await records.countReached(3)
        promotion.speculativeProofEnded()
        await records.countReached(4)
        #expect(records.values == ["begin", "end", "begin", "end"])
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
