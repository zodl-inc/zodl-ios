#if VOTING_ENABLED
import Foundation
import Testing
@testable import zodl_internal

/// The tracker ported from the Android app, one test for each of the Android
/// app's own, so both platforms answer the same reports the same way.
@Suite struct VotingRoundProgressTrackerTests {
    private let weight = VotingRoundProgressTracker.delegationPhaseWeight

    // MARK: - The bar

    @Test func theFractionIsNilWhileTheTotalIsUnknown() {
        var tracker = VotingRoundProgressTracker()

        #expect(tracker.fraction(completedProposals: nil, totalProposals: nil) == nil)
        #expect(tracker.fraction(completedProposals: 0, totalProposals: nil) == nil)
    }

    @Test func theFractionIsNilWhileNothingIsMeasuredAndTheTallyIsZero() {
        var tracker = VotingRoundProgressTracker()

        #expect(tracker.fraction(completedProposals: 0, totalProposals: 37) == nil)
    }

    @Test func theFractionIsNilWhileNothingIsMeasuredAndTheTallyIsNotKnownYet() {
        var tracker = VotingRoundProgressTracker()

        #expect(tracker.fraction(completedProposals: nil, totalProposals: 37) == nil)
    }

    @Test func oneRecordedStepGivesAPositiveFraction() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 0.5)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.5 / 37))
    }

    @Test func questionsInFlightAddUp() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 2), proofProgress: 0.5)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 1.5 / 37))
    }

    @Test func aQuestionOnSeveralBundlesMovesWithItsSlowestBundle() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 1, proposalId: 1), proofProgress: 0.2)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.2 / 37))
    }

    @Test func aBundlesProgressOnAQuestionNeverDrops() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 0.8)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 0.1)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.8 / 37))
    }

    @Test func theFractionNeverGoesBackwards() throws {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 2), proofProgress: 1.0)
        // The mutating call is hoisted out of `#require`: swift-testing's macro
        // captures the receiver as an immutable value to re-invoke it for its
        // failure diagnostics, which a `mutating` method cannot be called on.
        let rawHigh = tracker.fraction(completedProposals: 0, totalProposals: 37)
        let high = try #require(rawHigh)

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 3), proofProgress: 0)
        let rawNext = tracker.fraction(completedProposals: 0, totalProposals: 37)
        let next = try #require(rawNext)

        #expect(next >= high)
    }

    @Test func theTallyAloneGivesAFraction() {
        var tracker = VotingRoundProgressTracker()

        #expect(isClose(tracker.fraction(completedProposals: 10, totalProposals: 37), 10.0 / 37))
    }

    @Test func theMeasuredShareWinsWhenItIsFurtherThanTheTally() {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 2), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 3), proofProgress: 1.0)

        #expect(isClose(tracker.fraction(completedProposals: 1, totalProposals: 37), 3.0 / 37))
    }

    // MARK: - Delegation

    @Test func aDelegationStepCountsAtTheDelegationWeight() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 0.5)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.5 / 37 * weight))
    }

    @Test func delegatingBundlesAddUp() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 1.0)
        tracker.record(step: delegate(bundleIndex: 1), proofProgress: 0.5)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 1.5 / 37 * weight))
    }

    @Test func aBundlesDelegationProgressNeverDrops() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 0.8)
        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 0.1)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.8 / 37 * weight))
    }

    @Test func delegationOnOneBundleAddsToCastingOnAnother() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 0.4)
        tracker.record(step: castVote(bundleIndex: 1, proposalId: 5), proofProgress: 0.9)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.9 / 37 + 0.4 / 37 * weight))
    }

    @Test func aBundleThatStartsCastingStopsCountingItsDelegation() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 0.3)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.3 / 37))
    }

    @Test func delegationAloneNeverFillsTheBar() throws {
        var tracker = VotingRoundProgressTracker()
        for bundleIndex in UInt32(0)..<4 {
            tracker.record(step: delegate(bundleIndex: bundleIndex), proofProgress: 1.0)
        }

        let rawFraction = tracker.fraction(completedProposals: 0, totalProposals: 4)
        let fraction = try #require(rawFraction)

        #expect(isClose(fraction, weight))
        #expect(fraction < 1)
    }

    @Test func delegationStaysBoundedWithMoreBundlesThanQuestions() throws {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 1.0)
        tracker.record(step: delegate(bundleIndex: 1), proofProgress: 1.0)

        let rawFraction = tracker.fraction(completedProposals: 0, totalProposals: 1)
        let fraction = try #require(rawFraction)

        #expect(fraction <= weight)
        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 1) == nil)
    }

    @Test func theBarHoldsWhenABundleMovesFromDelegatingToCasting() throws {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 1.0)
        let rawWhileDelegating = tracker.fraction(completedProposals: 0, totalProposals: 37)
        let whileDelegating = try #require(rawWhileDelegating)

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 0.1)
        let rawAfterTransition = tracker.fraction(completedProposals: 0, totalProposals: 37)
        let afterTransition = try #require(rawAfterTransition)

        #expect(afterTransition >= whileDelegating)
    }

    @Test func aReportWithoutAStepOrWithoutProgressRecordsNothing() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: nil, proofProgress: 0.5)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: nil)

        #expect(tracker.fraction(completedProposals: 0, totalProposals: 37) == nil)
    }

    @Test func aZeroTotalNeverDivides() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.fraction(completedProposals: 0, totalProposals: 0) == nil)
    }

    // MARK: - The question a vote proof names

    @Test func eachQuestionAVoteProofNamesIsTrackedOnItsOwn() {
        var tracker = VotingRoundProgressTracker()
        let step = castVote(bundleIndex: 0, proposalId: 1)

        tracker.record(step: step, proofProgress: 1.0, voteCommitProposalId: 1)
        tracker.record(step: step, proofProgress: 1.0, voteCommitProposalId: 2)
        tracker.record(step: step, proofProgress: 0.5, voteCommitProposalId: 3)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 2.5 / 37))
    }

    @Test func theQuestionAVoteProofNamesWinsOverTheSteps() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0, voteCommitProposalId: 9)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0, voteCommitProposalId: 10)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 2.0 / 37))
    }

    @Test func withoutAVoteProofTheStepsQuestionIsUsed() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 5), proofProgress: 0.5, voteCommitProposalId: nil)

        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 0.5 / 37))
    }

    @Test func anUnrecognisedStepCountsOnlyForTheQuestionAVoteProofNames() {
        var tracker = VotingRoundProgressTracker()
        let step = VotingRoundProgressTracker.Step.unrecognised(bundleIndex: 0)

        tracker.record(step: step, proofProgress: 1.0)
        #expect(tracker.fraction(completedProposals: 0, totalProposals: 37) == nil)

        tracker.record(step: step, proofProgress: 1.0, voteCommitProposalId: 3)
        #expect(isClose(tracker.fraction(completedProposals: 0, totalProposals: 37), 1.0 / 37))
    }

    // MARK: - The count

    @Test func theCountIsNilWhileTheTotalIsUnknown() {
        var tracker = VotingRoundProgressTracker()

        #expect(tracker.estimatedCompletedProposals(completedProposals: nil, totalProposals: nil) == nil)
        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: nil) == nil)
    }

    @Test func theCountIsNilWhileNothingIsMeasuredAndTheTallyIsZero() {
        var tracker = VotingRoundProgressTracker()

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == nil)
    }

    @Test func theCountShowsMeasuredQuestionsAheadOfTheTally() {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 2), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 2)
    }

    @Test func theCountNeverReachesTheTotalBeforeTheTallyDoes() {
        var tracker = VotingRoundProgressTracker()
        for proposalId in UInt32(1)...4 {
            tracker.record(step: castVote(bundleIndex: 0, proposalId: proposalId), proofProgress: 1.0)
        }

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 3)
    }

    @Test func theCountSnapsToTheTotalOnceTheTallyConfirmsIt() {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
        #expect(tracker.estimatedCompletedProposals(completedProposals: 4, totalProposals: 4) == 4)
    }

    @Test func theCountNeverGoesBackwards() throws {
        var tracker = VotingRoundProgressTracker()
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 2), proofProgress: 1.0)
        let rawHigh = tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4)
        let high = try #require(rawHigh)

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 3), proofProgress: 0)
        let rawNext = tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4)
        let next = try #require(rawNext)

        #expect(next >= high)
    }

    @Test func theCountFollowsTheTallyWhenTheTallyIsAhead() {
        var tracker = VotingRoundProgressTracker()

        #expect(tracker.estimatedCompletedProposals(completedProposals: 3, totalProposals: 4) == 3)
    }

    @Test func delegationAloneNeverMovesTheCount() throws {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 2) == nil)
        let rawFraction = tracker.fraction(completedProposals: 0, totalProposals: 2)
        let fraction = try #require(rawFraction)
        #expect(fraction > 0)
    }

    @Test func theCountMovesOnceAQuestionIsProvenBesideADelegatingBundle() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: delegate(bundleIndex: 0), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 1, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    // MARK: - The plan's vote-carrying bundles

    @Test func aQuestionEarnsPartialCreditUntilEveryCarryingBundleReports() {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: [0, 1])

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 2), proofProgress: 1.0)

        // Two questions at half credit are one question, not two.
        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    @Test func aQuestionCountsOnceEveryCarryingBundleHasProvenIt() {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: [0, 1])

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 1, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    @Test func aBundleThatFinishedAndLeftThePlanStillCounts() {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: [0, 1])
        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 1, proposalId: 1), proofProgress: 1.0)

        tracker.recordPlan(voteCarryingBundleIndexes: [1])

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    @Test func aBundleThePlanDroppedBeforeItCastNoLongerHoldsTheCountDown() {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: [0, 1])
        tracker.recordPlan(voteCarryingBundleIndexes: [0])

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    @Test func bundlesSeenReportingCountWithoutAPlan() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)
        tracker.record(step: castVote(bundleIndex: 1, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    @Test func aMissingOrEmptyPlanIsHarmless() {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: nil)
        tracker.recordPlan(voteCarryingBundleIndexes: [])

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 4) == 1)
    }

    @Test func manyBundlesAtDifferentPacesGiveAProportionalCount() throws {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: Array(UInt32(0)..<13))
        for proposalId in UInt32(1)...37 {
            tracker.record(step: castVote(bundleIndex: 0, proposalId: proposalId), proofProgress: 1.0)
        }

        let rawEstimate = tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 37)
        let estimate = try #require(rawEstimate)

        #expect((1...4).contains(estimate))
    }

    @Test func oneFullyProvenQuestionOfFortyOneIsNotRoundedAway() {
        var tracker = VotingRoundProgressTracker()

        tracker.record(step: castVote(bundleIndex: 0, proposalId: 1), proofProgress: 1.0)

        #expect(tracker.estimatedCompletedProposals(completedProposals: 0, totalProposals: 41) == 1)
    }

    @Test func theBarStaysLowWhileFewOfManyCarryingBundlesHaveFinished() throws {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: Array(UInt32(0)..<13))
        for proposalId in UInt32(1)...37 {
            tracker.record(step: castVote(bundleIndex: 0, proposalId: proposalId), proofProgress: 1.0)
            tracker.record(step: castVote(bundleIndex: 1, proposalId: proposalId), proofProgress: 1.0)
        }

        let rawFraction = tracker.fraction(completedProposals: 0, totalProposals: 37)
        let fraction = try #require(rawFraction)

        #expect(fraction < 0.3)
        #expect(fraction > 0)
    }

    @Test func theBarFillsOnceEveryCarryingBundleHasFinished() {
        var tracker = VotingRoundProgressTracker()
        tracker.recordPlan(voteCarryingBundleIndexes: [0, 1, 2])
        for proposalId in UInt32(1)...37 {
            for bundleIndex in UInt32(0)...2 {
                tracker.record(step: castVote(bundleIndex: bundleIndex, proposalId: proposalId), proofProgress: 1.0)
            }
        }

        #expect(isClose(tracker.fraction(completedProposals: 37, totalProposals: 37), 1))
    }

    // MARK: - Helpers

    private func castVote(bundleIndex: UInt32, proposalId: UInt32) -> VotingRoundProgressTracker.Step {
        VotingRoundProgressTracker.Step.proposal(bundleIndex: bundleIndex, proposalId: proposalId)
    }

    private func delegate(bundleIndex: UInt32) -> VotingRoundProgressTracker.Step {
        VotingRoundProgressTracker.Step.delegation(bundleIndex: bundleIndex)
    }

    private func isClose(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-9
    }
}
#endif
