//
//  SmartBannerResidualSlotTests.swift
//  zodlTests
//
//  MOB-1749 review fix: the residual banner is informational dust — it must never hold the
//  top-priority migration slot (that suppressed the wallet-backup and shielding banners
//  indefinitely, since the migration slot has no snooze). It seats only at the new BOTTOM rung and
//  any other claimant displaces it.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerResidualSlotTests {
    /// The dust the residual lane exists for — strictly between 0.0001 and 0.01 ZEC, sitting
    /// unlocked in Orchard on a wallet whose funds already live in Ironwood.
    private static let residual = MigrationBannerVariant.residual(amount: Zatoshi(800_000))

    /// A plain Zcash-vendor account. The ladder's entry rung refuses to walk without one, so every
    /// test that exercises the walk (rather than a single case) needs it installed.
    private static func walletAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 9, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Currency conversion (rung 8) claims the slot whenever it has not been set up, which would
    /// stop any walk before it reached the bottom. Answering "already configured" is what lets the
    /// ladder tests measure the rung they are actually about.
    private static func preferencesWithCurrencyConversionSetUp() -> UserPreferencesStorageClient {
        var preferences = UserPreferencesStorageClient()
        preferences.exchangeRate = { UserPreferencesStorage.ExchangeRate(manual: true, automatic: true) }
        return preferences
    }

    /// BULLET 1 — the fix itself. The pre-verdict CLAIM gate (R3) is the code that used to paint
    /// `.checkingStatus` and take `priorityMigration` for any non-nil variant, residual included;
    /// leaving the session verdict unknown arms it. A residual must walk straight past it: no
    /// checking flash (there is no run whose verdict could be pending), and no migration slot.
    @Test func residualNeverClaimsTheMigrationSlotNorPaintsChecking() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.isMigrationSessionVerdictKnown = { false }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(Self.residual))
            // No account is installed, so the walk this hands off to holds at its own entry gate —
            // which keeps this test on its own bullet. Where the walk goes when it CAN run is
            // `residualSeatsTheBottomRungOnceEveryRungAboveDeclines`.
            await store.receive(\.evaluatePriority1)

            #expect(store.state.priorityContent != .priorityMigration, "the residual took the slot that has no snooze")
            #expect(store.state.priorityContent == nil, "the residual claimed a slot instead of asking the ladder for one")
            #expect(store.state.migrationBannerVariant == Self.residual, "a residual has no verdict to wait on — it must never render Checking")
            #expect(!store.state.isMigrationCheckDwelling)
        }
    }

    /// BULLET 2 — the whole point of the demotion. Wallet backup (`priority6`) holds the slot; the
    /// residual is dust and must wait its turn rather than evict a banner the user actually needs.
    ///
    /// Exhaustive on purpose: the residual must not even REQUEST the slot here, and an unasserted
    /// `.triggerPriority` is what would prove it did.
    @Test func residualDoesNotDisplaceAHigherBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priority6

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.migrationManager = .noOp
                $0.sdkSynchronizer = .mocked()
            }

            // The answer is still RECORDED — the content is right the moment the slot frees up —
            // it simply does not claim anything.
            await store.send(.migrationVariantUpdated(Self.residual)) {
                $0.migrationBannerVariant = Self.residual
            }

            #expect(store.state.priorityContent == .priority6, "wallet backup lost its slot to informational dust")
        }
    }

    /// BULLET 3 — the arbiter, from the other side. A real run answer (`.required`) arriving while
    /// the residual is seated must take the slot back: `priorityMigration` (-1) outranks
    /// `priorityResidual` (11), so the rank guard in `.openBannerRequest` lets it through.
    @Test func aRunVariantDisplacesASeatedResidual() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // A seated, open residual is this test's PRECONDITION, not its subject — how a residual
            // comes to be seated is `residualSeatsTheBottomRungOnceEveryRungAboveDeclines`'s job —
            // so it is set directly rather than walked to.
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priorityResidual
            state.migrationBannerVariant = Self.residual
            state.isOpen = true

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.migrationManager = .noOp
                $0.sdkSynchronizer = .mocked()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(.required))
            // Seated and open, so the request bounces once off the open banner — close, then
            // re-request — before the slot changes hands.
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            await store.receive(\.closeBanner)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priorityMigration)
            #expect(store.state.migrationBannerVariant == .required)
        }
    }

    /// BULLET 4 (AS AMENDED) — the demotion is not a mute, and the ladder is the only way in.
    ///
    /// An empty slot is not an invitation: a residual arriving through the funnel re-runs the WALK
    /// rather than claiming, so every banner above gets its ask first. Here they all decline — no
    /// restore, no sync backlog, nothing to back up, nothing to shield, the Tor prompt answered,
    /// currency conversion configured — so the walk reaches the bottom rung and the dust seats
    /// there, which is the design's whole intent for it.
    @Test func residualSeatsTheBottomRungOnceEveryRungAboveDeclines() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.$selectedWalletAccount.withLock { $0 = Self.walletAccount() }

            // Bound here rather than read inside the dependency closure: that closure is
            // `@Sendable` and cannot reach a `@MainActor`-isolated static.
            let answer = Self.residual

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                // The walk asks the manager its own question on the migration rung, and gets the
                // same answer the funnel just heard — which is what the bottom rung cashes in.
                client.bannerVariant = { _ in answer }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked()
                // Rungs 6, 7 and 75 decline through `.noOp`: no transactions to warrant a backup
                // prompt, no transparent balance to shield, the Tor setup flag already answered.
                $0.walletStorage = .noOp
                $0.userStoredPreferences = Self.preferencesWithCurrencyConversionSetUp()
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(Self.residual))

            // The funnel hands off to the ladder instead of seating anything itself...
            await store.receive(\.evaluatePriority1)
            // ...and the walk ends at the new bottom rung.
            await store.receive(\.evaluatePriorityResidual)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priorityResidual)
            #expect(store.state.migrationBannerVariant == Self.residual)
        }
    }

    /// THE NARROWER DOOR the demotion nearly left open (review finding, ruled on as a spec change).
    ///
    /// A wallet that owes a backup seats `priority6`; a real sync starts and `priority4` displaces
    /// it; the sync completes, and the `.upToDate` arm for `priority4` closes the banner and feeds
    /// `bannerVariant` STRAIGHT into the funnel — bypassing the ladder. With the funnel allowed to
    /// claim an empty slot, dust took the slot the backup prompt had just been holding, and kept it
    /// for the session: the exact harm this task exists to prevent, reached by a different route.
    ///
    /// Written at the funnel rather than through a scripted sync, because the funnel is where the
    /// decision is made — an empty slot plus a residual answer, which is precisely the state the
    /// `.priority4` arm produces.
    @Test func aResidualArrivingOnAnEmptySlotStillYieldsToWalletBackup() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.$selectedWalletAccount.withLock { $0 = Self.walletAccount() }
            // The backup rung's own conditions: a Zcash account with history, a stored wallet whose
            // phrase has not been verified (`.noOp` answers `StoredWallet.placeholder`, which has
            // not), and no reminder on record — so it claims at phase 1.
            state.$transactions.withLock { $0 = [TransactionState.mockedReceived] }
            // The slot is EMPTY, exactly as the closing `.priority4` banner leaves it.
            let answer = Self.residual

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.bannerVariant = { _ in answer }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked()
                $0.walletStorage = .noOp
                $0.userStoredPreferences = Self.preferencesWithCurrencyConversionSetUp()
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(Self.residual))
            await store.receive(\.evaluatePriority1)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(
                store.state.priorityContent == .priority6,
                "dust took the slot the wallet-backup prompt was owed — the suppression this fix exists to end"
            )
            #expect(store.state.priorityContent != .priorityResidual)
        }
    }

    /// BULLET 5 — how the residual banner goes away. The dust gets locked (or spent) and the
    /// derivation answers nil; the release path has to recognise the residual seat as its own,
    /// or the banner would sit there forever with nothing behind it.
    @Test func nilVariantReleasesTheResidualSeat() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priorityResidual
            state.migrationBannerVariant = Self.residual
            state.isOpen = true
            // No account selected on purpose: the re-run ladder holds at its own account gate, so
            // this test measures the release and nothing downstream of it.

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.migrationManager = .noOp
                $0.sdkSynchronizer = .mocked()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(nil))
            await store.receive(\.closeBanner)

            #expect(store.state.priorityContent == nil, "the residual kept a slot it no longer has anything to say in")
            #expect(!store.state.isOpen)

            // The ladder re-runs, so whatever was suppressed while the dust held the slot gets its
            // turn immediately rather than waiting for the next sync edge.
            await store.receive(\.evaluatePriority1)
        }
    }

    /// BULLET 6 — the Checking flash belongs to migration, not to dust. `.migrationForegroundCheck
    /// Started` guards on `priorityContent == .priorityMigration`, and that guard must keep
    /// excluding the residual seat: there is no session verdict pending for a wallet whose only
    /// migration business is leftover change, so a spinner would be a lie.
    ///
    /// Exhaustive on purpose — the assertion is that NOTHING happens.
    @Test func foregroundCheckSkipsAResidualSeat() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priorityResidual
            state.migrationBannerVariant = Self.residual

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.migrationManager = .noOp
                $0.sdkSynchronizer = .mocked()
            }

            await store.send(.migrationForegroundCheckStarted)

            #expect(store.state.migrationBannerVariant == Self.residual)
            #expect(!store.state.isMigrationCheckDwelling)
            #expect(store.state.priorityContent == .priorityResidual)
        }
    }

    /// BULLET 7 — the tap still has to go somewhere. The residual banner's whole surface opens the
    /// migration flow, whose re-entry route lands on the Remaining Orchard Funds screen; demoting
    /// the rung must not quietly cut that door.
    @Test func tappingTheResidualBannerOpensTheMigrationFlow() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.priorityContent = .priorityResidual
            state.migrationBannerVariant = Self.residual

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.migrationManager = .noOp
                $0.walletStorage = .noOp
            }

            await store.send(.smartBannerContentTapped)
            await store.receive(\.migrationScreenRequested)
        }
    }

    /// BULLET 8 — the ladder half. The cold walk-down asks migration on its own rung; a residual
    /// answer there must NOT claim, it must keep walking (`evaluatePriority3`) so every banner
    /// above gets its chance. The new bottom rung is where the answer is finally cashed in: when
    /// the walk reaches `evaluatePriority9` and nothing has claimed, `evaluatePriorityResidual`
    /// seats it.
    @Test func theLadderWalksPastAResidualAndSeatsItOnlyAtTheBottom() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.migrationManager = .noOp
                $0.sdkSynchronizer = .mocked()
                $0.walletStorage = .noOp
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantLoaded(Self.residual))
            await store.receive(\.evaluatePriority3)

            #expect(store.state.priorityContent != .priorityMigration, "the walk-down handed dust the top-priority slot")
            #expect(store.state.priorityContent == nil, "the residual claimed a rung the walk had not reached yet")
            #expect(store.state.migrationBannerVariant == Self.residual, "the answer must still be recorded for the bottom rung to cash in")

            // The bottom of the ladder — every rung above declined, so the recorded residual is
            // what is left to show. (The walk above dead-ends at `evaluatePriority7`'s account
            // guard in this fixture, so the last rung is driven directly.)
            await store.send(.evaluatePriority9)
            await store.receive(\.evaluatePriorityResidual)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priorityResidual)

            // THE OTHER HALF OF THE SAME RUNG, and the reason it needs one: this rung claims from
            // the CACHED answer, not from a fresh question. So once the dust is gone — the seat
            // already released, the ladder's own question now answering nil — the cache has to be
            // retired in that same pass, or this walk would re-seat the banner its own nil just
            // declined, and every sync edge would flip it back and forth.
            await store.send(.closeBanner(true))
            await store.send(.migrationVariantLoaded(nil))
            await store.receive(\.evaluatePriority3)

            #expect(
                store.state.migrationBannerVariant != Self.residual,
                "the retirement must clear the cached residual answer — a kept answer would re-seat the banner from stale dust"
            )
        }
    }
}
