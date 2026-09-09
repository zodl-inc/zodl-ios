# VotingRecovery

Recovery of poll delegations that an earlier build wiped. The mechanism has
four parts, all in this package:

- **Snapshot.** Before the voting database is opened, a copy of it and its
  write-ahead log is preserved under `Documents/voting_recovery/`. Opening
  checkpoints and unlinks the log, and the log is the only place a cleared
  round's original secrets still exist.
- **Recovery.** On every cold launch, every preserved copy and the live
  database are decoded without SQLite (`Decoder/`), and every schema-consistent
  delegation record found is written to the escrow with where it was found.
- **Escrow.** A file beside the voting database holding every candidate
  blinding factor per bundle, keyed by bundle, blinding and commitment, with a
  provenance rank and a mark for candidates the chain refused.
- **Restore.** When a poll is entered, the best candidate per bundle that opens
  its commitment is offered to the SDK's guarded restore, which clears the
  round only if that costs the wallet nothing. A leaf the chain refuses at tree
  sync marks that candidate so the next restore offers the next one.

## How the app reaches it

Every call site is marked `VotingRecovery`, so `grep -rn VotingRecovery secant`
lists them all:

| Seam | Where |
|---|---|
| `VotingRecovery.configure(logger:backend:didRestore:)` | `VotingCryptoClientLiveKey.liveValue`, once |
| `VotingRecovery.preserve(databasePath:)` | the database actor's `open`, before the database is opened |
| `VotingRecovery.captureLiveDelegation(...)` | `buildVotingPczt`, while the blinding factor is in hand |
| `VotingRecovery.wipe(inDocuments:)` | `Root.clearDeviceScopedWalletState` |
| `@Dependency(\.delegationRecovery).run()` | `Root`, on cold launch, cancellable by `VotingRecovery.CancelID.launch` |
| `.cancel(id: VotingRecovery.CancelID.launch)` | `Root`, at `.resetZashi` |
| `@Dependency(\.delegationRestore)` | `VotingCoordFlow`: restore on poll entry, chain refusal at tree sync, the diagnosis signal |

`DelegationDiagnosis` stays in the app. It takes booleans, never recovery
types, so its messages survive the package's removal; `secretsRecovered` and
`commitmentUndecodable` simply become unreachable.

## Removing it

1. Delete `Packages/VotingRecovery` and its reference in `secant.xcodeproj`.
2. Delete each line or file that `grep -rn VotingRecovery secant zodlTests`
   names, and drop `Packages/` from `.swiftlint.yml`.
3. Delete the recovery tests under `zodlTests/VotingTests`,
   `zodlTests/TestSupport/SharedLiveEscrow.swift`,
   `Scripts/e2e/run-delegation-recovery-e2e.sh` and its workflow step.

## Tests

The unit tests live in the app's test target, under `zodlTests/VotingTests`,
with `@testable import VotingRecovery`, so CI runs them with everything else.
The device suite is driven by `Scripts/e2e/run-delegation-recovery-e2e.sh`.
