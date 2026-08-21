//
//  MigrationResidualDerivationTests.swift
//  zodlTests
//
//  MOB-1749: the residual arms of the two pure tables. The residual is the LOWEST-priority answer:
//  it appears only where the tables used to answer nil / .entry, so every row here either pins a
//  bound (0.0001 exclusive, 0.01 exclusive, Ironwood > 0) or pins that an existing answer still wins.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationResidualBannerDerivationTests {
    private static let ironwood = Zatoshi(1_245_000_000)

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
            ironwoodBalance: ironwood,
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

    @Test func theSplitPhaseIsUntouched() {
        let variant = Self.banner(state: .splitPendingConfirmation, orchard: Zatoshi(800_000))

        #expect(variant != .residual(amount: Zatoshi(800_000)))
    }
}

@Suite struct MigrationResidualRouteDerivationTests {
    private static let ironwood = Zatoshi(1_245_000_000)

    private static func route(
        state: MigrationState = .notStarted,
        orchard: Zatoshi,
        ironwood: Zatoshi = ironwood,
        isCompleteAcknowledged: Bool = false,
        isIronwoodActivated: Bool = true
    ) -> MigrationReentryRoute {
        MigrationDerivations.reentryRoute(
            isIronwoodActivated: isIronwoodActivated,
            state: state,
            advanceStep: nil,
            hasInvalid: false,
            hasOverdue: false,
            isCompleteAcknowledged: isCompleteAcknowledged,
            progress: nil,
            orchardBalance: orchard,
            ironwoodBalance: ironwood
        )
    }

    @Test func aResidualOnAFreshWalletRoutesToTheResidualScreen() {
        #expect(Self.route(orchard: Zatoshi(800_000)) == .residual)
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
        #expect(Self.route(state: .complete, orchard: Zatoshi(800_000), isCompleteAcknowledged: true) == .residual)
    }

    @Test func anAcknowledgedCompletionWithoutAResidualRoutesToTheFork() {
        #expect(Self.route(state: .complete, orchard: .zero, isCompleteAcknowledged: true) == .entry)
    }

    @Test func theDefaultedInputsNeverProduceAResidual() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: .notStarted,
            advanceStep: nil,
            hasInvalid: false,
            hasOverdue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == .entry)
    }
}
