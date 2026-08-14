//
//  SmartBannerLadderReadinessTests.swift
//  zodlTests
//
//  THE LADDER MAY NOT WALK BEFORE IT CAN EVALUATE (MOB-1466, Lukas's ruling 2026-08-09).
//
//  THE FIELD REPORT, from almost everybody: at cold launch the Currency Conversion banner appears
//  first and the migration banner replaces it seconds — or a minute and a half — later. Lukas 2-3 s,
//  Andrea 30 s and 80 s. Backgrounding and foregrounding raises migration instantly.
//
//  THE MECHANISM. `selectedWalletAccount` is `@Shared(.inMemory(...))`, seeded nil, and populated
//  only when `.loadedWalletAccounts` selects an account. The ladder used to be kicked from
//  `.registerForSynchronizersUpdate`, which is NOT ordered after that load. So on a cold start:
//
//    .evaluatePriorityMigration → bannerVariant(nil) → the manager's own guard fires
//    ("no banner: no account selected") → nil → and a nil variant is a DECLINE, not a claim.
//
//  The walk then falls through to priority8 and currency conversion seats. The R3 claim gate cannot
//  save it either — that gate requires a non-nil variant — so the user does not even get
//  "Checking status…". Nothing re-runs the ladder when the account finally lands, because
//  `.walletAccountChanged` is sent only from `accountSwitchedEffect`: a SWITCH signal, not a LOADED
//  one. Recovery therefore waits for whatever generic trigger comes first — the sync-completion
//  transition (the 30 s / 80 s reports) or a foreground reconcile (the instant bg→fg "fix").
//
//  LUKAS'S RULING, verbatim: "banner logic must wait on a moment when it's possible to evaluate
//  it's priorities.. it's a bug to ask migration without accounts being loaded … it's better to
//  prolong time before any banner is rendered.. I kinda smell that we run it so Currency Conversion
//  wins the race but a moment later, we finaly re-evaluate banner when migration is known..
//  therefore CC is first but replaced.. that's wrong... simply wait for the right moment".
//
//  WHY GATING THE ONE KICK IS ENOUGH. The ladder is ORDERED — priority1 → priority2 →
//  priorityMigration → priority3 … → priority8. Migration is asked before currency conversion by
//  construction. So there is no need to teach the other banners to wait for migration: hold the
//  single entry until priorities are evaluable, and the ordering does the rest. One rule, one gate.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerLadderReadinessTests {
    private static func walletAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 7, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// THE REGRESSION ITSELF. No account selected yet — the ladder must not ask the migration
    /// question at all, because the only answer available is the manager's "no account" nil, and
    /// that nil is indistinguishable from "this wallet has nothing to migrate". Asking is what
    /// hands the slot to currency conversion.
    @Test func theLadderDoesNotAskMigrationBeforeAnAccountIsKnown() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            // Deliberately NOT setting `selectedWalletAccount`: nil is the cold-launch value.

            let asks = LockIsolated(0)
            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in
                    asks.withValue { $0 += 1 }
                    return nil
                }
                $0.migrationManager = client
                // The rungs BELOW migration are not what these tests are about; give them enough to
                // run so the only recorded issue can be the assertion itself.
                $0.walletStorage = .noOp
                $0.sdkSynchronizer = .mocked()
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.evaluatePriority1)

            #expect(asks.value == 0, "the ladder asked migration with no account — the blind question that seats currency conversion")
            #expect(state.priorityContent == nil)
        }
    }

    /// The gate is a WAIT, not a refusal: once the account is known the ladder walks exactly as it
    /// always did and the migration question is asked. Without this the fix would be a silent mute.
    @Test func theLadderWalksOnceAnAccountIsKnown() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.$selectedWalletAccount.withLock { $0 = Self.walletAccount() }

            let asks = LockIsolated(0)
            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in
                    asks.withValue { $0 += 1 }
                    return nil
                }
                $0.migrationManager = client
                // The rungs BELOW migration are not what these tests are about; give them enough to
                // run so the only recorded issue can be the assertion itself.
                $0.walletStorage = .noOp
                $0.sdkSynchronizer = .mocked()
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.evaluatePriority1)

            #expect(asks.value >= 1, "with an account known the ladder must ask migration as it always did")
        }
    }
}
