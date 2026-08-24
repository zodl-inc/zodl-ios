//
//  MigrationResidualDerivationTests.swift
//  zodlTests
//
//  MOB-1749: the residual arms of the two pure tables. The residual is the LOWEST-priority answer:
//  it appears only where the tables used to answer nil / .entry, so every row here either pins a
//  bound (0.0001 exclusive, 0.01 exclusive, Ironwood > 0) or pins that an existing answer still wins.
//
//  Review fix (2026-08-24): the residual figures ride `MigrationResidualBalances` — one value
//  carrying the spendable Orchard residual, the locked Orchard balance and the Ironwood total —
//  rather than a pair of loose Zatoshi parameters, and the route CARRIES that payload so the screen
//  renders the very figures the decision was made on. `nil` is a real input here: an unreadable
//  balances read is not an empty wallet, and both tables must degrade rather than invent a zero.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationResidualBannerDerivationTests {
    private static let ironwood = Zatoshi(1_245_000_000)

    /// `unlocked` defaults to `orchard` — the ordinary wallet, where nothing is pending and the
    /// two bases coincide, so every band test below keeps reading as one number. Pass it
    /// explicitly only to pull the offer basis away from the spendable one.
    private static func residual(
        orchard: Zatoshi,
        unlocked: Zatoshi? = nil,
        locked: Zatoshi = .zero,
        ironwood: Zatoshi = ironwood
    ) -> MigrationResidualBalances {
        MigrationResidualBalances(
            residualOrchard: orchard,
            unlockedOrchard: unlocked ?? orchard,
            lockedOrchard: locked,
            ironwood: ironwood
        )
    }

    private static func banner(
        state: MigrationState = .notStarted,
        orchard: Zatoshi,
        ironwood: Zatoshi = ironwood,
        isCompleteAcknowledged: Bool = false,
        isMigrationRemainderPending: Bool = false,
        isIronwoodActivated: Bool = true
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: isIronwoodActivated,
            state: state,
            orchardBalance: orchard,
            residual: residual(orchard: orchard, ironwood: ironwood),
            isCompleteAcknowledged: isCompleteAcknowledged,
            isMigrationRemainderPending: isMigrationRemainderPending,
            transferRows: []
        )
    }

    // MARK: - Bounds

    @Test func theResidualFloorItselfShowsNothing() {
        #expect(Self.banner(orchard: Zatoshi(10_000)) == nil)
    }

    @Test func oneZatoshiAboveTheResidualFloorIsResidual() {
        #expect(Self.banner(orchard: Zatoshi(10_001)) == .residual(amount: Zatoshi(10_001)))
    }

    @Test func justBelowTheOfferFloorIsResidual() {
        #expect(Self.banner(orchard: Zatoshi(999_999)) == .residual(amount: Zatoshi(999_999)))
    }

    @Test func theOfferFloorIsStillTheOffer() {
        #expect(Self.banner(orchard: Zatoshi(1_000_000)) == .required)
    }

    @Test func nothingInOrchardShowsNothing() {
        #expect(Self.banner(orchard: .zero) == nil)
    }

    // MARK: - Gates

    @Test func nothingInIronwoodShowsNothing() {
        #expect(Self.banner(orchard: Zatoshi(800_000), ironwood: .zero) == nil)
    }

    @Test func preActivationShowsNothing() {
        #expect(Self.banner(orchard: Zatoshi(800_000), isIronwoodActivated: false) == nil)
    }

    // MARK: - Precedence

    @Test func anUnacknowledgedCompletionOutranksTheResidual() {
        #expect(Self.banner(state: .complete, orchard: Zatoshi(800_000)) == .complete)
    }

    @Test func aPendingRemainderOutranksTheResidual() {
        let variant = Self.banner(
            state: .complete,
            orchard: Zatoshi(800_000),
            isCompleteAcknowledged: true,
            isMigrationRemainderPending: true
        )

        #expect(variant == .nextRoundRequired(round: 1, totalRounds: nil))
    }

    @Test func anAcknowledgedCompletionWithNothingToPlanShowsTheResidual() {
        let variant = Self.banner(state: .complete, orchard: Zatoshi(800_000), isCompleteAcknowledged: true)

        #expect(variant == .residual(amount: Zatoshi(800_000)))
    }

    @Test func anAcknowledgedCompletionWithNoResidualStaysQuiet() {
        #expect(Self.banner(state: .complete, orchard: .zero, isCompleteAcknowledged: true) == nil)
    }

    /// The split phase keeps its OWN answer — a committed run reads as progress, whatever dust the
    /// Orchard balance happens to still hold. Pinned as the exact variant rather than "not the
    /// residual": with no rows and nothing in flight the arm answers the run-level readout with
    /// zero counts and no round labels, and an `!=` would go on passing if that arm started
    /// answering something else entirely.
    @Test func theSplitPhaseIsUntouched() {
        let variant = Self.banner(state: .splitPendingConfirmation, orchard: Zatoshi(800_000))

        #expect(variant == .inProgress(done: 0, total: 0, round: nil, totalRounds: nil))
    }

    /// MOB-1749 review fix: the two lanes read DIFFERENT bases — the OFFER is sized from
    /// `unlockedForMigration` (spendable plus both pending buckets), the residual from spendable
    /// alone. A pending-heavy wallet therefore sits in the residual band on one basis and above the
    /// offer floor on the other, and before the fix the banner said "Migration Required" while the
    /// route opened the Remaining Orchard Funds screen. `isResidualCandidate`'s upper bound now
    /// rides the offer's own figure precisely so the two can never split. Twin in the route suite.
    @Test func aPendingHeavyBalanceAboveTheOfferFloorIsTheOfferNotTheResidual() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .notStarted,
            orchardBalance: Zatoshi(1_300_000),
            residual: Self.residual(orchard: Zatoshi(800_000), unlocked: Zatoshi(1_300_000)),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: []
        )

        #expect(variant == .required)
    }

    /// An unreadable balances read is NOT an empty wallet — the arms must stay quiet rather than
    /// invent a zero.
    @Test func anUnreadableBalanceReadShowsNothing() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .notStarted,
            orchardBalance: Zatoshi(800_000),
            residual: nil,
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: []
        )

        #expect(variant == nil)
    }
}

@Suite struct MigrationResidualRouteDerivationTests {
    private static let ironwood = Zatoshi(1_245_000_000)

    /// `unlocked` defaults to `orchard` — see the banner suite's twin.
    private static func residual(
        orchard: Zatoshi,
        unlocked: Zatoshi? = nil,
        ironwood: Zatoshi = ironwood
    ) -> MigrationResidualBalances {
        MigrationResidualBalances(
            residualOrchard: orchard,
            unlockedOrchard: unlocked ?? orchard,
            lockedOrchard: .zero,
            ironwood: ironwood
        )
    }

    private static func route(
        state: MigrationState = .notStarted,
        orchard: Zatoshi,
        ironwood: Zatoshi = ironwood,
        isCompleteAcknowledged: Bool = false,
        isMigrationRemainderPending: Bool = false,
        isIronwoodActivated: Bool = true
    ) -> MigrationReentryRoute {
        MigrationDerivations.reentryRoute(
            isIronwoodActivated: isIronwoodActivated,
            state: state,
            advanceStep: nil,
            hasInvalid: false,
            hasOverdue: false,
            isCompleteAcknowledged: isCompleteAcknowledged,
            isMigrationRemainderPending: isMigrationRemainderPending,
            progress: nil,
            residual: residual(orchard: orchard, ironwood: ironwood)
        )
    }

    @Test func aResidualOnAFreshWalletRoutesToTheResidualScreen() {
        #expect(Self.route(orchard: Zatoshi(800_000)) == .residual(Self.residual(orchard: Zatoshi(800_000))))
    }

    @Test func anOfferableBalanceStillRoutesToTheFork() {
        #expect(Self.route(orchard: Zatoshi(1_000_000)) == .entry)
    }

    @Test func theResidualFloorItselfRoutesToTheFork() {
        #expect(Self.route(orchard: Zatoshi(10_000)) == .entry)
    }

    @Test func nothingInIronwoodRoutesToTheFork() {
        #expect(Self.route(orchard: Zatoshi(800_000), ironwood: .zero) == .entry)
    }

    @Test func preActivationRoutesToTheFork() {
        #expect(Self.route(orchard: Zatoshi(800_000), isIronwoodActivated: false) == .entry)
    }

    @Test func anUnacknowledgedCompletionOutranksTheResidual() {
        #expect(Self.route(state: .complete, orchard: Zatoshi(800_000)) == .complete)
    }

    @Test func anAcknowledgedCompletionWithAResidualRoutesToTheResidualScreen() {
        let route = Self.route(state: .complete, orchard: Zatoshi(800_000), isCompleteAcknowledged: true)

        #expect(route == .residual(Self.residual(orchard: Zatoshi(800_000))))
    }

    @Test func anAcknowledgedCompletionWithoutAResidualRoutesToTheFork() {
        #expect(Self.route(state: .complete, orchard: .zero, isCompleteAcknowledged: true) == .entry)
    }

    /// MOB-1749 review fix: the flag the banner's matching arm consults FIRST. A pending remainder
    /// means the banner reads "Migration Required / next round" — the tap must open the fork that
    /// starts it, exactly as it did before the residual lane existed.
    @Test func aPendingRemainderOutranksTheResidual() {
        let route = Self.route(
            state: .complete,
            orchard: Zatoshi(800_000),
            isCompleteAcknowledged: true,
            isMigrationRemainderPending: true
        )

        #expect(route == .entry)
    }

    /// MOB-1749 review fix: the route twin of the banner suite's test of the same name — the same
    /// pending-heavy wallet, the same struct, and the answer that must match it: the fork, because
    /// the offer lane is the one that fires.
    @Test func aPendingHeavyBalanceAboveTheOfferFloorIsTheOfferNotTheResidual() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: .notStarted,
            advanceStep: nil,
            hasInvalid: false,
            hasOverdue: false,
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            progress: nil,
            residual: Self.residual(orchard: Zatoshi(800_000), unlocked: Zatoshi(1_300_000))
        )

        #expect(route == .entry)
    }

    /// An unreadable balances read degrades to the fork deliberately (and the live route traces
    /// it) — the arms must never mistake it for a residual.
    @Test func anUnreadableBalanceReadRoutesToTheFork() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: .notStarted,
            advanceStep: nil,
            hasInvalid: false,
            hasOverdue: false,
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            progress: nil,
            residual: nil
        )

        #expect(route == .entry)
    }
}
