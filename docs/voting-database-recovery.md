# Voting database recovery

`VotingDatabaseSnapshot` preserves the first available `voting.sqlite3`,
`voting.sqlite3-wal`, and `voting.sqlite3-shm` set before the voting SDK opens
the database. Recovery must run against that preserved set, never the active
files.

`VotingDatabaseRecovery` requires two independently trusted values:

- the 64-character round identifier;
- the exact 32-byte `van_cmx` obtained from that round's production commitment
  leaves.

The optional wallet and bundle identifiers should also be supplied when they
can be established independently. In particular, bundle indices zero and one
can be encoded entirely in a SQLite record header; if deletion overwrote that
header, the raw body cannot prove the index without external context.

Recovery uses three complementary paths:

1. Validate the current WAL generation's header, salts, cumulative checksums,
   and commit markers. Apply each committed prefix to an in-memory copy of the
   main database, resolve the `bundles` root through `sqlite_schema`, and inspect
   the resulting reachable table rows.
2. Carve every WAL page image, including stale salt-mismatched frames. These
   frames are unordered forensic candidates; physical frame number is never
   used to decide which delegation is original.
3. Carve the main database, including unreachable and freed pages. When a
   deleted record header is damaged, a surviving bundle layout can locate the
   remaining body relative to the exact target commitment.

Every returned candidate has `gov_comm == van_cmx`, a canonical 32-byte Pallas
`van_comm_rand`, a valid round identifier, and schema-consistent bundle fields.
An exact target occurrence that cannot be decoded safely is reported only as a
raw hit, not as recovered state.

The result is still forensic input, not authorization to write the voting
database. Before restoration, the SDK must recompute the VAN from the recovered
randomness, trusted round/hotkey context, and weight, require the same on-chain
commitment, and validate any additional fields needed by the import path.

Recovered values contain sensitive wallet and proof material. Do not log them,
include them in analytics, or place them in ordinary support exports.
