# Voting-database recovery fixtures

Two `voting.sqlite3` / `-wal` / `-shm` sets used by `DelegationWalRecoveryTests`,
built by `make_fixtures.py`:

| fixture       | round state                              | WAL versions per bundle | expected plan |
| ------------- | ---------------------------------------- | ----------------------- | ------------- |
| `post-clear/` | deleted by `prepareFreshRound`, rebuilt  | 2 (original + rebuilt)  | 3 replacements |
| `pre-clear/`  | untouched                                | 1                       | none — no-op   |

They reproduce the shape of a real captured incident: a delegation broadcast
returned successfully, the app crashed before persisting the transaction hash
and VAN position, and on restart the round was deleted and recreated with
freshly sampled secrets. The originals survive only in superseded WAL frames.

`pre-clear/` is the idempotence guard. Recovery must not "restore" anything for
a round that was never cleared, and a bundle whose page was merely rewritten
still has a single `van_comm_rand`, so the plan comes back empty.

## Regenerating

```sh
VOTING_SCHEMA_SQL=…/zcash_voting/src/storage/migrations/001_init.sql \
    python3 make_fixtures.py
```

Expected values are asserted in the test; if you change the generator, update
`DelegationWalRecoveryTests.Expected` to match.

The generated directories are git-ignored. `DelegationWalRecoveryTests` skips
itself until `make_fixtures.py` has been run, so a clean checkout stays green.

## What is deliberately not here

Every secret in these files is fabricated. The real captures contain live
voting recovery material — blinding factors that cannot be regenerated and that
are not derivable from the seed. They are not committed to this repository and
must not be: run recovery against a copy of them outside the source tree.
