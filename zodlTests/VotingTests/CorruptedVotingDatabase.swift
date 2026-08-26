#if VOTING_ENABLED
import Foundation
import SQLite3
@testable import zodl_internal

extension VotingRecoveryEndToEndTests {
    /// The values the built database is seeded with.
    enum Fixture {
        static let roundId = String(repeating: "4a", count: 32)
        static let walletId = "wallet-e2e"
        static let bundleCount = 3

        /// Generation 0 — the delegation the user broadcast.
        static let originalRand = [byte(0xA0), byte(0xA1), byte(0xA2)]
        /// Generation 1 — what the rebuild sampled in its place.
        static let rebuiltRand = [byte(0xB0), byte(0xB1), byte(0xB2)]
        static let govComm = String(repeating: "c0", count: 31) + "02"

        /// A 32-byte value whose most significant byte is small, so it is below
        /// the Pallas modulus and could genuinely have been a blinding factor.
        static func byte(_ value: UInt8) -> String {
            String(repeating: String(format: "%02x", value), count: 31) + "01"
        }
    }

    /// Builds a real voting database with SQLite, corrupts it the way the app
    /// corrupted it, and captures the resulting three-file set.
    ///
    /// The schema is the `rounds` and `bundles` definitions from
    /// `001_init.sql`, verbatim including column order — the record decoder
    /// reads columns positionally, so the order is load-bearing.
    final class CorruptedDatabase {
        let directory: URL
        let databaseURL: URL
        let walURL: URL
        let shmURL: URL

        var allURLs: [URL] { [databaseURL, walURL, shmURL] }

        /// - Parameter rebuildAfterClearing: when false, the round is never
        ///   cleared, producing the healthy database the idempotence tests use.
        init(rebuildAfterClearing: Bool) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("voting-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let live = directory.appendingPathComponent("live", isDirectory: true)
            let captured = directory.appendingPathComponent("captured", isDirectory: true)
            for url in [live, captured] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }

            databaseURL = captured.appendingPathComponent("voting.sqlite3")
            walURL = captured.appendingPathComponent("voting.sqlite3-wal")
            shmURL = captured.appendingPathComponent("voting.sqlite3-shm")

            let liveURL = live.appendingPathComponent("voting.sqlite3")
            let database = try Self.open(liveURL)
            defer { sqlite3_close(database) }

            try Self.exec(database, "PRAGMA journal_mode=WAL;")
            try Self.exec(database, "PRAGMA foreign_keys=ON;")
            try Self.exec(database, Self.schema)
            // Drain the log so everything that follows stays in it. In the real
            // incident no checkpoint ran between the delegation and the wipe,
            // which is precisely why the originals survived.
            try Self.exec(database, "PRAGMA wal_checkpoint(TRUNCATE);")

            try Self.exec(database, Self.insertRound(phase: 3, rands: Fixture.originalRand))
            // An ordinary commit, so the bundles page is rewritten and the
            // pre-incident image becomes a superseded frame rather than the
            // newest one.
            try Self.exec(
                database,
                "UPDATE rounds SET phase = 3 WHERE round_id = '\(Fixture.roundId)';"
            )

            if rebuildAfterClearing {
                // Exactly what `clear_round` does — `bundles` cascades away.
                try Self.exec(
                    database,
                    """
                    DELETE FROM rounds
                     WHERE round_id = '\(Fixture.roundId)' AND wallet_id = '\(Fixture.walletId)';
                    """
                )
                // …and what `prepareFreshRound` does next.
                try Self.exec(database, Self.insertRound(phase: 0, rands: Fixture.rebuiltRand))
            }

            // Capture the trio while the connection is still open. SQLite has
            // not checkpointed, so the log still holds every frame — this is
            // the state a device snapshot preserves.
            for (source, destination) in [
                (liveURL, databaseURL),
                (liveURL.appendingSuffix("-wal"), walURL),
                (liveURL.appendingSuffix("-shm"), shmURL)
            ] {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        /// A second, independent copy of the captured trio.
        ///
        /// Needed because opening a database checkpoints and unlinks its log:
        /// a test that queries the artifact would destroy what the other tests
        /// read from it.
        func duplicate() throws -> CorruptedDatabase {
            try CorruptedDatabase(cloning: self)
        }

        private init(cloning original: CorruptedDatabase) throws {
            directory = original.directory
                .deletingLastPathComponent()
                .appendingPathComponent("voting-e2e-copy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            databaseURL = directory.appendingPathComponent("voting.sqlite3")
            walURL = directory.appendingPathComponent("voting.sqlite3-wal")
            shmURL = directory.appendingPathComponent("voting.sqlite3-shm")

            for (source, destination) in zip(original.allURLs, allURLs) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }

        /// Every `van_comm_rand` SQL can still see, in bundle order.
        func queryVanCommRands() throws -> [String] {
            let database = try Self.open(databaseURL)
            defer { sqlite3_close(database) }

            var statement: OpaquePointer?
            let sql = "SELECT hex(van_comm_rand) FROM bundles ORDER BY bundle_index;"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Failure.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }

            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                values.append(String(cString: text).lowercased())
            }
            return values
        }

        // MARK: - SQLite plumbing

        enum Failure: Error {
            case sqlite(String)
        }

        private static func open(_ url: URL) throws -> OpaquePointer? {
            var database: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(database)
                throw Failure.sqlite(message)
            }
            return database
        }

        private static func exec(_ database: OpaquePointer?, _ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(error)
                throw Failure.sqlite("\(message) — while running: \(sql.prefix(120))")
            }
        }

        /// Blob values go in as hex literals so no statement binding is needed.
        private static func insertRound(phase: Int, rands: [String]) -> String {
            var sql = """
                INSERT INTO rounds
                    (round_id, wallet_id, network, snapshot_height,
                     ea_pk, nc_root, nullifier_imt_root, phase, created_at)
                VALUES
                    ('\(Fixture.roundId)', '\(Fixture.walletId)', 'testnet', 4245460,
                     X'01', X'02', X'03', \(phase), 0);

                """
            for (index, rand) in rands.enumerated() {
                sql += """
                    INSERT INTO bundles
                        (round_id, wallet_id, bundle_index, note_positions_blob,
                         van_comm_rand, gov_comm, total_note_value, address_index)
                    VALUES
                        ('\(Fixture.roundId)', '\(Fixture.walletId)', \(index), X'11',
                         X'\(rand)', X'\(Fixture.govComm)', 130000000, 0);

                    """
            }
            return sql
        }

        /// `rounds` and `bundles` from `001_init.sql`. Column order is part of
        /// the contract: records are decoded positionally.
        private static let schema = """
            CREATE TABLE rounds (
                round_id            TEXT NOT NULL,
                wallet_id           TEXT NOT NULL DEFAULT '',
                network             TEXT NOT NULL CHECK (network IN ('mainnet', 'testnet', 'regtest')),
                snapshot_height     INTEGER NOT NULL,
                ea_pk               BLOB NOT NULL,
                nc_root             BLOB NOT NULL,
                nullifier_imt_root  BLOB NOT NULL,
                session_json        TEXT,
                phase               INTEGER NOT NULL DEFAULT 0,
                created_at          INTEGER NOT NULL,
                bundle_policy_json  TEXT,
                PRIMARY KEY (round_id, wallet_id)
            );

            CREATE TABLE bundles (
                round_id            TEXT NOT NULL,
                wallet_id           TEXT NOT NULL DEFAULT '',
                bundle_index        INTEGER NOT NULL,
                note_positions_blob BLOB,
                note_identity_hashes_blob BLOB,
                van_comm_rand       BLOB,
                dummy_nullifiers    BLOB,
                rho_signed          BLOB,
                padded_note_data    BLOB,
                nf_signed           BLOB,
                cmx_new             BLOB,
                alpha               BLOB,
                rseed_signed        BLOB,
                rseed_output        BLOB,
                gov_comm            BLOB,
                total_note_value    INTEGER,
                address_index       INTEGER,
                van_leaf_position   INTEGER,
                rk                  BLOB,
                gov_nullifiers_blob BLOB,
                padded_note_secrets BLOB,
                pczt_sighash        BLOB,
                tx1_effects         BLOB,
                delegation_tx_hash  TEXT,
                PRIMARY KEY (round_id, wallet_id, bundle_index),
                FOREIGN KEY (round_id, wallet_id) REFERENCES rounds(round_id, wallet_id) ON DELETE CASCADE
            );
            """
    }
}

private extension URL {
    /// `voting.sqlite3` + `-wal`, which is how SQLite names its sidecars —
    /// a path suffix, not a path extension.
    func appendingSuffix(_ suffix: String) -> URL {
        deletingLastPathComponent().appendingPathComponent(lastPathComponent + suffix)
    }
}
#endif
