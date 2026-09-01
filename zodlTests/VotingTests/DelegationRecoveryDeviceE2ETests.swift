#if VOTING_ENABLED
@preconcurrency import Combine
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// Whether the end-to-end run is active, kept OUTSIDE the suite type.
///
/// A `@Suite(.enabled(if:))` condition cannot reach into the type its macro is
/// attached to: expanding the macro would require the type the expansion
/// defines.
///
/// The gate is a MARKER FILE planted next to the fixture, not an environment
/// variable. `xcodebuild`'s `TEST_RUNNER_` passthrough does not reach a hosted
/// unit test under `test-without-building`, which made every test here skip
/// while the run still reported success. The marker travels with the fixture
/// through the same copy, so the gate cannot disagree with the data.
///
/// Once the marker is present every precondition below is ASSERTED rather than
/// skipped: an end-to-end test that quietly passes because nobody planted its
/// fixture is worse than no test at all.
enum RecoveryDeviceE2E {
    /// Written by `Scripts/e2e/run-delegation-recovery-e2e.sh`.
    static let markerName = ".e2e-marker"

    static var isEnabled: Bool {
        guard let documents else { return false }
        return FileManager.default.fileExists(
            atPath: documents
                .appendingPathComponent("voting_recovery", isDirectory: true)
                .appendingPathComponent(markerName)
                .path
        )
    }

    static var documents: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
    }
}

/// Recovery driven THROUGH APP LAUNCH against a corrupted database planted in
/// the app's own container, exactly as
/// `Scripts/e2e/run-delegation-recovery-e2e.sh` plants it.
///
/// This is the whole path end to end and in the real order: the preserved
/// files as a device would hold them, `Root` receiving the launch action the
/// app delegate sends, the real `DelegationRecoveryClient` and the real
/// file-backed escrow underneath it, and an assertion that the secrets the
/// user actually broadcast are on disk afterwards.
///
/// Driving `.didFinishLaunching` rather than calling `run()` is the point.
/// Everything below the client is already covered by the in-process suites;
/// what nothing else can prove on a device is that OPENING THE APP is what
/// sets it going, with no screen and nothing to tap. A regression that
/// unhooked recovery from launch would leave every other test green.
@Suite(.serialized, .enabled(if: RecoveryDeviceE2E.isEnabled)) @MainActor
struct DelegationRecoveryDeviceE2ETests {
    enum Expected {
        static let roundId = String(repeating: "4a", count: 32)
        static let bundleCount = 3

        /// Generation 0: what the user broadcast, recoverable only from the log.
        static let originalVanCommRand = [
            String(repeating: "a0", count: 31) + "00",
            String(repeating: "a1", count: 31) + "01",
            String(repeating: "a2", count: 31) + "02"
        ]

        /// Generation 1: what the rebuild put in their place. Recovery must
        /// never hand one of these back as an original.
        static let rebuiltVanCommRand = [
            String(repeating: "a0", count: 31) + "08",
            String(repeating: "a1", count: 31) + "09",
            String(repeating: "a2", count: 31) + "0a"
        ]
    }


    /// Runs the real recovery against the real escrow.
    ///
    /// `DelegationRecoveryClient.liveValue` resolves `@Dependency(\.delegationEscrow)`
    /// at call time, and inside a test process that resolves to `testValue`,
    /// whose `record` is unimplemented. Without this override the carver finds
    /// the bundles and then throws on every write, which reads as a recovery
    /// failure when the carver was in fact fine. The end-to-end run wants the
    /// live escrow precisely because the file it writes is the deliverable.
    /// Sends the launch action `AppDelegate` sends, with the REAL recovery
    /// client and the REAL escrow underneath.
    ///
    /// `delegationEscrow` must be overridden to `.liveValue` explicitly.
    /// `DelegationRecoveryClient.liveValue` resolves `@Dependency(\.delegationEscrow)`
    /// at call time, and inside a test process that resolves to the
    /// unimplemented `testValue`, so a perfectly working carve would find all
    /// three bundles and then throw on every write. That failure reads exactly
    /// like a broken recovery, which is why it is called out here.
    private func openTheApp() async {
        let store = TestStore(
            initialState: Root.State(
                destinationState: Root.DestinationState(internalDestination: .welcome),
                exportLogsState: ExportLogs.State(),
                onboardingState: RestoreWalletCoordFlow.State(),
                phraseDisplayState: RecoveryPhraseDisplay.State(),
                walletConfig: .initial,
                welcomeState: Welcome.State()
            )
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate

            // The launch chain reaches well past recovery, and TCA refuses
            // live dependencies in tests, so everything it touches is stubbed.
            $0.sdkSynchronizer = .mocked()
            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp
            $0.databaseFiles.areDbFilesPresentFor = { _ in true }
            $0.walletStorage = .noOp
            $0.walletStorage.areKeysPresent = { true }
            $0.walletStorage.exportWallet = { .placeholder }
            $0.readTransactionsStorage = .noOp
            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            $0.userDefaults.objectForKey = { _ in nil }
            $0.userDefaults.setValue = { _, _ in }
            $0.userDefaults.remove = { _ in }
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )

            // The two under test, both real.
            $0.delegationRecovery = .liveValue
            $0.delegationEscrow = .liveValue
        }
        // The launch fan-out is covered elsewhere; only its effect on the
        // escrow matters here.
        store.exhaustivity = .off

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        await store.finish()
    }

    /// Entries the file-backed escrow holds for the fixture round.
    private func escrowedEntries() async throws -> [DelegationEscrowEntry] {
        try await withDependencies {
            $0.delegationEscrow = .liveValue
        } operation: {
            @Dependency(\.delegationEscrow) var escrow
            return try await escrow.entries(Expected.roundId)
        }
    }

    // MARK: - Preconditions

    /// The planted files must be there. Asserted, never skipped: a green run
    /// against a missing fixture would prove nothing.
    @Test func theCorruptedDatabaseWasPlantedInTheContainer() throws {
        let documents = try #require(RecoveryDeviceE2E.documents)
        let preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)

        for name in ["voting.sqlite3", "voting.sqlite3-wal"] {
            let url = preserved.appendingPathComponent(name)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "\(name) was not planted into the app container"
            )
            let size = (try? Data(contentsOf: url).count) ?? 0
            #expect(size > 0, "\(name) is empty")
        }

        // A checkpointed log carries only its header, and there would be
        // nothing left to recover from.
        let wal = try Data(
            contentsOf: preserved.appendingPathComponent("voting.sqlite3-wal")
        )
        #expect(wal.count > 32, "the planted log holds only a header")
    }

    // MARK: - The recovery path, driven by opening the app

    @Test func openingTheAppRecoversTheBroadcastDelegationAndEscrowsIt() async throws {
        let documents = try #require(RecoveryDeviceE2E.documents)
        let escrowFile = documents.appendingPathComponent(DelegationEscrowFile.name)
        // Start from a clean escrow, so what is on disk afterwards can only
        // have been put there by this launch.
        try? FileManager.default.removeItem(at: escrowFile)

        await openTheApp()

        // The escrow is the durable half. Launch returns no report by design,
        // so the file IS the observable: without it, recovery changed nothing
        // that survives to the next launch.
        #expect(
            FileManager.default.fileExists(atPath: escrowFile.path),
            "opening the app did not escrow anything"
        )

        let entries = try await escrowedEntries()
        #expect(entries.count == Expected.bundleCount)

        let recovered = entries
            .sorted { $0.bundleIndex < $1.bundleIndex }
            .map(\.vanCommRand.hexString)
        #expect(recovered == Expected.originalVanCommRand)

        for rebuilt in Expected.rebuiltVanCommRand {
            #expect(
                recovered.contains(rebuilt) == false,
                "a rebuilt secret was escrowed as though it were the original"
            )
        }
    }

    /// The recovered value must be usable as a blinding factor, not merely
    /// 32 bytes that decoded cleanly.
    @Test func everyRecoveredSecretIsACanonicalPallasElement() async throws {
        await openTheApp()

        let entries = try await escrowedEntries()
        #expect(entries.isEmpty == false)
        for entry in entries {
            #expect(DelegationWalRecovery.isCanonicalPallasElement(entry.vanCommRand))
        }
    }

    /// Recovery runs on EVERY cold launch, so opening the app repeatedly must
    /// converge rather than accumulate or drift.
    @Test func openingTheAppTwiceLeavesTheEscrowUnchanged() async throws {
        await openTheApp()
        let first = try await escrowedEntries().map(\.vanCommRand.hexString)

        await openTheApp()
        let second = try await escrowedEntries().map(\.vanCommRand.hexString)

        #expect(first == second)
        #expect(second.sorted() == Expected.originalVanCommRand.sorted())
    }

    /// Reading is not writing: the preserved files must come out byte for byte
    /// identical, or the next launch would have less to work with than this
    /// one did.
    @Test func openingTheAppDoesNotModifyThePlantedFiles() async throws {
        let documents = try #require(RecoveryDeviceE2E.documents)
        let preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)
        let urls = ["voting.sqlite3", "voting.sqlite3-wal"]
            .map { preserved.appendingPathComponent($0) }

        let before = try urls.map { try Data(contentsOf: $0) }
        await openTheApp()
        let after = try urls.map { try Data(contentsOf: $0) }

        #expect(before == after)
    }
}
#endif
