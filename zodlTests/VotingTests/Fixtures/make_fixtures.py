#!/usr/bin/env python3
"""Builds the voting-database fixtures used by `DelegationWalRecoveryTests`.

Two three-file sets are produced, mirroring the real post-clear/pre-clear
reproduction pair captured from a device:

  post-clear/   a round that `prepareFreshRound` deleted and rebuilt. Each
                bundle appears TWICE in the WAL: the original secrets in an
                early frame, the regenerated ones in a later frame.
  pre-clear/    the same round, never cleared. Each bundle appears ONCE.

Recovery must restore all three bundles from `post-clear/`, and must do
nothing at all for `pre-clear/`.

Every secret here is fabricated. The real reproduction contains live voting
material and must never be committed; run recovery against it out of tree.

Regenerate with:
    VOTING_SCHEMA_SQL=<path to 001_init.sql> python3 make_fixtures.py
"""

import os
import shutil
import sqlite3
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_ENV = "VOTING_SCHEMA_SQL"

ROUND_ID = "4a" * 32
WALLET_ID = "fixturewallet0000000000000000000"
BUNDLE_WEIGHTS = [130_000_000, 130_000_000, 26_000_000]


def secret(tag: int, byte: int) -> bytes:
    """Deterministic 32-byte stand-in that is a canonical Pallas element.

    The top byte is kept small so the little-endian value stays below the
    field modulus, exactly as a real blinding factor must.
    """
    return bytes([byte] * 31 + [tag & 0x3F])


def build(directory: str, schema: str, clear: bool) -> None:
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(directory)
    path = os.path.join(directory, "voting.sqlite3")

    conn = sqlite3.connect(path, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(schema)
    # Drain the schema commits so the WAL starts empty. Everything after this
    # point stays in the WAL, which is what makes the original delegation
    # recoverable -- in the real incident no checkpoint ran between the
    # delegation and the wipe.
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    def insert_round(phase: int, generation: int) -> None:
        conn.execute(
            "INSERT INTO rounds (round_id, wallet_id, network, snapshot_height, ea_pk,"
            " nc_root, nullifier_imt_root, phase, created_at)"
            " VALUES (?,?,'testnet',4245460,?,?,?,?,0)",
            (ROUND_ID, WALLET_ID, b"\x01" * 32, b"\x02" * 32, b"\x03" * 32, phase),
        )
        for index, weight in enumerate(BUNDLE_WEIGHTS):
            conn.execute(
                "INSERT INTO bundles (round_id, wallet_id, bundle_index, note_positions_blob,"
                " note_identity_hashes_blob, van_comm_rand, rho_signed, nf_signed, cmx_new,"
                " alpha, rseed_signed, rseed_output, gov_comm, total_note_value, address_index,"
                " rk, gov_nullifiers_blob, pczt_sighash, tx1_effects)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?,?,?)",
                (
                    ROUND_ID, WALLET_ID, index,
                    b"\x11" * 40, b"\x22" * 160,
                    secret(generation * 8 + index, 0xA0 + index),   # van_comm_rand
                    b"\x33" * 32, b"\x44" * 32, b"\x55" * 32,
                    secret(generation * 8 + index, 0xB0 + index),   # alpha
                    b"\x66" * 32, b"\x77" * 32,
                    secret(generation * 8 + index, 0xC0 + index),   # gov_comm
                    weight,
                    secret(generation * 8 + index, 0xD0 + index),   # rk
                    b"\x88" * 160,
                    secret(generation * 8 + index, 0xE0 + index),   # pczt_sighash
                    b"\x99" * 821,
                ),
            )

    # Generation 0: the delegation the user actually broadcast.
    insert_round(phase=3, generation=0)

    # Ordinary commits that rewrite the bundles page, so the pre-incident image
    # ends up in a superseded frame rather than the newest one.
    conn.execute("UPDATE rounds SET phase=3 WHERE round_id=?", (ROUND_ID,))
    conn.execute(
        "INSERT INTO proofs (round_id, wallet_id, bundle_index, proof, success, created_at)"
        " VALUES (?,?,0,?,1,0)",
        (ROUND_ID, WALLET_ID, b"\xAB" * 11_328),
    )

    if clear:
        # Exactly what `clear_round` does, then what `prepareFreshRound` does next.
        conn.execute(
            "DELETE FROM rounds WHERE round_id=? AND wallet_id=?", (ROUND_ID, WALLET_ID)
        )
        insert_round(phase=0, generation=1)

    # Terminate without closing: SQLite never checkpoints, so the WAL keeps
    # every frame. This is an app killed after the wipe.
    os._exit(0)


def main() -> int:
    schema_path = os.environ.get(SCHEMA_ENV)
    if not schema_path or not os.path.exists(schema_path):
        print(
            f"Set {SCHEMA_ENV} to zcash_voting/src/storage/migrations/001_init.sql",
            file=sys.stderr,
        )
        return 1

    for name in ("post-clear", "pre-clear"):
        # Each build ends in os._exit, so run it in its own process.
        child = subprocess.run([sys.executable, os.path.abspath(__file__), "--build", name])
        if child.returncode != 0:
            return child.returncode
        print(f"built {name}/")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--build":
        target = sys.argv[2]
        build(
            os.path.join(HERE, target),
            open(os.environ[SCHEMA_ENV]).read(),
            clear=(target == "post-clear"),
        )
    else:
        sys.exit(main())
