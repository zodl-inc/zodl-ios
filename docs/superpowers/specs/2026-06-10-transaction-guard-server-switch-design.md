# Server switch vs. transaction coordination — TransactionGuard redesign

**Date:** 2026-06-10
**Status:** Approved in design discussion; implementation plan pending
**Branch:** `michal/change-server-switch-lock-mechanism`

## Problem

The SDK's `switchTo(endpoint:)` tears down and rebuilds the synchronizer, so it must never
overlap a transaction broadcast. Today this is enforced by `TransactionGuard`
(`secant/Sources/Dependencies/TransactionGuard/TransactionGuard.swift`), a fair FIFO async
mutex actor, applied **per call site**: every broadcast wraps itself in
`transactionGuard.withSubmission { }`, the automatic server switch runs under
`switchIfIdle { }` (skips when busy), and the manual Save on Server Setup runs under
`switchWaiting { }` (waits, then wins).

This works, but has three weaknesses:

1. **Per-call-site discipline.** There are 11 scattered `withSubmission` sites
   (SendConfirmation ×2, SwapAndPay, Flexa in RootDestination, ShieldingProcessor,
   Voting ×6). Every new broadcast path must remember to wrap itself; a missed wrap is
   silent and dangerous, and one was already caught in review (unguarded
   `submitDelegation` during the PR #1804 review).
2. **No coverage for multi-call sequences.** The guard is released between the calls of one
   logical operation:
   - Voting round: `submitVoteCommitment` → ~90 s confirmation polling → `delegateShares`
     (`VotingCoordFlowCoordinator.swift:1892` … `:1939`) — the guard is free during the poll.
   - Keystone: proposal → minutes of QR signing on the hardware wallet →
     `createTransactionFromPCZT` (`SendConfirmationStore.swift:543`).
   - Flexa: unguarded `proposeTransfer` → guarded `createProposedTransactions`
     (`RootDestination.swift:114-124`).
3. **Mid-flow switch attempts are common, not theoretical.** `didEnterBackground` stops the
   synchronizer (`RootInitialization.swift:76`); `willEnterForeground` → `retryStart` →
   `start()` → `.refreshAutomaticServer` (`RootInitialization.swift:72`, `:199`). Every
   background/foreground cycle re-runs the endpoint benchmark (tens of seconds) followed by
   a possible switch. Reproduction: enter Send → submit → background the app → foreground →
   the benchmark runs while the user is still mid-flow → a switch can fire behind the
   send UI.

## Goals

- A broadcast can never overlap a server switch (the existing hard guarantee, kept).
- New broadcast paths **cannot forget** the guard — enforcement moves to a choke point.
- The automatic switch never applies while the user is inside a sensitive UI flow; it
  **defers** and applies when the flow ends.
- **No tracked or mirrored UI state.** Nothing event-based that can desync or get stuck.
- Manual switch behavior unchanged: an explicit user choice waits for in-flight broadcasts,
  then wins.

## Non-goals

- Suppressing switches while a transaction is pending-unmined in the SDK after the user
  leaves the flow. The SDK resubmits pending transactions to whichever endpoint is current;
  lightwalletd servers are interchangeable views of one network, and resubmitting an
  already-broadcast txid is idempotent. Suppressing for the whole unmined window (tens of
  minutes) would effectively disable auto-switching for active users.
- Changing the guard's liveness trade-off for a hung holder. The documented stance in
  `TransactionGuard.swift:75-80` (never force-release a half-applied switch) stays.

## Design overview

Three layers with different stakes:

| Layer | Mechanism | Stakes | Failure mode |
|---|---|---|---|
| 1 | Mutex inside dependency LiveKeys | Correctness (hard) | Unchanged from today |
| 2 | Benchmark/apply split; apply gated on live `Root.State` | UX (soft, defers) | Deferral only; cannot wedge |
| 3 | Logging | Observability | — |

Layer 1 is the only correctness-bearing mechanism. Layer 2 only decides *when* the
automatic switch applies; even if it judged wrongly, every broadcast remains individually
protected by layer 1.

## Layer 1 — mutex moves into the dependency choke points

Wrap the **live implementations** of the broadcast-sensitive closures in
`transactionGuard.withSubmission`, and delete all call-site wrappers. A future feature
physically cannot broadcast without going through these dependencies, so it cannot forget
the guard.

Closures to wrap (in their `liveValue`):

| Client | Closure | Declared at |
|---|---|---|
| `SDKSynchronizerClient` | `createProposedTransactions` | `SDKSynchronizerInterface.swift:65` (live: `SDKSynchronizerLive.swift`) |
| `SDKSynchronizerClient` | `createTransactionFromPCZT` | `SDKSynchronizerInterface.swift:82` |
| `SDKSynchronizerClient` | `getTreeState` | `SDKSynchronizerInterface.swift:108` |
| `VotingAPIClient` | `submitVoteCommitment` | `VotingAPIClientInterface.swift:69` (live: `VotingAPIClientLiveKey.swift`) |
| `VotingAPIClient` | `submitDelegation` | `VotingAPIClientInterface.swift:68` |

`getTreeState` is included because the voting flow's round-snapshot fetch is currently
call-site-guarded (`VotingCoordFlowCoordinator.swift:3312`) — a switch mid-fetch would fail
or skew the snapshot. Wrapping it at the choke point preserves that guarantee for all
callers. The guard is uncontended in normal operation, so wrapping a read costs nothing.

Wrap shape (mirrors the existing pattern of resolving dependencies inside live closures):

```swift
createProposedTransactions: { proposal, spendingKey in
    @Dependency(\.transactionGuard) var transactionGuard
    return try await transactionGuard.withSubmission {
        // existing implementation, unchanged
    }
}
```

Call-site wrappers to delete (keep the bodies, drop the `withSubmission` and the now-unused
`@Dependency(\.transactionGuard)` declarations):

- `SendConfirmationStore.swift:293` (send), `:543` (Keystone PCZT)
- `SwapAndPayCoordFlowCoordinator.swift:318`
- `RootDestination.swift:122` (Flexa)
- `ShieldingProcessorLiveKey.swift:75`
- `VotingCoordFlowCoordinator.swift:1892`, `:1939`, `:2911`, `:3312`, `:3484`, `:3607`

After this change, `transactionGuard` is referenced only by: the five LiveKey closures
above, `AutoServerSelectionLiveKey` (`switchIfIdle`), and `ServerSetupStore`
(`switchWaiting`).

Deliberate semantic deltas:

- `Voting.delegateSharesWithFallback` batches were previously one guard section including
  fallback retries; now each inner `submitDelegation` acquires individually. Acceptable:
  layer 2 covers the surrounding flow, and each broadcast remains individually exclusive
  against switches.
- Test values are unaffected: the wrap exists only in `liveValue`. Tests that exercise
  guard interplay keep injecting `TransactionGuardClient` explicitly (as
  `AutoServerSelectionClientTests` does today).

Unchanged: `TransactionGuard` actor semantics, `withTimeout(serverSwitchTimeout)`,
manual Save via `switchWaiting` (`ServerSetupStore.swift:342`), automatic switch via
`switchIfIdle` — still the hard backstop at apply time (skips if a broadcast is mid-flight).

## Layer 2 — benchmark/apply split, gated on live navigation state

The flaw in every tracking-based variant considered (operation tokens, enter/leave UI
events) is that they maintain a **copy** of "is the user in a sensitive flow" inside a
dependency, and a copy can desync — one missed event and suppression wedges for the
session. Root already owns the original: `state.path` and
`state.signWithKeystoneCoordFlowBinding`. So the apply decision moves into Root's reducer
and reads **current state at decision time**. Nothing is recorded, so nothing can go stale.

The timing problem this must solve: the benchmark takes tens of seconds, so a check when
the refresh *starts* says nothing about where the user is when the switch would *apply*.
Therefore the refresh splits into benchmark and apply, with the apply decision routed back
through the reducer where fresh state is in hand.

### Client API

`AutoServerSelectionClient` (`AutoServerSelectionInterface.swift`) changes from a single
`refreshIfEnabled` to:

```swift
@DependencyClient
struct AutoServerSelectionClient {
    /// Benchmarks the known endpoints when Automatic mode is enabled. Returns the best
    /// endpoint when it differs from the current one, nil otherwise (or when Automatic
    /// mode is off).
    var findBestServer: @Sendable () async -> LightWalletEndpoint?
    /// Re-validates (Automatic still on, candidate still differs from current) and applies
    /// the switch under the transaction guard: switchIfIdle + withTimeout + setServer.
    /// Returns true when the switch ran. Logs failures internally, like today.
    var applySwitch: @Sendable (LightWalletEndpoint) async -> Bool
}
```

`applySwitch` re-checks the Automatic preference and the candidate-vs-current difference
because both can change while a candidate sits deferred (the user may flip to Manual or
save a server manually).

### Root state and actions

```swift
// Root.State additions
struct PendingServerCandidate {
    let endpoint: LightWalletEndpoint
    let benchmarkedAt: Date
}
var pendingServerCandidate: PendingServerCandidate?

// Root.Action addition
case autoServerCandidateReady(LightWalletEndpoint)
```

```swift
extension Root.State {
    /// True while the user is inside a UI flow that may contain an in-progress payment
    /// or voting sequence. Read live at decision time — never stored anywhere.
    var isSensitiveFlowActive: Bool {
        if signWithKeystoneCoordFlowBinding { return true }
        guard let path else { return false }
        switch path {
        case .sendCoordFlow, .scanCoordFlow, .swapAndPayCoordFlow, .transactionsCoordFlow, .settings:
            return true
        case .addKeystoneHWWalletCoordFlow, .currencyConversionSetup, .receive,
             .requestZecCoordFlow, .serverSwitch, .torSetup, .walletBackup:
            return false
        }
    }

    var canApplyAutoServerSwitch: Bool {
        bgTask == nil && !isServerSetupVisible && !isSensitiveFlowActive
    }
}
```

The switch over `Path` is **exhaustive with no `default`**: adding a new flow to the enum
refuses to compile until it is classified. This converts "future flows must remember" into
a compile error.

Classification rationale:

- `.sendCoordFlow`, `.swapAndPayCoordFlow` — payment flows, the motivating case.
- `.scanCoordFlow`, `.transactionsCoordFlow` — can lead directly into send sequences;
  conservatively sensitive (the only cost of over-marking is deferral).
- `.settings` — sensitive because the voting flow is presented from Settings
  (`@Presents var votingCoordFlow`, `SettingsStore.swift:49`); marking the whole settings
  tree sensitive covers it with zero plumbing.
- `.serverSwitch` — not sensitive; that window belongs to the manual flow and is governed
  by `isServerSetupVisible` + `switchWaiting`.
- `signWithKeystoneCoordFlowBinding` — the PCZT signing flow (minutes of QR signing),
  presented via a separate binding on Root, hence checked separately.

### Reducer flow

```swift
case .refreshAutomaticServer:
    // Existing trigger gates, unchanged. The benchmark deliberately still runs while a
    // sensitive flow is active: it is read-only, and we want a candidate ready to apply
    // the moment the user leaves the flow.
    guard state.bgTask == nil, !state.isServerSetupVisible else { return .none }
    return .run { send in
        if let best = await autoServerSelection.findBestServer() {
            await send(.autoServerCandidateReady(best))
        }
    }
    .cancellable(id: state.automaticServerRefreshCancelId, cancelInFlight: true)

case .autoServerCandidateReady(let candidate):
    guard state.canApplyAutoServerSwitch else {
        state.pendingServerCandidate = PendingServerCandidate(endpoint: candidate, benchmarkedAt: date.now)
        // log: candidate deferred, sensitive flow active
        return .none
    }
    state.pendingServerCandidate = nil
    return .run { _ in
        _ = await autoServerSelection.applySwitch(candidate)
    }
```

Deferred candidates re-enter through the same single decision point when the blocking
condition clears — observed via TCA's `onChange` on the derived Bool, composed onto the
Root reducer:

```swift
.onChange(of: { $0.canApplyAutoServerSwitch }) { _, canApply in
    Reduce { state, _ in
        guard canApply, let pending = state.pendingServerCandidate else { return .none }
        state.pendingServerCandidate = nil
        guard date.now.timeIntervalSince(pending.benchmarkedAt) < Constants.pendingCandidateTTL else {
            // log: deferred candidate expired, dropped
            return .none
        }
        return .send(.autoServerCandidateReady(pending.endpoint))
    }
}
```

`pendingCandidateTTL` is 15 minutes, defined in `AutoServerSelectionConstants`: a candidate
older than that is dropped rather than applied (server health data goes stale; the next foreground re-benchmarks anyway).
Timestamps come from `@Dependency(\.date)`.

### Pending-candidate lifecycle

- Overwritten by any newer candidate (every foreground re-triggers the benchmark, and the
  refresh effect uses `cancelInFlight: true`).
- Dropped when older than the TTL at apply time.
- In-memory only; dies with the process. The next launch/foreground re-benchmarks.
- It is plain data consulted at decision points — it blocks nothing and cannot wedge
  anything.

### Walking the motivating scenario

User taps Send → broadcast runs under the layer-1 mutex → user backgrounds the app →
foregrounds → `refreshAutomaticServer` fires → benchmark runs while the user finishes the
flow → `.autoServerCandidateReady` lands in the reducer → `path == .sendCoordFlow` →
**deferred**, nothing moves under the send UI → user leaves the flow →
`canApplyAutoServerSwitch` flips → pending candidate applies via `switchIfIdle` at a quiet
moment. Had the candidate instead arrived while a broadcast was literally in flight,
`switchIfIdle` skips — layer 1 is the unconditional backstop. If the user force-quits
mid-flow, the candidate dies with the process.

### What layer 2 deliberately does not cover

- **Flexa** — its UI belongs to the Flexa SDK and is invisible to `path`. Its broadcast is
  layer-1 protected; the short unguarded `proposeTransfer` → `createProposedTransactions`
  gap is accepted (today's status quo; worst case a recoverable error).
- **Shielding** — runs in a detached task with no screen (`ShieldingProcessorLiveKey.swift:65`).
  Same reasoning.

## Layer 3 — observability

`LoggerProxy` events so the field behavior of the soft layer is visible:

- candidate deferred (which gate blocked it: bgTask / serverSetup / sensitive flow)
- deferred candidate applied after flow exit
- deferred candidate expired (TTL) and dropped
- switch skipped by `switchIfIdle` because the guard was busy (in `applySwitch`)

## Failure-mode analysis

| Mechanism | Worst failure | Blast radius |
|---|---|---|
| Mutex in LiveKeys | Hung SDK call holds the guard | Submissions queue behind it — identical to today's documented trade-off; unreachable from UI events |
| Live-state gate | A `Path` case statically misclassified | Auto-switch defers too much (or too little, where layer 1 still protects every broadcast); deterministic, compile-forced, unit-testable |
| Deferred candidate | Candidate never applies in a session | Auto-switch postponed until next foreground/launch benchmark; sends, sync, and manual switch unaffected |

There is no event sequence that wedges anything, because there are no events — the gate is
a pure function of current state, evaluated at the moment of each decision.

## Alternatives considered (rejected)

- **Status quo (per-call-site wraps).** Omission-prone (one already caught in review); no
  coverage for multi-call sequences.
- **UI-visibility flag as the correctness mechanism.** Broadcasts are facts about tasks,
  not screens: shielding has no screen, Flexa's UI is SDK-owned, TCA effects outlive
  dismissed screens. Also cannot replace the mutex for manual Save vs. in-flight broadcast
  (the shielding-then-navigate-to-ServerSetup overlap). A stale flag silently disables
  switching.
- **`withFlow { }` operation tokens.** Sound (ref-count held for an operation's lifetime,
  released by structured concurrency on cancellation), but adds boilerplate to many TCA
  actions. Rejected on maintainability.
- **Edge-tracked sensitive-UI set (enter/leave events).** Maintains a mirror of navigation
  state; one missed edge wedges suppression for the session. Superseded by reading the
  live state directly.
- **Layer 1 only.** Rejected: the background/foreground trigger chain makes mid-flow
  switch attempts a common case, and a switch landing between the steps of a voting round
  or Keystone signing produces user-visible failures even though each broadcast is safe.

## Testing

- `TransactionGuardTests` — unchanged (actor semantics untouched).
- LiveKey wrapping — a test per wrapped closure: a switch attempted via `switchIfIdle`
  during an in-flight call is skipped; `switchWaiting` waits, then runs.
- `Root.State.isSensitiveFlowActive` — unit test pinning every `Path` case and the
  Keystone binding.
- Root reducer (TCA test store):
  - candidate ready while sensitive flow active → deferred, no switch effect
  - flow exit with pending candidate → re-fed through `.autoServerCandidateReady` → applied
  - flow exit with expired candidate → dropped
  - candidate ready while `isServerSetupVisible` / `bgTask != nil` → deferred
  - newer candidate overwrites an older pending one
- `AutoServerSelectionClientTests` — update for the split API (`findBestServer` returns
  candidate without switching; `applySwitch` re-validates preference and current endpoint).
- `ServerSetupStoreTests` — unchanged behavior.
- Manual QA: the motivating scenario end-to-end, observing the defer → apply log sequence.

## Implementation order

1. **Layer 1** — wrap the five LiveKey closures, delete the eleven call-site wrappers and
   unused `transactionGuard` dependencies, update tests. No user-visible behavior change
   (besides delegate-batch guard granularity).
2. **Layer 2** — split `AutoServerSelectionClient`, add Root state/action/gates and the
   `onChange` re-feed, classification property + tests.
3. **Layer 3** — logging, update the TransactionGuard section in `CLAUDE.md` to describe
   the choke-point model (the "per call site" warning becomes obsolete).

## Future work (out of scope)

- Task-local reentrancy tolerance in `withSubmission` (defense against an accidentally
  re-added call-site wrap deadlocking against the LiveKey wrap).
- Watchdog log when the guard is held longer than a few minutes.
- Field telemetry on deferral frequency to validate the TTL and classification choices.
