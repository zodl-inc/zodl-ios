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

The application sends candidates to the SDK only when they form one complete,
contiguous, unambiguous batch for the current wallet and round. The SDK then
re-fetches the public tree, recomputes its advertised root, recomputes every VAN
from the recovered randomness, voting hotkey, round, and weight, and checks the
active database under a write transaction. It restores only the minimal rows
needed to resume voting, and either restores the whole batch or writes nothing.

The automatic attempt is limited to an existing incomplete round for which the
ordinary exact-transaction recovery found no bundle. Missing, partial,
ambiguous, conflicting, already-voted, or ordinary current state is left
untouched so the normal delegation path can continue.

Recovered values contain sensitive wallet and proof material. Do not log them,
include them in analytics, or place them in ordinary support exports.
