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
        /// A distinct round id for the neighbour rounds that create page
        /// pressure, so they cannot be confused with the round under test.
        static func otherRoundId(_ index: Int) -> String {
            String(repeating: String(format: "%02x", UInt8(0xE0 &+ UInt8(index & 0x0F))), count: 32)
        }

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
        /// - Parameter updateAfterCheckpoint: rewrites a bundle row AFTER the
        ///   rows have been checkpointed into the database file, which is what
        ///   the real delegation lifecycle does repeatedly as `alpha`, `rk`,
        ///   `rseed_signed`, `pczt_sighash` and `delegation_tx_hash` are
        ///   filled in. Each rewrite leaves the previous cell in freed space
        ///   with an IDENTICAL `van_comm_rand`, so the same value ends up both
        ///   live and released. A healthy round in that state must still read
        ///   as healthy.
        /// - Parameter notesPerBundle: scales the per-note blobs, which is
        ///   what makes a real record large. The fixture's default of one note
        ///   produces a row of a few hundred bytes; a real bundle at
        ///   `delegationConstructed` carries 8 bytes of position and 32 bytes
        ///   of identity hash PER NOTE, ahead of `van_comm_rand` in column 5,
        ///   plus everything `build_pczt` writes after it.
        /// - Parameter otherRounds: unrelated rounds inserted alongside, so the
        ///   bundles of interest share pages with neighbours instead of sitting
        ///   alone on freshly allocated ones.
        init(
            rebuildAfterClearing: Bool,
            updateAfterCheckpoint: Bool = false,
            notesPerBundle: Int = 1,
            otherRounds: Int = 0
        ) throws {
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

            // Both pragmas mirror `Store::open`; see the note on `schema`.
            try Self.exec(database, "PRAGMA journal_mode=WAL;")
            try Self.exec(database, "PRAGMA foreign_keys=ON;")
            try Self.exec(database, Self.schema)
            // Drain the log so everything that follows stays in it. In the real
            // incident no checkpoint ran between the delegation and the wipe,
            // which is precisely why the originals survived.
            try Self.exec(database, "PRAGMA wal_checkpoint(TRUNCATE);")

            for other in 0..<otherRounds {
                try Self.exec(
                    database,
                    Self.insertRound(
                        phase: 3,
                        rands: Fixture.originalRand,
                        notesPerBundle: notesPerBundle,
                        roundId: Fixture.otherRoundId(other)
                    )
                )
            }
            try Self.exec(
                database,
                Self.insertRound(
                    phase: 3, rands: Fixture.originalRand, notesPerBundle: notesPerBundle
                )
            )
            // An ordinary commit, so the bundles page is rewritten and the
            // pre-incident image becomes a superseded frame rather than the
            // newest one.
            try Self.exec(
                database,
                "UPDATE rounds SET phase = 3 WHERE round_id = '\(Fixture.roundId)';"
            )

            if rebuildAfterClearing {
                // Byte for byte the statement `clear_round` issues:
                // <https://github.com/valargroup/zcash_voting/blob/4db47293736ed0c06dee512d59f08a65ca11e11f/zcash_voting/src/storage/queries.rs#L598-L601>
                // `bundles` goes with it through ON DELETE CASCADE (see
                // `schema`), which is the whole incident: `van_comm_rand` is
                // destroyed by a statement that never mentions it.
                try Self.exec(
                    database,
                    """
                    DELETE FROM rounds
                     WHERE round_id = '\(Fixture.roundId)' AND wallet_id = '\(Fixture.walletId)';
                    """
                )
                // …and what `prepareFreshRound` does next.
                try Self.exec(
                    database,
                    Self.insertRound(
                        phase: 0, rands: Fixture.rebuiltRand, notesPerBundle: notesPerBundle
                    )
                )
            }

            if updateAfterCheckpoint {
                // Land the rows in the database file, then rewrite one. The
                // update writes a new cell and releases the old one, and the
                // second checkpoint makes both visible in the file.
                try Self.exec(database, "PRAGMA wal_checkpoint(FULL);")
                // Must GROW the record. An integer-to-integer update of the
                // same width is rewritten in place, leaving no freed cell, so
                // it cannot produce the live-and-released state at all. Filling
                // a NULL column with 32 bytes forces a new cell and releases
                // the old one, which is what the delegation lifecycle does when
                // it writes `alpha`, `rk` and `pczt_sighash`.
                try Self.exec(
                    database,
                    """
                    UPDATE bundles SET rk = X'\(String(repeating: "dd", count: 32))'
                     WHERE round_id = '\(Fixture.roundId)' AND bundle_index = 0;
                    """
                )
                try Self.exec(database, "PRAGMA wal_checkpoint(FULL);")
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


        /// The schema applied and nothing inserted: a wallet that never opened
        /// a poll. Closed cleanly on purpose, so its log is checkpointed away
        /// and there is genuinely nothing anywhere to find.
        static func writeEmptySchema(to url: URL) throws {
            let database = try open(url)
            defer { sqlite3_close(database) }

            try exec(database, "PRAGMA journal_mode=WAL;")
            try exec(database, "PRAGMA foreign_keys=ON;")
            try exec(database, schema)
            try exec(database, "PRAGMA wal_checkpoint(TRUNCATE);")
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

        static func open(_ url: URL) throws -> OpaquePointer? {
            var database: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(database)
                throw Failure.sqlite(message)
            }
            return database
        }

        static func exec(_ database: OpaquePointer?, _ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(error)
                throw Failure.sqlite("\(message) — while running: \(sql.prefix(120))")
            }
        }

        /// Blob values go in as hex literals so no statement binding is needed.
        /// Blob literal of `bytes` bytes, filled with `fill`.
        private static func blob(_ fill: String, _ bytes: Int) -> String {
            "X'\(String(repeating: fill, count: max(bytes, 1)))'"
        }

        /// One round and its bundles, with every column `build_pczt` writes
        /// populated, so the record is the size a real one would be.
        ///
        /// `van_comm_rand` is column 5, BEHIND `note_positions_blob` and
        /// `note_identity_hashes_blob`. Both scale with the note count, so a
        /// bundle holding enough notes pushes the secret past the page's local
        /// payload and into an overflow page, which the carver does not follow.
        /// That boundary is what `DelegationRecordSizeTests` measures.
        private static func insertRound(
            phase: Int,
            rands: [String],
            notesPerBundle: Int = 1,
            roundId: String = Fixture.roundId
        ) -> String {
            let notes = max(notesPerBundle, 1)
            var sql = """
                INSERT INTO rounds
                    (round_id, wallet_id, network, snapshot_height,
                     ea_pk, nc_root, nullifier_imt_root, phase, created_at)
                VALUES
                    ('\(roundId)', '\(Fixture.walletId)', 'testnet', 4245460,
                     X'01', X'02', X'03', \(phase), 0);

                """
            for (index, rand) in rands.enumerated() {
                sql += """
                    INSERT INTO bundles
                        (round_id, wallet_id, bundle_index,
                         note_positions_blob, note_identity_hashes_blob,
                         van_comm_rand, dummy_nullifiers, rho_signed,
                         padded_note_data, nf_signed, cmx_new, alpha,
                         rseed_signed, rseed_output, gov_comm,
                         total_note_value, address_index, rk,
                         gov_nullifiers_blob, padded_note_secrets, pczt_sighash,
                         tx1_effects)
                    VALUES
                        ('\(roundId)', '\(Fixture.walletId)', \(index),
                         \(blob("aa", 8 * notes)), \(blob("bb", 32 * notes)),
                         X'\(rand)', \(blob("cc", 32 * notes)), \(blob("dd", 32)),
                         \(blob("ee", 64 * notes)), \(blob("ff", 32)),
                         \(blob("11", 32)), \(blob("22", 32)),
                         \(blob("33", 32)), \(blob("44", 32)),
                         X'\(Fixture.govComm)',
                         130000000, 0, \(blob("55", 32)),
                         \(blob("66", 32 * notes)), \(blob("77", 64 * notes)),
                         \(blob("88", 32)), \(blob("99", 512)));

                    """
            }
            return sql
        }

        /// `rounds` and `bundles`, copied VERBATIM from the voting crate's
        /// first migration. Column order is part of the contract: the carver
        /// decodes records positionally, so a reordering upstream silently
        /// changes which column it reads as `van_comm_rand`.
        ///
        /// Source, pinned to the commit this was taken from:
        /// <https://github.com/valargroup/zcash_voting/blob/4db47293736ed0c06dee512d59f08a65ca11e11f/zcash_voting/src/storage/migrations/001_init.sql>
        /// `rounds` is lines 1-14, `bundles` lines 16-43. Only `rounds` has
        /// ever gained a column (at schema v13), so this `bundles` layout is
        /// valid for every version the app has shipped.
        ///
        /// The pragmas below match what the crate sets when it opens a
        /// database, and both matter to what this fixture reproduces:
        /// <https://github.com/valargroup/zcash_voting/blob/4db47293736ed0c06dee512d59f08a65ca11e11f/zcash_voting/src/storage/mod.rs#L94>
        ///
        ///     PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
        ///
        /// `journal_mode=WAL` is why superseded page images exist to recover
        /// at all, and `foreign_keys=ON` is what makes the round delete
        /// CASCADE into `bundles` and take `van_comm_rand` with it. Without
        /// the second, the incident this fixture reproduces cannot happen.
        ///
        /// The delete being reproduced is `clear_round`:
        /// <https://github.com/valargroup/zcash_voting/blob/4db47293736ed0c06dee512d59f08a65ca11e11f/zcash_voting/src/storage/queries.rs#L600>
        static let schema = """
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
