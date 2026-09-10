//
//  LiveValueConstructionLockTests.swift
//  zodlTests
//
//  #2113 — a dependency's live implementation must be constructible while another thread holds a
//  swift-sharing reference lock.
//
//  swift-dependencies builds `liveValue` under its dependency-cache lock; `Shared.withLock` reads a
//  dependency (`sharedChangeTracker`) while holding the reference lock. A stored `@Shared` on a
//  class that `liveValue` creates retains that reference INSIDE the build — so the moment a store
//  sits in `$walletAccounts.withLock` on another thread, the two lock orders cross and both threads
//  wait forever. That is the cold-launch freeze behind the "hi" splash: `.loadedWalletAccounts`
//  spawns both the smart-banner ladder (which resolves `migrationManager` cold, on the cooperative
//  pool) and the private-UA stash refill (which writes through `$walletAccounts.withLock` on main).
//
//  The property is pinned directly, without the library's cache lock: the reference locks are held
//  on a plain thread, construction runs on a child task that shares this test's dependency context
//  (swift-dependencies keys its cache by the current swift-testing test, so a GCD thread would
//  resolve a DIFFERENT `PersistentReferences` and prove nothing), and construction must finish.
//  With a stored `@Shared` the constructor blocks in `_PersistentReference.retain()` until the
//  timeout. The last test pins that the on-demand accessors still read the live shared value.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct LiveValueConstructionLockTests {
    @Test func migrationManagerConstructsWhileAccountReferencesAreLocked() async {
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        nonisolated(unsafe) let accounts = $walletAccounts
        nonisolated(unsafe) let selected = $selectedWalletAccount

        let finished = await Self.constructionFinishes(
            whileHolding: { body in
                accounts.withLock { _ in
                    selected.withLock { _ in body() }
                }
            },
            construct: { _ = Self.migrationManager() }
        )

        #expect(finished, "MigrationManagerImpl.init must not take a shared-state reference lock")
    }

    @Test func shieldingProcessorConstructsWhileSelectedAccountIsLocked() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        nonisolated(unsafe) let selected = $selectedWalletAccount

        let finished = await Self.constructionFinishes(
            whileHolding: { body in selected.withLock { _ in body() } },
            construct: { _ = ShieldingProcessorClient.live() }
        )

        #expect(finished, "ShieldingProcessorClient.live() must not take a shared-state reference lock")
    }

    @Test func onDemandAccessorsReadTheLiveSharedValue() {
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        let manager = Self.migrationManager()
        let account = Self.walletAccount(idByte: 7)

        $walletAccounts.withLock { $0 = [account] }
        $selectedWalletAccount.withLock { $0 = account }

        #expect(manager.walletAccounts == [account])
        #expect(manager.selectedWalletAccount == account)
    }

    // MARK: - Helpers

    /// Holds whatever `hold` locks on a plain thread, then runs `construct` on a child task (which
    /// inherits this test's dependency context) and reports whether it finished within `timeout`.
    /// The locks are released as soon as the race is decided, so a constructor that did block is
    /// freed rather than leaked.
    private static func constructionFinishes(
        whileHolding hold: @escaping @Sendable (_ body: () -> Void) -> Void,
        construct: @escaping @Sendable () -> Void,
        timeout: Swift.Duration = .seconds(5)
    ) async -> Bool {
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (locked: CheckedContinuation<Void, Never>) in
            Thread {
                hold {
                    locked.resume()
                    release.wait()
                }
            }.start()
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                construct()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let finished = await group.next() ?? false
            release.signal()
            group.cancelAll()
            return finished
        }
    }

    /// Scoped storage, so constructing the manager never touches `UserDefaults.standard`.
    private static func migrationManager() -> MigrationManagerImpl {
        let suiteName = "LiveValueConstructionLockTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return MigrationManagerImpl(
            gateStorage: MigrationGateStorage(userDefaults: userDefaults),
            scheduleStorage: MigrationScheduleStorage(userDefaults: userDefaults),
            snapshotStorage: MigrationSnapshotStorage(userDefaults: userDefaults),
            failureRoutingStorage: MigrationFailureRoutingStorage(userDefaults: userDefaults)
        )
    }

    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }
}
