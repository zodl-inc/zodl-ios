import Testing
@testable import zodl_internal

@Suite struct WalletDatabaseSeedReconcileTests {
    @Test func relevantSeedSkipsHealAndReturnsFalse() async throws {
        let recorder = CallRecorder()
        let healed = try await Root.reconcileWalletDatabaseWithSeed(
            knownStale: false,
            seedBytes: [1, 2, 3],
            isSeedRelevant: { _ in
                await recorder.record("isSeedRelevant")
                return true
            },
            hasSeedDerivedAccount: {
                await recorder.record("hasSeedDerivedAccount")
                return true
            },
            clearDeviceScopedState: { await recorder.record("clear") },
            wipe: { await recorder.record("wipe") },
            reprepare: { await recorder.record("reprepare") }
        )
        #expect(healed == false)
        let calls = await recorder.calls
        #expect(calls == ["isSeedRelevant"], "nothing but the relevance probe may run when the seed is already relevant")
    }

    @Test func irrelevantSeedWithDerivedAccountClearsWipesRepreparesAndReturnsTrue() async throws {
        let recorder = CallRecorder()
        let healed = try await Root.reconcileWalletDatabaseWithSeed(
            knownStale: false,
            seedBytes: [1, 2, 3],
            isSeedRelevant: { _ in
                await recorder.record("isSeedRelevant")
                return false
            },
            hasSeedDerivedAccount: {
                await recorder.record("hasSeedDerivedAccount")
                return true
            },
            clearDeviceScopedState: { await recorder.record("clear") },
            wipe: { await recorder.record("wipe") },
            reprepare: { await recorder.record("reprepare") }
        )
        #expect(healed == true)
        let calls = await recorder.calls
        #expect(
            calls == ["isSeedRelevant", "hasSeedDerivedAccount", "clear", "wipe", "reprepare"],
            "device-scoped state must be cleared, then the database wiped, then re-prepared, in that order"
        )
    }

    @Test func knownStaleSkipsRelevanceAndDerivationChecksButStillHeals() async throws {
        let recorder = CallRecorder()
        let healed = try await Root.reconcileWalletDatabaseWithSeed(
            knownStale: true,
            seedBytes: [1, 2, 3],
            isSeedRelevant: { _ in
                await recorder.record("isSeedRelevant")
                return true
            },
            hasSeedDerivedAccount: {
                await recorder.record("hasSeedDerivedAccount")
                return false
            },
            clearDeviceScopedState: { await recorder.record("clear") },
            wipe: { await recorder.record("wipe") },
            reprepare: { await recorder.record("reprepare") }
        )
        #expect(healed == true)
        let calls = await recorder.calls
        #expect(
            calls == ["clear", "wipe", "reprepare"],
            "a database already known to be stale must heal unconditionally, without probing relevance or derivation"
        )
    }

    @Test func isSeedRelevantFailureRethrowsAndNeverHeals() async {
        let recorder = CallRecorder()
        await #expect(throws: ReconcileTestError.boom) {
            try await Root.reconcileWalletDatabaseWithSeed(
                knownStale: false,
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in throw ReconcileTestError.boom },
                hasSeedDerivedAccount: {
                    await recorder.record("hasSeedDerivedAccount")
                    return true
                },
                clearDeviceScopedState: { await recorder.record("clear") },
                wipe: { await recorder.record("wipe") },
                reprepare: { await recorder.record("reprepare") }
            )
        }
        let calls = await recorder.calls
        #expect(calls.isEmpty, "An indeterminate isSeedRelevant answer must never trigger a heal")
    }

    @Test func viewOnlyDatabaseThrowsAndNeverHeals() async throws {
        let recorder = CallRecorder()
        do {
            _ = try await Root.reconcileWalletDatabaseWithSeed(
                knownStale: false,
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in false },
                hasSeedDerivedAccount: { false },
                clearDeviceScopedState: { await recorder.record("clear") },
                wipe: { await recorder.record("wipe") },
                reprepare: { await recorder.record("reprepare") }
            )
            Issue.record("Expected reconcileWalletDatabaseWithSeed to throw viewOnlyDatabase")
        } catch Root.WalletDatabaseHealError.viewOnlyDatabase {
            // Expected: a database with no seed-derived account must never be wiped.
        } catch {
            Issue.record("Expected WalletDatabaseHealError.viewOnlyDatabase, got \(error)")
        }
        let calls = await recorder.calls
        #expect(calls.isEmpty, "A database with no seed-derived account must never be wiped")
    }

    @Test func hasSeedDerivedAccountFailureRethrowsAndNeverHeals() async {
        let recorder = CallRecorder()
        await #expect(throws: ReconcileTestError.boom) {
            try await Root.reconcileWalletDatabaseWithSeed(
                knownStale: false,
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in false },
                hasSeedDerivedAccount: { throw ReconcileTestError.boom },
                clearDeviceScopedState: { await recorder.record("clear") },
                wipe: { await recorder.record("wipe") },
                reprepare: { await recorder.record("reprepare") }
            )
        }
        let calls = await recorder.calls
        #expect(calls.isEmpty, "An indeterminate hasSeedDerivedAccount answer must never trigger a heal")
    }

    @Test func wipeFailureRethrowsAndNeverReprepares() async {
        let recorder = CallRecorder()
        await #expect(throws: ReconcileTestError.boom) {
            try await Root.reconcileWalletDatabaseWithSeed(
                knownStale: false,
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in false },
                hasSeedDerivedAccount: { true },
                clearDeviceScopedState: { },
                wipe: { throw ReconcileTestError.boom },
                reprepare: { await recorder.record("reprepare") }
            )
        }
        let calls = await recorder.calls
        #expect(calls.isEmpty, "reprepare must never run when wipe throws")
    }

    @Test func reprepareFailureRethrowsWrapped() async throws {
        do {
            _ = try await Root.reconcileWalletDatabaseWithSeed(
                knownStale: false,
                seedBytes: [1, 2, 3],
                isSeedRelevant: { _ in false },
                hasSeedDerivedAccount: { true },
                clearDeviceScopedState: { },
                wipe: { },
                reprepare: { throw ReconcileTestError.boom }
            )
            Issue.record("Expected reconcileWalletDatabaseWithSeed to throw reprepareFailed")
        } catch Root.WalletDatabaseHealError.reprepareFailed(let underlying) {
            #expect(underlying as? ReconcileTestError == ReconcileTestError.boom)
        } catch {
            Issue.record("Expected WalletDatabaseHealError.reprepareFailed, got \(error)")
        }
    }
}

private enum ReconcileTestError: Error, Equatable {
    case boom
}

private actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}
