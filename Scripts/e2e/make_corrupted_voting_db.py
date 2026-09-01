#!/usr/bin/env python3
"""Builds a corrupted voting database for the recovery end-to-end test.

Produces the three-file SQLite set that a device presents after the incident
`8c6ecc93` fixes: a round whose delegation was broadcast, then deleted and
rebuilt with freshly sampled secrets. The originals survive only in superseded
write-ahead log frames, which is what recovery has to find.

Two sets are produced:

  post-clear/   deleted and rebuilt. Each bundle appears TWICE in the log.
                Recovery must restore all three originals.
  pre-clear/    never cleared. Each bundle appears ONCE. Recovery must do
                nothing at all, which is the idempotence control.

The schema is embedded rather than read from the Rust crate's
`001_init.sql`, so this runs in CI with no external inputs. Column ORDER is
load-bearing: records are decoded positionally by `DelegationWalRecovery`. Keep
it in step with `zodlTests/VotingTests/CorruptedVotingDatabase.swift`, which
carries the same DDL for the in-process suite.

Every secret here is fabricated, and the values match
`zodlTests/VotingTests/Fixtures/make_fixtures.py` so the artifacts are
interchangeable with the fixture-gated suite. The real captures hold live
voting material and must never be committed.

Usage:
    python3 make_corrupted_voting_db.py <output-directory>
"""

import os
import shutil
import sqlite3
import subprocess
import sys

ROUND_ID = "4a" * 32
WALLET_ID = "fixturewallet0000000000000000000"
BUNDLE_WEIGHTS = [130_000_000, 130_000_000, 26_000_000]

# Generation 0: what the user actually broadcast.
ORIGINAL_RAND = ["a0" * 31 + "00", "a1" * 31 + "01", "a2" * 31 + "02"]
# Generation 1: what the rebuild sampled in its place.
REBUILT_RAND = ["a0" * 31 + "08", "a1" * 31 + "09", "a2" * 31 + "0a"]
GOV_COMM = ["c0" * 31 + "00", "c1" * 31 + "01", "c2" * 31 + "02"]

# `rounds` and `bundles` from the voting crate's 001_init.sql, verbatim
# including column order.
SCHEMA = """
CREATE TABLE rounds (
    round_id            TEXT NOT NULL,
    wallet_id           TEXT NOT NULL DEFAULT '',
    network             TEXT NOT NULL CHECK (network IN ('mainnet','testnet','regtest')),
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
    FOREIGN KEY (round_id, wallet_id)
        REFERENCES rounds(round_id, wallet_id) ON DELETE CASCADE
);
"""


def insert_round(cursor, phase, rands):
    cursor.execute(
        "INSERT INTO rounds (round_id, wallet_id, network, snapshot_height,"
        " ea_pk, nc_root, nullifier_imt_root, phase, created_at)"
        " VALUES (?, ?, 'testnet', 4245460, X'01', X'02', X'03', ?, 0)",
        (ROUND_ID, WALLET_ID, phase),
    )
    for index, rand in enumerate(rands):
        cursor.execute(
            "INSERT INTO bundles (round_id, wallet_id, bundle_index,"
            " note_positions_blob, van_comm_rand, gov_comm, total_note_value,"
            " address_index) VALUES (?, ?, ?, X'11', ?, ?, ?, 0)",
            (
                ROUND_ID,
                WALLET_ID,
                index,
                bytes.fromhex(rand),
                bytes.fromhex(GOV_COMM[index]),
                BUNDLE_WEIGHTS[index],
            ),
        )


def build(directory, clear):
    if os.path.isdir(directory):
        shutil.rmtree(directory)
    os.makedirs(directory)

    connection = sqlite3.connect(os.path.join(directory, "voting.sqlite3"))
    connection.isolation_level = None
    cursor = connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.executescript(SCHEMA)
    # Drain the log so everything that follows stays in it. In the real
    # incident no checkpoint ran between the delegation and the wipe, which is
    # precisely why the originals survived.
    cursor.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    insert_round(cursor, 3, ORIGINAL_RAND)
    # An ordinary commit, so the bundles page is rewritten and the pre-incident
    # image becomes a superseded frame rather than the newest one.
    cursor.execute("UPDATE rounds SET phase = 3 WHERE round_id = ?", (ROUND_ID,))

    if clear:
        # Exactly what `clear_round` does: bundles cascades away with it.
        cursor.execute(
            "DELETE FROM rounds WHERE round_id = ? AND wallet_id = ?",
            (ROUND_ID, WALLET_ID),
        )
        # ...and what `prepareFreshRound` did next.
        insert_round(cursor, 0, REBUILT_RAND)

    # Terminate WITHOUT closing the connection. SQLite therefore never
    # checkpoints, and the log keeps every frame. This is an app killed after
    # the wipe, which is the state a device snapshot preserves.
    sys.stdout.flush()
    os._exit(0)


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    root = os.path.abspath(sys.argv[1])
    os.makedirs(root, exist_ok=True)

    for name in ("post-clear", "pre-clear"):
        target = os.path.join(root, name)
        # Each build ends in os._exit, so it needs its own process.
        child = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--build", target,
             "--clear" if name == "post-clear" else "--keep"]
        )
        if child.returncode != 0:
            print(f"failed to build {name}", file=sys.stderr)
            return child.returncode

        for required in ("voting.sqlite3", "voting.sqlite3-wal"):
            path = os.path.join(target, required)
            if not os.path.exists(path) or os.path.getsize(path) == 0:
                print(f"{name}: {required} missing or empty", file=sys.stderr)
                return 1

        wal = os.path.getsize(os.path.join(target, "voting.sqlite3-wal"))
        # A checkpointed log has only a 32-byte header and nothing to recover.
        if wal <= 32:
            print(f"{name}: log holds only a header", file=sys.stderr)
            return 1
        print(f"built {name}/ (log {wal} bytes)")

    return 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--build":
        build(sys.argv[2], clear=(sys.argv[3] == "--clear"))
    else:
        sys.exit(main())
