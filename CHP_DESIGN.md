# CHP_DESIGN — Coinholder Polling re-enable on Ironwood (iOS)

**The approved design specification.** Sections 1–6 were presented to and approved by Lukas
section-by-section on 2026-08-11. This document is written for a reader with **zero session
context** — a delegated model or an engineer grabbing it cold. Everything needed to build is
here or one pointer away.

| | |
|---|---|
| Ticket | [MOB-1678 — Coinholder polling adoption](https://linear.app/zodl/issue/MOB-1678/coinholder-polling-adoption) |
| Evidence base | `CHP.md` (same directory — the findings ledger: §2.0 ownership, §5.5 crate ladder, §11 panel + R1, §12 Vizor study) |
| Raw inputs | `docs/chp-panel/` (four verbatim independent proposals) |
| Branches | zodl `chp-re-enable` (this branch) · SDK `chp-re-enable` @ `a3823651` (local; push-guarded, Lukas pushes) |
| Execution model | **Orchestrator delegates; cheaper models write the code.** The next artifact after this spec is the implementation plan (writing-plans format: bite-sized tasks, complete code in every step). No coding from this document directly. |
| Status of code | **Zero production code changed so far.** The only landed change is the SDK base-on-main merge (`a3823651`, cargo-check green). |

## 0 · Hard rules (bind every task derived from this spec)

1. **UI is frozen.** No screen, string, flow, or view file changes. All 23 voting screens, all
   297 `coinVote.*` keys, the CoordFlow topology: untouched. If work seems to require a new
   state or string → STOP, hand to product (that is a finding, not a task).
2. **Adapters are semantics-free.** FFI + Swift wrapper + app dependency clients marshal the
   crate; they never add phase tracking, workflow state, or wire mirrors (CHP.md §2.0 rules
   1–3). Any logic beyond marshalling is a defect candidate.
3. **Pin exactly.** `zcash_voting = "=2.0.0-rc.5"` (the `=` matters — cargo otherwise resolves
   1.0.0). Every future re-pin checks the crate CHANGELOG for rollout preconditions first
   (CHP.md §5.5 pin rule v2).
4. **Gates are honest.** Full-log-to-file + real exit codes; never judge by grep. FFI slice
   discipline: `--universal` before any archive or generic-destination build; verify slices
   with `lipo -archs`; verify symbols with `nm -gU`.
5. **Secrets never appear** in code, logs, commits, or reports. The hotkey stored secret is
   key material — same handling as a seed.
6. **Commit conventions:** zodl `[MOB-1466]`-style is NOT used here — CHP work is
   `[MOB-1678] <title>` on zodl (pushes to `origin`), `[#1855] <title>` on the SDK (local
   only; Lukas pushes by hand). Trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
7. **Provenance tags** used throughout: **[LIB]** forced by the 2.0 library · **[BUG]**
   pre-existing defect · **[CEO]** originated by the CEO plan · **[PENDING]** awaiting a named
   decision.

## 1 · The system, in one page (approved Section 1)

A poll asks ZEC holders a question; voting power = shielded balance at a **snapshot height**;
the machinery exists so a holder can prove and vote **without revealing coins or identity**.
All cryptography lives in Valar Group's `zcash_voting` crate — a third-party dependency exactly
like `orchard` (crate authors ≈ the reference-wallet authors; see CHP.md §12.1).

Actors: the app (UI, HTTP, secret storage, timing) · the crate (everything cryptographic +
round state + wire formats) · vote servers (9 operators live, incl. our `zvote.zodl.com`) ·
PIR servers (private lookups) · the vote chain (records votes) · helpers (receive encrypted
vote-shares for tallying).

The journey: **Discover** (pinned static config → dynamic config → signed rounds) →
**Qualify** (notes at snapshot → crate checks Ironwood-only eligibility, packs bundles,
reports weight) → **Register** (crate-generated random **hotkey** = the round's voting
identity, app stores the secret; crate builds + proves the delegation; Keystone slots in
here) → **Vote** (ONE `commitVote` call per proposal → app broadcasts → ONE
`confirmVoteSubmission` call → late-bound share payloads → POST to helpers) → **Results**.

The 2.0 punchline: the crate absorbed what wallet apps used to hand-roll (six-call vote
assembly, wire JSON, recovery) — *"so wallet clients can reuse one implementation instead of
duplicating."* Consequence: **this campaign is a net deletion** (~SDK +215/−360, app +95/−160).

## 2 · Why the old app cannot run on the new library (approved Section 2)

| Area | Today | Now required | Failure mode if untouched |
|---|---|---|---|
| 2.1 Vote pipeline [LIB] | app sequences six calls | one `commitVote` | **does not compile** — the six members no longer exist |
| 2.2 Hotkey container [LIB] | BIP-39 mnemonic stored, seed derived per use | opaque `storedSecret` bytes stored as-is | does not compile; NO data migration (feature never shipped) |
| 2.3 Wire dialect [LIB] | hand-built JSON: `sighash`, `all_enc_shares` | crate-serialized: `tx1_effects` (821-byte blob), per-helper single share | server **400** ("tx1 effects must be 821 bytes, got 0"); privacy regression |
| 2.4 Config schema [LIB] | `pir_layout` not decoded | dynamic config REQUIRES `pir_layout{pir_depth,tier0_layers,tier1_layers}`; live prod already serves `{19,12,7}` | library fail-closes before any PIR query |
| 2.5 Ironwood constant [BUG] | hardcoded NU6 branch `0xC8E7_1055` at `VotingCryptoClientLiveKey.swift:218` | Ironwood `0x37a5_165b`; rc.5 hard-rejects wrong era | every delegation fails at construction post-activation |
| 2.6 Confirmation dance [LIB] | manual `leaf_index` `split(",")` + two-step position writes | one atomic `confirmVoteSubmission` | not broken — deleted as duplication (removes a non-atomic window) |
| 2.7 The switch | `VOTING_ENABLED` defined in NO build config | flag into internal+testnet | n/a — flag-on is the compiler-enumeration gate |

Not changing: screens, strings, flows, TCA structure, `VotingAPIClient` transport role,
storage clients; both test suites return unmodified with the flag.

## 3 · The change specification (approved Section 3) — ladder v2

Execution order: **S1→S6 first** (SDK wave, gates 1–3 green), **then A7's flag flip** — which
IS the enumeration step (gate 4: the compiler lists every remaining old-dialect call site) —
**then A1–A6 burn that list to zero**, then gates 5–7. Each change below: exact target, shape,
acceptance.

### SDK workstream (repo: `zcash-swift-wallet-sdk`, branch `chp-re-enable`, base `a3823651`)

**S1 · Foundation merge — DONE.** `a3823651` = team stack + origin/main (#1855 voting restore,
rc.3, cargo-check green). Do not re-derive; build on it. If Michal's branches move underneath,
re-merge with the same policy (voting→main, migration/slipstream→ours, librustzcash pin→ours
`13ce6c4e` — main's `41a1e17c` provably cannot resolve here; see CHP.md §11.1).

**S2 · Bump to rc.5 + PIR geometry [LIB].**
- `Cargo.toml:105`: `zcash_voting = { version = "2.0.0-rc.3" }` → `"=2.0.0-rc.5"`; `cargo update -p zcash_voting`.
- Known break (compiler-verified in advance): `rust/src/voting/delegation.rs:419` —
  `connect_pir_client(&pir_url)` must take an explicit `PirLayout`; call sites `:461`, `:542`.
  Thread the three layout fields from the round's resolved config through the FFI struct that
  feeds `precompute_delegation_pir` / `build_and_prove_delegation` (Android's
  `pir_layout_from_jni` + 3-field struct is the recipe — PR zcash/zcash-android-wallet-sdk#2157).
- Acceptance: `cargo check` real exit 0; `Cargo.lock` shows zcash_voting 2.0.0-rc.5,
  pir-client/pir-types 0.4.0-rc.4/0.3.0-rc.4, and STILL exactly one librustzcash rev (`13ce6c4e`).

**S3 · De-mirror the wire [LIB, simplification].**
- Retire `rust/src/voting/json.rs` (359 lines of hand-mirrored wire structs). FFI functions
  marshal `zcash_voting::wire::*` via the crate's own serialization (`to_json`,
  `VoteShareWire::with_late_bound`). Reference proof this is achievable: Vizor keeps zero wire
  DTOs (CHP.md §12.1).
- This makes 2.3's `tx1_effects` + single-share correctness **automatic** — do NOT hand-add
  those fields anywhere.
- Same sweep: audit and remove any FFI phase-flattening that re-derives state the crate owns
  (CHP.md §12.2 D1).
- Acceptance: `git grep -c 'all_enc_shares\|sighash' rust/src/voting/` → only crate-type
  passthroughs remain; cargo check green; OfflineTests voting suite green **unmodified**.

**S4 · Two thin passthroughs [LIB].** New FFI + Swift surface, zero logic:
- `zcashlc_voting_confirm_vote_submission(...)` → `zcash_voting::confirmation::confirm_vote_submission`
  (crate fn parses the confirmation events, records tx hash, advances VAN, records VC position
  in ONE DB transaction; returns both positions). ~50 Rust + ~25 Swift.
- `zcashlc_voting_recover_wire_json(...)` → `zcash_voting::share::recover_wire_json(...,
  vc_tree_position, submit_at)` (late-binds the confirmed position into helper payloads; no
  second commit). ~40 Rust + ~20 Swift.
- Both exist at rc.5: `confirmation.rs:119`, `share.rs:192`. Follow the existing wrapper
  conventions in `Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift` (handle
  lock, error surface, `decodeJSON`).
- After landing: open upstream PRs to `zcash/zcash-swift-wallet-sdk` main (Android precedent).
- Acceptance: symbols present in `nm -gU`; Swift wrappers compile; one offline test per
  wrapper following the existing suite's DB-fixture pattern.

**S5 · Publicize the Ironwood constant [BUG-support].** `nu63ConsensusBranchID`
(`0x37a5_165b`, currently internal on the server-validation path) becomes a public SDK
constant so the app can never re-hardcode an era. ~2 lines + doc comment.

**S6 · FFI rebuild.** FFI boundary changed ⇒ full `./Scripts/init-local-ffi.sh` (per repo
CLAUDE.md), `--universal` before any archive/generic build. Gate:
`nm -gU <built libzcashlc> | grep -c 'zcashlc_voting_commit_vote\|confirm_vote_submission\|recover_wire_json'` = 3.
Budget the halo2 voting-circuits build tax (Android CI went 30→60 min).

### App workstream (repo: `zodl-ios`, branch `chp-re-enable`)

**A1 · Pipeline collapse [LIB], net −120.** Disposition of the six dead client members
(`secant/Sources/Dependencies/VotingCryptoClient/`):

| Old member | Disposition |
|---|---|
| `buildVoteCommitment`, `signCastVote`, `buildSharePayloads` | → ONE `commitVote(round, bundle, hotkeyStoredSecret, proposal, choice, numOptions, vcTreePosition, vanWitness, singleShare, progress:)` — same `progress:` closure keeps `RoundSession.preparingProof`/`.sendingShares` phases and every screen untouched |
| `encryptShares` | **delete** — zero consumers in the app |
| `decomposeWeight` | **delete** — zero consumers; removed from crate, no replacement |
| `storeCommitmentBundle` | **delete** — persistence is internal to `commitVote` |
| `getDelegationSubmissionWithKeystoneSig` | absent in the new wrapper; Keystone signatures ride `storeKeystoneSignature` + the plain submission accessor — final wiring confirmed at the A7 compile-enumeration gate (do not guess; read the compiler) |

Rewire regions: `VotingCoordFlowCoordinator.swift` ~`:1872-1930` (main path) + recovery paths
~`:2171` and ~`:3463`. **No compatibility shim faking the old shape** — `commitVote` is
idempotent per (round, bundle, proposal); a shim would silently return stale data.

**A2 · The vote sequence [LIB], net −40.** The canonical per-proposal sequence (CHP.md §11.9
as amended by §12 — third-time-confirmed physics):

1. `commitVote(..., voteCommitmentTreePosition: 0, ...)` — provisional; do NOT send the
   returned payloads to helpers.
2. Broadcast the cast-vote tx.
3. `markVoteSubmitted` (tx hash).
4. Await confirmation → `confirmVoteSubmission(txHash, eventsJson)` — one atomic call, fed the
   confirmation-events JSON the app's existing confirmation polling already fetches (same input
   the reference wallet passes); delete the app's `leaf_index` string parsing entirely.
5. `recoverWireJson(confirmedPosition, submitAt)` → the corrected helper payloads.
6. POST payloads to helpers; record/confirm share delegations (existing members).

Trap T3 (stands): between steps 1 and 4 every position consumer in the crate hard-errors
("refusing to assume position 0") — **surface those errors, never swallow**; they are correct
behavior. Traps T1/T2 from earlier drafts are void (no replay-commit exists anymore).

**A3 · Hotkey container [LIB], ~60 lines.** `StoredVotingHotkey`: `seedPhrase: String` →
`storedSecret: Data`; bump its existing `version` field; delete the 4 `mnemonic.toSeed`
derivation sites (coordinator `:1770/:2043/:2629/:2835`); thread the secret through the
~13 coordinator + ~12 LiveKey references. NO migration code — treat any old-format record as
"no hotkey" (none exist in the wild). Model note for reviewers: the app already generated
random material; only the container changes (CHP.md §7.5 amended, §12.2 D4).

**A4 · Branch-ID fix [BUG], ~1 line.** `VotingCryptoClientLiveKey.swift:218`: replace the
hardcoded `0xC8E7_1055` with the S5 public constant.

**A5 · Config decode [LIB], ~30 lines.** Add `pirLayout` (3 `UInt32`) to
`VotingServiceConfig`, plumb to the SDK PIR entry points. `PirSnapshotResolver` already parses
`pir_depth` — half exists. Live prod serves `{19,12,7}` today.

**A6 · Static-config re-pin [LIB], ~2 lines.** `StaticVotingConfig.swift:12`: move the pinned
fallback from the commit-pinned raw.githubusercontent URL to the live checksummed
`https://voting.valargroup.org/prod/static-voting-config.json?checksum=sha256:…` (mirror
Android's). The signing-KEY custody behind future re-pins is CEO ledger item 5 — org decision,
not code.

**A7 · The flag, internal+testnet ONLY (Q4, confirmed).** Add `VOTING_ENABLED` to
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` for the `zodl-internal` and `zodl-testnet`
configurations in `secant.xcodeproj/project.pbxproj`. `zodl-production` stays off (see §5).
Flag-on is also the enumeration gate: the compiler's error list is the authoritative remaining
work list — burn it to zero, then run the suites.

## 4 · The CEO ledger (approved Section 4)

The CEO plan (`polling-plan-summary-for-validation.md`) originates almost no engineering — its
commitVote/hotkey items *describe* [LIB] work. What it originates is decisions/process:

| CEO item | Status | Android did it? | Impact here |
|---|---|---|---|
| 1 · Endorsement decision | **[PENDING product+partnerships]** — evidence: concept absent from crate AND reference wallet; silent "No polls" on both mobile apps | **No** (silent empty-set) | gates production flag; "drop the gate" now has reference precedent |
| 2 · Kris 1-hour sign-off | served by **§7 of this document** | n/a | none |
| 3 · Drafts via Claude | this campaign (iOS half) | shipped (their PRs) | none |
| 4 · QA prep (Harry) | not started; **our 3 additions**: test round must serve `pir_layout`; only ONE prod round exists → needs testnet round or crate local-PIR harness (#166); `zvote.zodl.com` is ours | n/a | inputs handed over |
| 5 · Signing-key owner | **[PENDING org]** — code side is A6 (trivial) | URL re-pinned; custody unanswered | blocked on a name |
| 6 · rc.1→rc.2 + parity check (Danny) | **superseded**: rc.1 never published, server requires rc.4+ wire, target = rc.5; parity gap was Kotlin-side and merged | partially | Danny gets a one-paragraph corrected brief |

CEO assumptions scored: "SDK main complete" ✅ (with rc.5 delta named) · "rc.1→rc.2 additive"
❌ refuted (rc.4 is wire-breaking — hence rc.5 target) · "5 QA days sufficient" helped by
net-deletion scope + returning suites + our own vote server · "QA on pre-review build OK" even
more bounded than assumed (this spec pre-blesses the crypto-review surface).

## 5 · Rollout & gates (approved Section 5, Q4 confirmed)

Flag: internal+testnet ON from first build; production OFF until (a) green testnet E2E round,
(b) internal soak, (c) product rulings Q6 + R5. Rationale: blast radius, not confidence.

**Gate ladder (every step has a pass/fail; full-log + real exit codes):**

1. `cargo check` (SDK root) — exit 0 on the rc.5 graph.
2. Full FFI rebuild; `lipo -archs` sane; `nm -gU` shows the 3 voting symbols (S6 gate).
3. SDK: `swift build` + `swift test --filter OfflineTests` — voting suite green **unmodified**.
4. Flag on → app compile-error list → burn to zero (A1–A6 close it).
5. App voting tests return (they are flag-gated; zero porting).
6. Standing full gates: `xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
   and `xcodebuild build -scheme zodl-testnet -destination 'generic/platform=iOS'`.
7. **Testnet E2E round** (the exit gate; mirrors Android's acceptance + our matrix):
   multi-bundle delegation (software AND Keystone — rc.5's memo fix is the hardware-display
   reason), vote, confirmation, shares; crash-recovery mid-flow; share resubmission.
   macOS target: rides the same flag; smoke pass only in QA week.

**Rollback:** flag off = feature compiles out; SDK changes additive/upstreamable; zero data
migrations. Worst case = revert two build-setting lines.

**Calendar:** fits the CEO plan's Aug 17–21 review-and-land week with slack (2–4 focused
delegated days, net-deletion scope); this spec is what turns the Aug 24–25 crypto review into
a diff-check.

## 6 · Pending decisions & debt (approved Section 6)

Decisions: **Q6** endorsement (product+partnerships; gates production) · **R5** hotkey-loss
messaging (product; gates production; all three wallets currently silent) · **Q3** security
posture — no Tor/pinning on vote+PIR traffic, unsigned endpoint lists, plaintext drafts
(product+security; their call whether it gates) · **Q5** server-side `tree_position`
cross-check (one Valar question; documentation only) · **CEO-5** signing-key owner (org).

Debt register (recorded, deferred): `resume_plan` adoption (reference-wallet backbone,
25+ sites; would restructure the frozen flow) · phase-2 crate config resolution (deletes the
app's duplicated Ed25519 `RoundAuthenticator`, makes `pir_layout` crate-owned; ~1–1.5 days,
after flag-green, before mainnet) · upstream PRs for S4 · `commit_batch` (available, unneeded).

## 7 · Kris sign-off chapter (CEO item 2 — the one-hour review packet)

Kris: the two areas your review was scoped to, with the decisions and their evidence:

1. **commitVote rework.** The app adopts the crate's one-shot flow verbatim; the six-call
   pipeline is deleted, not shimmed (idempotency makes a shim silently stale). The
   vote-position question is settled as W2: position is late-bound metadata (never a circuit
   input — exhaustively swept: no reference in zkp1/zkp2/precompute/action, the sighash, or
   the share nullifier), commit stores recovery JSON only, and the sequence in §3/A2 uses your
   crate's own `confirm_vote_submission` (atomic) + `recover_wire_json` (late-bind), exactly
   as the Vizor reference does. Three independent derivations agree (CHP.md §11.9, §12.2 D3).
2. **Hotkey storage model.** The app was already random-material + app-owned-keychain; the
   change is container-only (mnemonic → `storedSecret` bytes), no migration exists to write
   (feature never shipped). Non-recoverability messaging is escalated to product (R5), not
   engineered silently.
3. **Your open question from the plan — "raw backend or convenience layer?"** Answer: raw,
   thin passthroughs, no convenience layer. Grounds: the no-semantics rule (the one place a
   zodl layer added semantics is the exact cause of Android's multi-bundle bug), and the
   reference wallet's zero-DTO architecture, which made rc.4's wire changes test-only diffs.
4. **New SDK surface for your review:** the two S4 passthroughs (both map 1:1 to public crate
   functions at rc.5: `confirmation.rs:119`, `share.rs:192`) and the S5 public constant.
   Upstream PRs follow landing.

Diff-check hint: every code change traces to exactly one lettered item in §3; anything in a
diff that doesn't is out of spec.

## 8 · Handoff protocol (how this gets built by anyone, anytime)

1. **Next artifact:** an implementation plan in writing-plans format — bite-sized tasks
   (2–5 min steps), exact paths, complete code in every step, exact commands with expected
   output, TDD where testable, one commit per task. A task must be executable by a
   Sonnet-class model with NO context beyond the task text + this spec.
2. **Delegation model:** orchestrator (any) dispatches one task per delegate; Sonnet default,
   Opus for S3 (the de-mirror sweep) and S4 (FFI boundary). The orchestrator reviews diffs
   against §3's acceptance criteria and runs gates via delegates. The orchestrator authors no
   code.
3. **Execution order:** S2→S3→S4→S5 (one SDK wave, then S6 rebuild) → A1–A6 (after gate 4's
   enumeration) → A7 finalize → gates 5–7.
4. **Report format per task:** what changed (files+lines), gate output tails + real exit
   codes, deviations from spec (if any — a deviation is a finding to surface, not to absorb).
5. **When the world moves** (crate ships rc.6, Michal's branches advance, Android re-targets
   PRs): re-check CHP.md §5.5's pin rule and §11.1's merge policy BEFORE continuing; update
   CHP.md's log with what moved.

— End of specification. —
