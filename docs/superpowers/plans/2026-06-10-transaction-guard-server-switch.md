# TransactionGuard Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the transaction/server-switch mutex into the dependency LiveKey choke points, and split the automatic server switch into benchmark + apply with the apply decision gated on live Root navigation state (defer, not drop).

**Architecture:** Three layers per the approved spec ([2026-06-10-transaction-guard-server-switch-design.md](../specs/2026-06-10-transaction-guard-server-switch-design.md)): (1) `withSubmission` wraps the live implementations of six broadcast-sensitive dependency closures and all 11 call-site wrappers are deleted; (2) `AutoServerSelectionClient` splits into `findBestServer`/`applySwitch`, with a `.autoServerCandidateReady` action gated on `Root.State.canApplyAutoServerSwitch` (a pure live-state read), a `pendingServerCandidate` with 15-min TTL, and an `onChange` re-feed; (3) defer/apply/skip logging. Layer 1 is the correctness layer; layer 2 only decides *when* the auto-switch applies.

**Tech Stack:** Swift 6 / SwiftUI, TCA (`@Reducer`, `@ObservableState`, `@DependencyClient`), ZcashLightClientKit, XCTest.

---

## Conventions for all tasks

**Tooling.** This is an Xcode project — use the Xcode MCP tools, not raw `xcodebuild`:
- Get the workspace tab once: `mcp__xcode__XcodeListWindows` → use its `tabIdentifier` everywhere below.
- Read/search: `mcp__xcode__XcodeRead` / `mcp__xcode__XcodeGrep` with **Xcode-organization paths**.
- Edit: `mcp__xcode__XcodeUpdate` (string replacement) with Xcode-organization paths. Plain `Edit` on the filesystem path is an acceptable fallback.
- Build: `mcp__xcode__BuildProject`. On failure, `mcp__xcode__GetBuildLog`.
- Tests: `mcp__xcode__RunSomeTests` with identifiers like `zodlTests/AutoServerSelectionClientTests`, or `mcp__xcode__RunAllTests`. The active scheme must be **zodl-internal** (the Xcode MCP only operates on the active scheme and cannot switch it — ask the user if a different scheme is active); tests live in target **zodlTests** and use `@testable import zodl_internal`.
- `RunSomeTests` validates against a possibly stale test index: after **adding** a test class or method, build first; if the test is reported "not found", use `mcp__xcode__RunAllTests` (it forces a build-for-testing and reliably discovers new tests). Do not use CLI `xcodebuild test` — it hits a known resource-copy conflict with the gitignored `PartnerKeys.plist`.

**Path mapping** (Xcode organization ↔ filesystem, from repo root):

| Xcode-organization path | Filesystem path |
|---|---|
| `secant/secant/Sources/...` | `secant/Sources/...` |
| `secant/zodlTests/...` | `zodlTests/...` |

Git commands use filesystem paths.

**Style rules (enforced; violations fail the build or review):**
- Construct instances with the explicit type name — never `.init(...)` shorthand.
- No semicolons — one statement per line.
- 4-space indentation, 150-char line warning, no force unwraps, no `print`.
- New `// TODO:` comments must reference an issue number — do not add any.

**Commits:** descriptive title (no issue number exists for this work), body optional, and end the message with:
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

**Every task must end with a green build, green tests, and a commit.**

## File structure

| File (filesystem path) | Change |
|---|---|
| `secant/Sources/Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift` | Wrap 3 closures in the guard (Tasks 1–3) |
| `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` | Wrap 3 closures in the guard (Task 4) |
| `secant/Sources/Features/SendConfirmation/SendConfirmationStore.swift` | Unwrap 2 call sites, drop guard dependency (Tasks 1–2) |
| `secant/Sources/Features/CoordFlows/SwapAndPayCoordFlowCoordinator.swift` + `...Store.swift` | Unwrap 1 call site, drop guard dependency (Task 1) |
| `secant/Sources/Features/Root/RootDestination.swift` | Unwrap Flexa call site (Task 1) |
| `secant/Sources/Dependencies/ShieldingProcessor/ShieldingProcessorLiveKey.swift` | Unwrap 1 call site, drop guard dependency + capture (Task 1) |
| `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift` + `...Store.swift` | Unwrap 6 call sites, drop guard dependencies (Tasks 3–4) |
| `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionInterface.swift` | Split client API + TTL constant (Task 6) |
| `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionLiveKey.swift` | `findBestServer`/`applySwitch` live implementations (Task 6) |
| `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionTestKey.swift` | New test value (Task 6) |
| `secant/Sources/Features/Root/RootStore.swift` | State/Action/gating/onChange (Tasks 6–9) |
| `zodlTests/UtilTests/AutoServerSelectionClientTests.swift` | Rewrite for split API + new gating test class (Tasks 6–7) |
| `CLAUDE.md` | Update Transaction guard section (Task 10) |

Do **not** create any new source files — this project registers files in `project.pbxproj` explicitly (no synchronized folders), so new files require project-file surgery. All additions go into the files above.

---

### Task 1: Guard `createProposedTransactions` at the choke point

The wrap moves into `SDKSynchronizerClient.liveValue`; the four call sites that wrap this call today are unwrapped in the same commit (leaving both would nest a non-reentrant mutex → runtime deadlock).

**Files:**
- Modify: `secant/Sources/Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift` (closure starts at line ~135)
- Modify: `secant/Sources/Features/SendConfirmation/SendConfirmationStore.swift:293`
- Modify: `secant/Sources/Features/CoordFlows/SwapAndPayCoordFlowCoordinator.swift:318` + `SwapAndPayCoordFlowStore.swift:94`
- Modify: `secant/Sources/Features/Root/RootDestination.swift:122` + `secant/Sources/Features/Root/RootStore.swift:268`
- Modify: `secant/Sources/Dependencies/ShieldingProcessor/ShieldingProcessorLiveKey.swift:33,65,75`

- [ ] **Step 1: Wrap the live closure**

Read the closure with `XcodeRead` (`secant/secant/Sources/Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift`, offset 130, limit 115). It currently begins:

```swift
            createProposedTransactions: { proposal, spendingKey in
                let stream = try await synchronizer.createProposedTransactions(
```

Rewrite the closure so the **entire existing body** is inside the guard — body content unchanged, re-indented one level (4 spaces):

```swift
            createProposedTransactions: { proposal, spendingKey in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let stream = try await synchronizer.createProposedTransactions(
                        proposal: proposal,
                        spendingKey: spendingKey
                    )
                    // ... existing body, byte-identical, re-indented ...
                }
            },
```

The closure ends immediately before the `createTransactionFromPCZT:` entry (line ~241). Add the closing `}` of `withSubmission` before the closure's existing closing `},`.

- [ ] **Step 2: Unwrap SendConfirmationStore.swift:293**

Replace:

```swift
                        let result = try await transactionGuard.withSubmission {
                            try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
                        }
```

with:

```swift
                        let result = try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
```

Do **not** delete `@Dependency(\.transactionGuard)` at `SendConfirmationStore.swift:190` yet — line 543 still uses it (Task 2 removes it).

- [ ] **Step 3: Unwrap SwapAndPayCoordFlowCoordinator.swift:318**

Replace (identical shape to Step 2):

```swift
                        let result = try await transactionGuard.withSubmission {
                            try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
                        }
```

with:

```swift
                        let result = try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
```

Then delete this line from `SwapAndPayCoordFlowStore.swift:94` (no other use remains in the SwapAndPay flow — verify with `XcodeGrep` pattern `transactionGuard` path `secant/secant/Sources/Features/CoordFlows`):

```swift
    @Dependency(\.transactionGuard) var transactionGuard
```

- [ ] **Step 4: Unwrap the Flexa site, RootDestination.swift:122**

Replace:

```swift
                        let result = try await transactionGuard.withSubmission {
                            try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
                        }
```

with:

```swift
                        let result = try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
```

Then delete from `RootStore.swift:268` (RootDestination extends Root; this was its only guard use — verify with `XcodeGrep` pattern `transactionGuard` path `secant/secant/Sources/Features/Root`):

```swift
    @Dependency(\.transactionGuard) var transactionGuard
```

- [ ] **Step 5: Unwrap ShieldingProcessorLiveKey.swift**

At line ~75, replace:

```swift
                    let result = try await transactionGuard.withSubmission {
                        try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
                    }
```

with:

```swift
                    let result = try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
```

At line ~65, remove `transactionGuard` from the capture list:

```swift
            Task { [subject, derivationTool, mnemonic, sdkSynchronizer, walletStorage, zcashSDKEnvironment] in
```

At line ~33, delete:

```swift
    @Dependency(\.transactionGuard) var transactionGuard
```

- [ ] **Step 6: Build**

Run `mcp__xcode__BuildProject`. Expected: build succeeds. If it fails with an unused-variable or unresolved-symbol error, a deletion in Steps 3–5 was wrong — check `GetBuildLog`.

- [ ] **Step 7: Run the nearby test suites**

Run `mcp__xcode__RunSomeTests` with tests: `["zodlTests/TransactionGuardTests", "zodlTests/AutoServerSelectionClientTests", "zodlTests/ServerSetupStoreTests"]`. Expected: all pass (these stub the guard/synchronizer explicitly, so the LiveKey change is invisible to them).

- [ ] **Step 8: Commit**

```bash
git add secant/Sources
git commit -m "Move transaction guard into createProposedTransactions LiveKey

The live implementation acquires the guard itself; the four call-site
withSubmission wrappers (send, swap, Flexa, shielding) are removed in
the same change so the non-reentrant guard is never nested.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Guard `createTransactionFromPCZT` at the choke point

**Files:**
- Modify: `secant/Sources/Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift` (closure starts at line ~241)
- Modify: `secant/Sources/Features/SendConfirmation/SendConfirmationStore.swift:543,190`

- [ ] **Step 1: Wrap the live closure**

Same transformation as Task 1 Step 1. The closure currently begins:

```swift
            createTransactionFromPCZT: { pcztWithProofs, pcztWithSigs in
                let stream = try await synchronizer.createTransactionFromPCZT(
```

becomes:

```swift
            createTransactionFromPCZT: { pcztWithProofs, pcztWithSigs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let stream = try await synchronizer.createTransactionFromPCZT(
                        pcztWithProofs: pcztWithProofs,
                        pcztWithSigs: pcztWithSigs
                    )
                    // ... existing body, byte-identical, re-indented ...
                }
            },
```

The closure ends immediately before the `getTreeState:` entry (line ~335).

- [ ] **Step 2: Unwrap SendConfirmationStore.swift:543**

Replace:

```swift
                        let result = try await transactionGuard.withSubmission {
                            try await sdkSynchronizer.createTransactionFromPCZT(pcztWithProofs, pcztWithSigs)
                        }
```

with:

```swift
                        let result = try await sdkSynchronizer.createTransactionFromPCZT(pcztWithProofs, pcztWithSigs)
```

Now delete from `SendConfirmationStore.swift:190` (both its uses are gone):

```swift
    @Dependency(\.transactionGuard) var transactionGuard
```

- [ ] **Step 3: Build and test**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunSomeTests` with `["zodlTests/TransactionGuardTests"]` → passes.

- [ ] **Step 4: Commit**

```bash
git add secant/Sources
git commit -m "Move transaction guard into createTransactionFromPCZT LiveKey

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Guard `getTreeState` at the choke point

Preserves the voting round-snapshot guarantee currently enforced at the call site.

**Files:**
- Modify: `secant/Sources/Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift` (line ~335)
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:3311-3314`

- [ ] **Step 1: Wrap the live closure (complete code — it is small)**

Replace:

```swift
            getTreeState: { height in
                try await synchronizer.getTreeState(height: height)
            }
```

with:

```swift
            getTreeState: { height in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    try await synchronizer.getTreeState(height: height)
                }
            }
```

- [ ] **Step 2: Unwrap VotingCoordFlowCoordinator.swift:3311-3314**

Replace:

```swift
        @Dependency(\.transactionGuard) var transactionGuard
        let treeStateBytes = try await transactionGuard.withSubmission {
            try await sdkSynchronizer.getTreeState(snapshotHeight)
        }
```

with:

```swift
        let treeStateBytes = try await sdkSynchronizer.getTreeState(snapshotHeight)
```

- [ ] **Step 3: Build and test**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunSomeTests` with `["zodlTests/VotingCoordFlowCoordinatorTests"]` → passes (voting tests stub `sdkSynchronizer.getTreeState` directly).

- [ ] **Step 4: Commit**

```bash
git add secant/Sources
git commit -m "Move transaction guard into getTreeState LiveKey

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Guard the three voting broadcast closures at the choke point

`submitVoteCommitment`, `submitDelegation`, and `delegateShares`. The last one is what `Voting.delegateSharesWithFallback` (`VotingHelpers.swift:311`) calls internally — wrapping only the first two would leave share delegation unguarded once the call-site wrappers go.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` (closures at lines ~891, ~908, ~927)
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:1892,1939,2911,3483-3491,3606-3609`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowStore.swift:350`

- [ ] **Step 1: Wrap the three live closures**

Same transformation pattern (resolve the guard, wrap the entire existing body, re-indent one level). Heads after the change:

```swift
            submitDelegation: { registration in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let body: [String: Any] = [
```

```swift
            submitVoteCommitment: { bundle, signature in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    // voteRoundId is a hex string; chain expects base64-encoded bytes
                    let roundIdBytes = dataFromHex(bundle.voteRoundId)
```

```swift
            delegateShares: { payloads, roundIdHex, serverURLs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    // Active foreground delivery uses the submission-local server set.
```

Each closure's existing body stays byte-identical inside the wrap. Each ends immediately before the next labeled closure entry — read each range with `XcodeRead` first to find the exact boundaries.

- [ ] **Step 2: Unwrap the five call sites in VotingCoordFlowCoordinator.swift**

Line 1892:

```swift
                        let txResult = try await transactionGuard.withSubmission {
                            try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                        }
```

→

```swift
                        let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
```

Line 1939:

```swift
                        let batchDelegationResult = try await transactionGuard.withSubmission {
                            try await Voting.delegateSharesWithFallback(
                                payloads,
                                roundId: roundId,
                                votingAPI: votingAPI,
                                serverURLs: shareServerURLs
                            )
                        }
```

→

```swift
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
```

Line 2911:

```swift
                    let delegTxResult = try await transactionGuard.withSubmission {
                        try await votingAPI.submitDelegation(registration)
                    }
```

→

```swift
                    let delegTxResult = try await votingAPI.submitDelegation(registration)
```

Lines 3483-3491 (note: also deletes the local dependency declaration):

```swift
        @Dependency(\.transactionGuard) var transactionGuard
        let recoveryResult = try await transactionGuard.withSubmission {
            try await Voting.delegateSharesWithFallback(
                payloads,
                roundId: roundId,
                votingAPI: votingAPI,
                serverURLs: shareServerURLs
            )
        }
```

→

```swift
        let recoveryResult = try await Voting.delegateSharesWithFallback(
            payloads,
            roundId: roundId,
            votingAPI: votingAPI,
            serverURLs: shareServerURLs
        )
```

Lines 3606-3609 (also deletes the local dependency declaration):

```swift
            @Dependency(\.transactionGuard) var transactionGuard
            let delegTxResult = try await transactionGuard.withSubmission {
                try await votingAPI.submitDelegation(registration)
            }
```

→

```swift
            let delegTxResult = try await votingAPI.submitDelegation(registration)
```

- [ ] **Step 3: Delete the store-level dependency**

`VotingCoordFlowStore.swift:350` — delete:

```swift
    @Dependency(\.transactionGuard) var transactionGuard
```

Verify no remaining uses: `XcodeGrep` pattern `transactionGuard` path `secant/secant/Sources/Features/CoordFlows/VotingCoordFlow` → expect zero matches.

- [ ] **Step 4: Build and test**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunSomeTests` with `["zodlTests/VotingCoordFlowCoordinatorTests"]` → passes (voting tests stub `votingAPI` closures directly; the guard never enters the picture in tests).

- [ ] **Step 5: Commit**

```bash
git add secant/Sources
git commit -m "Move transaction guard into voting broadcast LiveKeys

submitVoteCommitment, submitDelegation, and delegateShares acquire the
guard in VotingAPIClientLiveKey; the five voting call-site wrappers and
the store-level guard dependency are removed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Layer-1 verification sweep

**Files:** none (verification only; fix strays if found)

- [ ] **Step 1: Verify the only remaining guard references are the sanctioned ones**

Run `XcodeGrep` pattern `transactionGuard` type `swift` outputMode `content`. Expected remaining app-code references, exactly:
- `Dependencies/TransactionGuard/*` (the guard itself)
- `Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift` (3 wraps)
- `Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` (3 wraps)
- `Dependencies/AutoServerSelection/AutoServerSelectionLiveKey.swift` (`switchIfIdle`)
- `Features/ServerSetup/ServerSetupStore.swift` (`switchWaiting`)
- test files (`zodlTests/*`)

Any other hit is a missed unwrap — fix it using the corresponding pattern from Tasks 1–4.

- [ ] **Step 2: Full test suite**

`mcp__xcode__RunAllTests` → all pass.

- [ ] **Step 3: Commit (only if Step 1 fixed strays)**

```bash
git add secant/Sources
git commit -m "Clean up remaining transaction guard call-site references

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Split `AutoServerSelectionClient` into `findBestServer` / `applySwitch`

Behavior-preserving at this stage: Root's effect calls find-then-apply back to back. The gating arrives in Task 8.

**Files:**
- Test: `zodlTests/UtilTests/AutoServerSelectionClientTests.swift` (full rewrite)
- Modify: `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionInterface.swift`
- Modify: `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionLiveKey.swift`
- Modify: `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionTestKey.swift`
- Modify: `secant/Sources/Features/Root/RootStore.swift:436-438`

- [ ] **Step 1: Rewrite the test file for the new API (red)**

Replace the entire contents of `zodlTests/UtilTests/AutoServerSelectionClientTests.swift` with:

```swift
import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

final class AutoServerSelectionClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var switchedTo: LightWalletEndpoint?
        var persisted: UserPreferencesStorage.ServerConfig?
    }

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    // MARK: - findBestServer

    /// Runs `findBestServer` with controlled dependencies.
    private func runFind(
        flag: Bool?,
        current: LightWalletEndpoint,
        best: LightWalletEndpoint?
    ) async -> LightWalletEndpoint? {
        await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { flag }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in best.map { [$0] } ?? [] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }
    }

    func testFindNoOpWhenFlagOff() async {
        let result = await runFind(flag: false, current: endpoint("zec.rocks"), best: endpoint("na.zec.rocks"))
        XCTAssertNil(result)
    }

    func testFindNilWhenBestEqualsCurrent() async {
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), best: endpoint("zec.rocks"))
        XCTAssertNil(result)
    }

    func testFindNilWhenBenchmarkEmpty() async {
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), best: nil)
        XCTAssertNil(result)
    }

    func testFindReturnsCandidateWhenDifferent() async {
        let result = await runFind(flag: true, current: endpoint("zec.rocks"), best: endpoint("na.zec.rocks"))
        XCTAssertEqual(result?.host, "na.zec.rocks")
    }

    // MARK: - applySwitch

    /// Runs `applySwitch` with controlled dependencies and returns (didSwitch, recorder).
    private func runApply(
        flag: Bool?,
        current: LightWalletEndpoint,
        candidate: LightWalletEndpoint,
        guardBusy: Bool = false
    ) async -> (didSwitch: Bool, recorder: Recorder) {
        let recorder = Recorder()
        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { flag }
            $0.userStoredPreferences.setServer = { recorder.persisted = $0 }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { current }
            $0.sdkSynchronizer.switchToEndpoint = { recorder.switchedTo = $0 }
            $0.transactionGuard = TransactionGuardClient(
                acquire: {},
                tryAcquire: { !guardBusy },
                release: {}
            )
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(candidate)
        }
        return (didSwitch, recorder)
    }

    func testApplySwitchesAndPersists() async {
        let (didSwitch, r) = await runApply(flag: true, current: endpoint("zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(r.switchedTo?.host, "na.zec.rocks")
        XCTAssertEqual(r.persisted?.host, "na.zec.rocks")
        XCTAssertEqual(r.persisted?.isCustom, false)
    }

    func testApplySkipsWhenGuardBusy() async {
        let (didSwitch, r) = await runApply(
            flag: true,
            current: endpoint("zec.rocks"),
            candidate: endpoint("na.zec.rocks"),
            guardBusy: true
        )
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyNoOpWhenFlagTurnedOff() async {
        // The user may flip to Manual while a candidate sits deferred.
        let (didSwitch, r) = await runApply(flag: false, current: endpoint("zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }

    func testApplyNoOpWhenCandidateEqualsCurrent() async {
        // A manual switch may have landed on the candidate while it sat deferred.
        let (didSwitch, r) = await runApply(flag: true, current: endpoint("na.zec.rocks"), candidate: endpoint("na.zec.rocks"))
        XCTAssertFalse(didSwitch)
        XCTAssertNil(r.switchedTo)
        XCTAssertNil(r.persisted)
    }
}
```

- [ ] **Step 2: Verify red**

`mcp__xcode__BuildProject` → **fails**: `findBestServer`/`applySwitch` don't exist yet. That is the expected red state.

- [ ] **Step 3: Rewrite the interface**

Replace the entire contents of `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionInterface.swift` with:

```swift
//
//  AutoServerSelectionInterface.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var autoServerSelection: AutoServerSelectionClient {
        get { self[AutoServerSelectionClient.self] }
        set { self[AutoServerSelectionClient.self] = newValue }
    }
}

@DependencyClient
struct AutoServerSelectionClient {
    /// Benchmarks the known endpoints when Automatic mode is enabled. Returns the best
    /// endpoint when it differs from the current one; nil when Automatic is off, the
    /// benchmark produced nothing, or the best server is already the current one.
    var findBestServer: @Sendable () async -> LightWalletEndpoint? = { nil }
    /// Re-validates (Automatic still on, candidate still differs from current) and applies
    /// the switch under the transaction guard (`switchIfIdle` + timeout), then persists
    /// the new server. Returns true when the switch ran. Never throws; failures are logged.
    var applySwitch: @Sendable (LightWalletEndpoint) async -> Bool = { _ in false }
}

enum AutoServerSelectionConstants {
    // Lightweight startup/foreground benchmark: cheap checks, short fetch.
    static let evaluationTimeoutSeconds = 5.0
    static let blocksToDownload: UInt64 = 1
    static let candidateCount = 3
    /// A deferred switch candidate older than this is dropped instead of applied.
    static let pendingCandidateTTL: TimeInterval = 15 * 60
}
```

- [ ] **Step 4: Rewrite the LiveKey**

Replace the entire contents of `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionLiveKey.swift` with:

```swift
//
//  AutoServerSelectionLiveKey.swift
//  Zashi
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension AutoServerSelectionClient: DependencyKey {
    static let liveValue = AutoServerSelectionClient(
        findBestServer: {
            @Dependency(\.userStoredPreferences) var userStoredPreferences
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer

            guard userStoredPreferences.automaticServerSelection() == true else { return nil }

            let network = zcashSDKEnvironment.network().networkType
            let endpoints = ZcashSDKEnvironment.endpoints(for: network)

            let ranked = await sdkSynchronizer.evaluateBestOf(
                endpoints,
                AutoServerSelectionConstants.evaluationTimeoutSeconds,
                AutoServerSelectionConstants.blocksToDownload,
                AutoServerSelectionConstants.candidateCount,
                network
            )

            guard let best = ranked.first else { return nil }

            let current = zcashSDKEnvironment.endpoint()
            guard best.host != current.host || best.port != current.port else { return nil }

            return best
        },
        applySwitch: { candidate in
            @Dependency(\.userStoredPreferences) var userStoredPreferences
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer
            @Dependency(\.transactionGuard) var transactionGuard

            // Re-validate: the user may have switched to Manual, or changed servers
            // manually, while the benchmark ran or the candidate sat deferred.
            guard userStoredPreferences.automaticServerSelection() == true else { return false }

            let current = zcashSDKEnvironment.endpoint()
            guard candidate.host != current.host || candidate.port != current.port else { return false }

            do {
                let didSwitch = try await transactionGuard.switchIfIdle {
                    try await withTimeout(serverSwitchTimeout) {
                        try await sdkSynchronizer.switchToEndpoint(candidate)
                    }
                }
                guard didSwitch else {
                    LoggerProxy.event("[AutoServerSelection] Switch skipped: transaction guard busy")
                    return false
                }

                try userStoredPreferences.setServer(candidate.serverConfig(isCustom: false))
                return true
            } catch {
                LoggerProxy.error("[AutoServerSelection] Failed to switch endpoint: \(error)")
                return false
            }
        }
    )
}
```

- [ ] **Step 5: Rewrite the TestKey**

Replace the entire contents of `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionTestKey.swift` with:

```swift
//
//  AutoServerSelectionTestKey.swift
//  Zashi
//

import ComposableArchitecture

extension AutoServerSelectionClient: TestDependencyKey {
    static let testValue = AutoServerSelectionClient(
        findBestServer: { nil },
        applySwitch: { _ in false }
    )
}
```

- [ ] **Step 6: Update the only caller (behavior-preserving shim)**

In `secant/Sources/Features/Root/RootStore.swift` (line ~436), replace:

```swift
                return .run { _ in
                    await autoServerSelection.refreshIfEnabled()
                }
```

with:

```swift
                return .run { _ in
                    if let best = await autoServerSelection.findBestServer() {
                        _ = await autoServerSelection.applySwitch(best)
                    }
                }
```

- [ ] **Step 7: Verify green**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunSomeTests` with `["zodlTests/AutoServerSelectionClientTests"]` → all 8 tests pass.

- [ ] **Step 8: Commit**

```bash
git add secant/Sources zodlTests
git commit -m "Split AutoServerSelectionClient into findBestServer/applySwitch

Benchmark and switch become separately callable; applySwitch re-validates
the Automatic preference and the candidate-vs-current difference because
both can change while a candidate is deferred. Root still calls them
back to back — the apply gating lands next.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `Root.State` gating properties + pending candidate

**Files:**
- Test: `zodlTests/UtilTests/AutoServerSelectionClientTests.swift` (append a class)
- Modify: `secant/Sources/Features/Root/RootStore.swift` (State block, lines ~16-113)

- [ ] **Step 1: Append the gating tests (red)**

Append to the end of `zodlTests/UtilTests/AutoServerSelectionClientTests.swift`:

```swift
// MARK: - Root auto-switch gating

final class RootAutoServerGatingTests: XCTestCase {
    func testNoFlowIsNotSensitive() {
        let state = Root.State.initial
        XCTAssertFalse(state.isSensitiveFlowActive)
        XCTAssertTrue(state.canApplyAutoServerSwitch)
    }

    func testSensitivePathCases() {
        var state = Root.State.initial
        let sensitive: [Root.State.Path] = [
            .sendCoordFlow, .scanCoordFlow, .swapAndPayCoordFlow, .transactionsCoordFlow, .settings
        ]
        for path in sensitive {
            state.path = path
            XCTAssertTrue(state.isSensitiveFlowActive, "\(path) must be sensitive")
            XCTAssertFalse(state.canApplyAutoServerSwitch, "\(path) must defer the auto switch")
        }
    }

    func testNonSensitivePathCases() {
        var state = Root.State.initial
        let notSensitive: [Root.State.Path] = [
            .addKeystoneHWWalletCoordFlow, .currencyConversionSetup, .receive,
            .requestZecCoordFlow, .serverSwitch, .torSetup, .walletBackup
        ]
        for path in notSensitive {
            state.path = path
            XCTAssertFalse(state.isSensitiveFlowActive, "\(path) must not be sensitive")
        }
    }

    func testKeystoneSigningBindingIsSensitive() {
        var state = Root.State.initial
        state.signWithKeystoneCoordFlowBinding = true
        XCTAssertTrue(state.isSensitiveFlowActive)
        XCTAssertFalse(state.canApplyAutoServerSwitch)
    }

    func testServerSetupVisibleBlocksApplyButIsNotSensitive() {
        var state = Root.State.initial
        state.serverSetupViewBinding = true
        XCTAssertFalse(state.isSensitiveFlowActive)
        XCTAssertFalse(state.canApplyAutoServerSwitch)
    }

    func testPendingCandidateExpiry() {
        let benchmarkedAt = Date(timeIntervalSince1970: 1_000_000)
        let candidate = Root.State.PendingServerCandidate(
            endpoint: LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0),
            benchmarkedAt: benchmarkedAt
        )
        XCTAssertFalse(candidate.isExpired(now: benchmarkedAt.addingTimeInterval(14 * 60)))
        XCTAssertTrue(candidate.isExpired(now: benchmarkedAt.addingTimeInterval(15 * 60)))
    }
}
```

- [ ] **Step 2: Verify red**

`mcp__xcode__BuildProject` → fails (`isSensitiveFlowActive`, `PendingServerCandidate` undefined).

- [ ] **Step 3: Add the nested struct**

In `secant/Sources/Features/Root/RootStore.swift`, directly after the `Path` enum's closing brace (line ~29), insert:

```swift

        struct PendingServerCandidate {
            let endpoint: LightWalletEndpoint
            let benchmarkedAt: Date

            func isExpired(now: Date) -> Bool {
                now.timeIntervalSince(benchmarkedAt) >= AutoServerSelectionConstants.pendingCandidateTTL
            }
        }
```

- [ ] **Step 4: Add the stored property**

Directly after `var path: Path? = nil` (line ~68), insert:

```swift
        var pendingServerCandidate: PendingServerCandidate?
```

- [ ] **Step 5: Add the computed gates**

Directly after the `isServerSetupVisible` computed property (line ~112), insert:

```swift

        /// True while the user is inside a UI flow that may contain an in-progress payment
        /// or voting sequence. Read live at decision time — never stored anywhere. The
        /// switch is exhaustive on purpose: a new `Path` case must be classified here
        /// before the project compiles.
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

        /// Gate for applying an automatic server switch.
        var canApplyAutoServerSwitch: Bool {
            bgTask == nil && !isServerSetupVisible && !isSensitiveFlowActive
        }
```

- [ ] **Step 6: Verify green**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunSomeTests` with `["zodlTests/RootAutoServerGatingTests"]` → all 6 pass. (This is a newly added class — if RunSomeTests reports it "not found", run `mcp__xcode__RunAllTests` instead.)

- [ ] **Step 7: Commit**

```bash
git add secant/Sources zodlTests
git commit -m "Add Root.State auto-switch gates and pending server candidate

isSensitiveFlowActive reads live navigation state (exhaustive Path
switch — new flows must be classified at compile time); the pending
candidate carries its benchmark timestamp for the 15-minute TTL.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `.autoServerCandidateReady` — gated apply with deferral

**Files:**
- Modify: `secant/Sources/Features/Root/RootStore.swift` (Action enum ~line 202, dependencies ~line 255, reducer case ~line 430)

- [ ] **Step 1: Add the action**

Directly after `case refreshAutomaticServer` (line ~202), insert:

```swift
        case autoServerCandidateReady(LightWalletEndpoint)
```

- [ ] **Step 2: Add the date dependency**

Directly before `@Dependency(\.derivationTool) var derivationTool` (line ~255), insert:

```swift
    @Dependency(\.date) var date
```

- [ ] **Step 3: Replace the refresh case and add the gate case**

Replace the whole `.refreshAutomaticServer` case (currently the gate comment, the `guard`, and the `.run` effect from Task 6 Step 6) with:

```swift
            case .refreshAutomaticServer:
                // Skip during a background task, and while the user is on the Server Setup
                // screen (a manual Save owns that window). The benchmark itself still runs
                // while a sensitive flow is on screen — it is read-only, and a candidate
                // should be ready to apply the moment the user leaves the flow; the apply
                // decision is gated in .autoServerCandidateReady. Correctness against a
                // concurrent manual switch is guaranteed by TransactionGuard regardless:
                // the manual Save uses switchWaiting (waits, then wins) while applySwitch
                // uses switchIfIdle (skips if busy).
                guard state.bgTask == nil, !state.isServerSetupVisible else { return .none }
                return .run { send in
                    if let best = await autoServerSelection.findBestServer() {
                        await send(.autoServerCandidateReady(best))
                    }
                }
                .cancellable(id: state.automaticServerRefreshCancelId, cancelInFlight: true)

            case .autoServerCandidateReady(let candidate):
                guard state.canApplyAutoServerSwitch else {
                    state.pendingServerCandidate = State.PendingServerCandidate(
                        endpoint: candidate,
                        benchmarkedAt: date.now
                    )
                    let gates = "bgTask: \(state.bgTask != nil), serverSetup: \(state.isServerSetupVisible), sensitiveFlow: \(state.isSensitiveFlowActive)"
                    LoggerProxy.event("[AutoServerSelection] Candidate deferred (\(gates))")
                    return .none
                }
                state.pendingServerCandidate = nil
                return .run { _ in
                    _ = await autoServerSelection.applySwitch(candidate)
                }
```

- [ ] **Step 4: Build and test**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunSomeTests` with `["zodlTests/RootAutoServerGatingTests", "zodlTests/AutoServerSelectionClientTests"]` → pass.

- [ ] **Step 5: Commit**

```bash
git add secant/Sources
git commit -m "Gate automatic server switch on live Root navigation state

The benchmark result routes through .autoServerCandidateReady, which
reads canApplyAutoServerSwitch at decision time: apply when clear,
otherwise stash as pendingServerCandidate and log which gate deferred it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Re-feed deferred candidates on flow exit (`onChange`)

**Files:**
- Modify: `secant/Sources/Features/Root/RootStore.swift` (`var body`, line ~392)

- [ ] **Step 1: Restructure `body` without touching the big `Reduce`**

Replace exactly these three lines (line ~392):

```swift
    var body: some Reducer<State, Action> {
        self.core

        Reduce { state, action in
```

with:

```swift
    var body: some Reducer<State, Action> {
        combinedCore
            .onChange(of: \.canApplyAutoServerSwitch) { _, canApply in
                Reduce { state, _ in
                    guard canApply, let pending = state.pendingServerCandidate else { return .none }
                    state.pendingServerCandidate = nil
                    if pending.isExpired(now: date.now) {
                        LoggerProxy.event("[AutoServerSelection] Deferred candidate expired, dropped")
                        return .none
                    }
                    LoggerProxy.event("[AutoServerSelection] Applying deferred candidate after flow exit")
                    return .send(.autoServerCandidateReady(pending.endpoint))
                }
            }
    }

    @ReducerBuilder<State, Action>
    private var combinedCore: some Reducer<State, Action> {
        self.core

        Reduce { state, action in
```

The existing 290-line `Reduce` body and all closing braces stay byte-identical — the old `body` property simply becomes `combinedCore`, and the new `body` wraps it with `onChange`. The `onChange` must wrap **both** `core` and the final `Reduce`, because `serverSetupViewBinding` (an input of `canApplyAutoServerSwitch`) is mutated in the final `Reduce` while `path` and `bgTask` are mutated inside `core`.

- [ ] **Step 2: Build and full test suite**

`mcp__xcode__BuildProject` → succeeds. `mcp__xcode__RunAllTests` → all pass.

- [ ] **Step 3: Commit**

```bash
git add secant/Sources
git commit -m "Re-feed deferred server candidate when the apply gate clears

Root.body observes canApplyAutoServerSwitch; on a false->true transition
a pending candidate re-enters .autoServerCandidateReady (the single
decision point), or is dropped with a log when older than the 15-min TTL.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Documentation, final verification, manual QA notes

**Files:**
- Modify: `CLAUDE.md` (Transaction guard section)
- Modify: `docs/superpowers/specs/2026-06-10-transaction-guard-server-switch-design.md` (status line)

- [ ] **Step 1: Replace the Transaction guard section in CLAUDE.md**

Replace the whole `**Transaction guard (...)** — ...` block (the paragraph plus its three bullets) with:

```markdown
**Transaction guard (`Dependencies/TransactionGuard/`)** — the SDK's `switchTo(endpoint:)` tears down and rebuilds the synchronizer, so it must never overlap a transaction broadcast. A shared, non-reentrant FIFO-mutex actor (`@Dependency(\.transactionGuard)`) enforces this **inside the dependency LiveKeys** — feature code never touches the guard:
- Guarded closures (their `liveValue` acquires the guard internally): `sdkSynchronizer.createProposedTransactions`, `createTransactionFromPCZT`, `getTreeState`, and `votingAPI.submitVoteCommitment`, `submitDelegation`, `delegateShares`. A new broadcast-sensitive dependency closure must take the same wrap in its own LiveKey — never at call sites, and **never nested** (the guard is non-reentrant and will deadlock). `withTimeout(serverSwitchTimeout)` bounds a switch.
- Server switches: the manual Save path uses `switchWaiting { }` (waits for in-flight broadcasts, then wins). The automatic refresh is split into `autoServerSelection.findBestServer()` (benchmark, may run anytime) and `applySwitch` (runs under `switchIfIdle { }`, which skips if a broadcast holds the guard).
- The automatic apply is additionally gated on live navigation state in Root: `.autoServerCandidateReady` defers while `Root.State.canApplyAutoServerSwitch` is false (sensitive flow on screen, Server Setup visible, or a background task), stashing the candidate in `pendingServerCandidate`; an `onChange` in `Root.body` re-feeds it when the gate clears (15-minute TTL). When adding a `Root.State.Path` case, the exhaustive switch in `isSensitiveFlowActive` forces classifying it as sensitive or not.
```

- [ ] **Step 2: Update the spec status**

In `docs/superpowers/specs/2026-06-10-transaction-guard-server-switch-design.md`, change the `**Status:**` line to:

```markdown
**Status:** Implemented (see docs/superpowers/plans/2026-06-10-transaction-guard-server-switch.md)
```

- [ ] **Step 3: Final full suite + lint**

`mcp__xcode__RunAllTests` → all pass. `mcp__xcode__XcodeListNavigatorIssues` → no new warnings introduced by this work (the SwiftLint build phase runs during builds).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs
git commit -m "Document choke-point transaction guard and gated auto-switch

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Manual QA (report results to the user; needs a device/simulator)**

The motivating scenario, observed via console logs:
1. Launch the app (zodl-internal scheme), open Send, start a send.
2. Background the app mid-flow, then foreground it — `refreshAutomaticServer` re-fires.
3. While still inside the Send flow, expect `[AutoServerSelection] Candidate deferred (… sensitiveFlow: true)` once the benchmark completes (requires Automatic server selection ON and the benchmark picking a non-current server — a testnet config with several endpoints makes this likely).
4. Leave the Send flow → expect `[AutoServerSelection] Applying deferred candidate after flow exit` followed by the switch.
5. Sanity: manual Save on Server Setup still switches immediately (switchWaiting path untouched).
```
