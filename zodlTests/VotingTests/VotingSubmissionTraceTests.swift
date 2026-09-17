#if VOTING_ENABLED
//
//  VotingSubmissionTraceTests.swift
//  zodlTests
//

import Foundation
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(1)))
struct VotingSubmissionTraceTests {
    private struct StepFailure: Error {}

    @Test func endAndFailedLinesFollowTheSharedFormat() {
        let context = VotingSubmissionTrace.context(roundId: "aabbccddeeff0011", bundleIndex: 1, proposalId: 7)
        #expect(context == "round=aabbccdd bundle=1 proposal=7")
        #expect(VotingSubmissionTrace.context(roundId: "aabbccddeeff0011") == "round=aabbccdd")

        #expect(
            VotingSubmissionTrace.endLine(step: "confirm", context: context, milliseconds: 1250, detail: "attempts=3")
                == "Voting trace end confirm round=aabbccdd bundle=1 proposal=7 ms=1250 attempts=3"
        )
        #expect(
            VotingSubmissionTrace.endLine(step: "sync", context: context, milliseconds: 40)
                == "Voting trace end sync round=aabbccdd bundle=1 proposal=7 ms=40"
        )
        let failed = VotingSubmissionTrace.failedLine(step: "prove", context: context, milliseconds: 5, error: StepFailure())
        #expect(failed.hasPrefix("Voting trace failed prove round=aabbccdd bundle=1 proposal=7 ms=5 error="))
    }

    @Test func measureLogsOneEndLineAndReturnsTheResult() async throws {
        let lines = SignalledRecords<String>()
        let totals = VotingSubmissionTrace.Totals()

        let value = try await VotingSubmissionTrace.measure("prove", "round=aabbccdd", totals: totals, sink: { lines.record($0) }) {
            42
        }

        #expect(value == 42)
        #expect(lines.values.count == 1)
        #expect(lines.values[0].hasPrefix("Voting trace end prove round=aabbccdd ms="))
        #expect(await totals.value("prove") >= 0)
    }

    @Test func measureLogsAFailedLineAndRethrows() async {
        let lines = SignalledRecords<String>()

        await #expect(throws: StepFailure.self) {
            try await VotingSubmissionTrace.measure("broadcast", "round=aabbccdd", sink: { lines.record($0) }) {
                throw StepFailure()
            }
        }

        #expect(lines.values.count == 1)
        #expect(lines.values[0].hasPrefix("Voting trace failed broadcast round=aabbccdd ms="))
    }

    @Test func totalsAccumulateAcrossConcurrentStepsAndSummarize() async {
        let totals = VotingSubmissionTrace.Totals()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { await totals.add("prove", 3) }
                group.addTask { await totals.add("confirm", 5) }
            }
        }

        #expect(await totals.value("prove") == 150)
        #expect(await totals.value("confirm") == 250)
        #expect(await totals.value("deliver") == 0)
        #expect(await totals.summary(["prove", "confirm", "deliver"]) == "proveMs=150 confirmMs=250 deliverMs=0")
    }

    @Test func productionSubmissionSummaryIncludesWholePhaseTotals() async {
        let totals = VotingSubmissionTrace.Totals()
        await totals.add("votes", 250)
        await totals.add("sharesJoin", 40)
        await totals.add("prove", 500)

        let summary = await VotingSubmissionTrace.submissionSummary(
            context: "round=aabbccdd",
            bundleCount: 2,
            questionCount: 3,
            totalMilliseconds: 900,
            totals: totals
        )

        #expect(
            summary == """
            Voting submission work summary round=aabbccdd scope=votePipelines bundles=2 questions=3 \
            pipelineWallMs=900 votesWallMs=250 sharesJoinWallMs=40 proveWorkMs=500 witnessWorkMs=0 \
            syncWorkMs=0 broadcastWorkMs=0 confirmWorkMs=0 recordWorkMs=0 deliverWorkMs=0
            """
        )
    }

    @Test func measureUsesInjectedClockAndAddsOneExactTotal() async throws {
        let reads = SignalledRecords<Void>()
        let origin = ContinuousClock().now
        let now: @Sendable () -> ContinuousClock.Instant = {
            reads.recordCall() == 1 ? origin : origin.advanced(by: .milliseconds(42))
        }
        let lines = SignalledRecords<String>()
        let totals = VotingSubmissionTrace.Totals()

        _ = try await VotingSubmissionTrace.measure(
            "votes",
            "round=aabbccdd",
            totals: totals,
            sink: { lines.record($0) },
            now: now
        ) {
            42
        }

        #expect(await totals.value("votes") == 42)
        #expect(lines.values == ["Voting trace end votes round=aabbccdd ms=42"])
    }
}
#endif
