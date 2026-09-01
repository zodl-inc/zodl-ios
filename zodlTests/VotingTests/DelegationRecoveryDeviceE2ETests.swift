#if VOTING_ENABLED
@preconcurrency import Combine
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// Where the app keeps its files, kept OUTSIDE the suite type because a
/// `@Suite` condition cannot reach into the type its macro is attached to.
enum RecoveryDeviceE2E {
    static var documents: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
    }

    /// Always on. The suite builds the database it needs, so there is no
    /// precondition to gate on, and an end-to-end test that quietly passes
    /// because its data is missing is worse than no test at all.
    static let isEnabled = true
}

/// Recovery driven THROUGH APP LAUNCH against a corrupted database planted in
/// the app's own container, where a real affected device would hold it.
/// `Scripts/e2e/run-delegation-recovery-e2e.sh` runs this suite on a
/// simulator; the suite itself does the planting.
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
    /// The values the planted database actually holds. Taken from the builder
    /// rather than restated, because a second copy of them is exactly how this
    /// suite and the fixture drifted apart before.
    private typealias Expected = VotingRecoveryEndToEndTests.Fixture

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

    /// Plants a corrupted voting database where the app will look, using the
    /// SAME builder the in-process suites use.
    ///
    /// Planting from inside the test, with the builder the in-process suites
    /// use, keeps ONE implementation of the fixture and removes any need to
    /// re-resolve the container path, which reinstalling migrates.
    ///
    /// Returns the preserved directory so the caller can assert on the files.
    @discardableResult
    private func plantCorruptedDatabase() throws -> URL {
        let documents = try #require(RecoveryDeviceE2E.documents)
        let preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)

        try? FileManager.default.removeItem(at: preserved)
        try FileManager.default.createDirectory(
            at: preserved, withIntermediateDirectories: true
        )

        let corrupted = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: true
        )
        for source in corrupted.allURLs {
            try FileManager.default.copyItem(
                at: source,
                to: preserved.appendingPathComponent(source.lastPathComponent)
            )
        }
        return preserved
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
        let preserved = try plantCorruptedDatabase()

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
        try plantCorruptedDatabase()

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
        #expect(recovered == Expected.originalRand)

        for rebuilt in Expected.rebuiltRand {
            #expect(
                recovered.contains(rebuilt) == false,
                "a rebuilt secret was escrowed as though it were the original"
            )
        }
    }

    /// The recovered value must be usable as a blinding factor, not merely
    /// 32 bytes that decoded cleanly.
    @Test func everyRecoveredSecretIsACanonicalPallasElement() async throws {
        try plantCorruptedDatabase()
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
        try plantCorruptedDatabase()
        await openTheApp()
        let first = try await escrowedEntries().map(\.vanCommRand.hexString)

        await openTheApp()
        let second = try await escrowedEntries().map(\.vanCommRand.hexString)

        #expect(first == second)
        #expect(second.sorted() == Expected.originalRand.sorted())
    }

    /// Reading is not writing: the preserved files must come out byte for byte
    /// identical, or the next launch would have less to work with than this
    /// one did.
    @Test func openingTheAppDoesNotModifyThePlantedFiles() async throws {
        let documents = try #require(RecoveryDeviceE2E.documents)
        let preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)
        let urls = ["voting.sqlite3", "voting.sqlite3-wal"]
            .map { preserved.appendingPathComponent($0) }

        try plantCorruptedDatabase()
        let before = try urls.map { try Data(contentsOf: $0) }
        await openTheApp()
        let after = try urls.map { try Data(contentsOf: $0) }

        #expect(before == after)
    }
}
#endif
