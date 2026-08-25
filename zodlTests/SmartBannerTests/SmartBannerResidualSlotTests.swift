//
//  SmartBannerResidualSlotTests.swift
//  zodlTests
//
//  MOB-1749: the residual banner never holds the top-priority migration slot itself (no snooze,
//  no session verdict — it bypasses the checkingStatus machinery entirely). Re-ranked 2026-08-25
//  (approved): it seats at rank 1.75, DIRECTLY BELOW the migration slot — only connectivity and
//  sync-error alerts and a real migration outrank it; the informational rungs (backup, shielding,
//  Tor, currency conversion) rank below it. The suppression trade-off was accepted knowingly —
//  at the old bottom rank a dust wallet could wait behind currency conversion forever.
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

    /// REVERSED 2026-08-25 (approved): the residual now ranks 1.75 — directly below the migration
    /// slot — so a residual answer arriving while wallet backup (`priority6`) holds the slot
    /// re-runs the ladder and takes it. The suppression trade-off was accepted knowingly: the
    /// residual is actionable and self-retiring, and at rank 11 a dust wallet could wait forever
    /// behind currency conversion (the field report that triggered the reversal).
    @Test func residualDisplacesTheInformationalBannersBelowIt() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.$selectedWalletAccount.withLock { $0 = Self.walletAccount() }
            state.priorityContent = .priority6

            let answer = Self.residual

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.bannerVariant = { _ in answer }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(Self.residual))
            await store.receive(\.evaluatePriority1)
            await store.receive(\.evaluatePriorityResidual)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priorityResidual, "at rank 1.75 the residual outranks the wallet-backup seat")
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

    /// BULLET 4 (AS RE-AMENDED 2026-08-25) — the ladder is still the only way in: a residual
    /// arriving through the funnel re-runs the WALK rather than claiming. The walk asks the rungs
    /// above the migration slot (connectivity, sync error), then the migration rung itself — and a
    /// `.residual` answer there goes straight to its seat one rank below, never continuing down to
    /// the informational rungs.
    @Test func residualSeatsDirectlyBelowTheMigrationRung() async {
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
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(Self.residual))

            // The funnel hands off to the ladder instead of seating anything itself...
            await store.receive(\.evaluatePriority1)
            // ...and the migration rung hands the residual straight to its seat, one rank below —
            // the walk never continues down to the informational rungs.
            await store.receive(\.evaluatePriorityResidual)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priorityResidual)
            #expect(store.state.migrationBannerVariant == Self.residual)
        }
    }

    /// Wave 2 — the rung-7 dead-end. A wallet holding an above-threshold transparent balance whose
    /// owner tapped "Remind me later" used to END the walk inside the shielding rung: the
    /// snooze-not-elapsed branch sent nothing, so the rungs below (Tor, currency conversion) were
    /// unreachable until the snooze elapsed. Re-anchored 2026-08-25: the residual no longer sits
    /// below rung 7 (it seats off the migration rung), so the `else` is pinned through Tor —
    /// entering at the transactions-change rung, the same mid-ladder door production uses.
    @Test func aSnoozedShieldingReminderStillYieldsTheWalkToTor() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.$selectedWalletAccount.withLock { $0 = Self.walletAccount() }

            let accountUUID = Self.walletAccount().id
            let snoozedYesterday = ReminedMeTimestamp(timestamp: Date().timeIntervalSince1970 - 3_600, occurence: 1)
            let aboveThreshold = AccountBalance(
                saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
                orchardBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
                ironwoodBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
                unshielded: Zatoshi(100_000_000),
                awaitingResolution: .zero
            )

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.migrationManager = .noOp
                $0.sdkSynchronizer = .mocked(
                    getAccountsBalances: { [accountUUID: aboveThreshold] }
                )
                var storage = WalletStorageClient.noOp
                storage.exportShieldingReminder = { _ in snoozedYesterday }
                storage.exportTorSetupFlag = { nil }
                $0.walletStorage = storage
                $0.continuousClock = ImmediateClock()
            }
            store.exhaustivity = .off

            await store.send(.evaluatePriority6)
            await store.receive(\.evaluatePriority75)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priority75, "the snoozed shielding rung ended the walk instead of passing it down")
        }
    }

    /// REVERSED 2026-08-25 (approved): at rank 1.75 the residual outranks wallet backup, and the
    /// walk order agrees — the migration rung sits above rung 6, so a residual answer seats before
    /// the backup rung is ever asked. Same backup-owed fixture as the original test, opposite
    /// expectation, so the reversal is pinned rather than implied.
    @Test func aResidualArrivingOnAnEmptySlotOutranksWalletBackup() async {
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
            await store.receive(\.evaluatePriorityResidual)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(
                store.state.priorityContent == .priorityResidual,
                "the migration rung sits above the backup rung — a residual answer seats before backup is asked"
            )
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
    @Test func theMigrationRungHandsAResidualStraightToItsSeat() async {
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
            // 2026-08-25: the seat sits directly below the migration slot now — the rung's answer
            // goes straight there instead of walking down past every informational banner.
            await store.receive(\.evaluatePriorityResidual)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent != .priorityMigration, "the walk-down handed dust the top-priority slot")
            #expect(store.state.priorityContent == .priorityResidual)
            #expect(store.state.migrationBannerVariant == Self.residual)

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
