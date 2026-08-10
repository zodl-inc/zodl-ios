# CHP — Coinholder Polling

Working document for re-enabling Coinholder Polling (CHP) on iOS, on the Ironwood stack.

Everything here is either **pinned fact** (a hash, a line of code, a verified state) or **an
explicitly labelled open question**. Nothing is inferred and left unmarked. If a row says
"verified", it was read out of the repo or the GitHub API at the time stamped on it — not
remembered.

**Status:** planning campaign live — base-on-main merge landed (SDK `a3823651`, §11.1), design
thesis ratified (§7.5), four-proposal panel adjudicated (§11). No production code changed; docs
and the validated merge only.
**Branches:** `chp-re-enable` in both zodl-ios and zcash-swift-wallet-sdk.
**Ticket:** [MOB-1678 — Coinholder polling adoption](https://linear.app/zodl/issue/MOB-1678/coinholder-polling-adoption)
(the umbrella item; dominik's Android PRs in §6 are the Android half of the same ticket).
**Date opened:** 2026-08-10.

---

## §0 · Why this document exists

Michal is merging in parallel, and `main` moved under us while we were doing migration work.
The single most expensive failure mode on this task is *not knowing which generation of code a
given symptom belongs to* — the voting crate alone has moved through five release candidates in
eleven days, across two GitHub orgs.

So before touching anything: pin the floor. §1 is that floor. Every later claim in this document
is relative to it.

---

## §1 · The starting point (pinned 2026-08-10)

### The four layers

| Layer | Repo | Branch | HEAD |
|---|---|---|---|
| App | `zodl-inc/zodl-ios` | `chp-re-enable` (cut from `migration/gardening-test`) | `fea8d600e8099cdd21f902ddd42a182f58e5f8fd` |
| SDK — Swift + Rust FFI | `zcash/zcash-swift-wallet-sdk` | `chp-re-enable` (cut from `fable/gardening-test`) | `93a11081bba6fa195e362801ccd65f5f91930870` |
| Wallet core | `zcash/librustzcash` | pinned rev (11 crates via `[patch.crates-io]`) | `13ce6c4ef57a6c7e8837d797d85112ae16ac7455` |
| Voting core | — | **not in the graph** | dependency commented out |

Both `chp-re-enable` branches sit at exactly the commit Lukas has been building from. They are
not cut from `main`; see §4.3 for why, and for the decision that still has to be made about it.

### Position relative to upstream

| | ahead of `origin/main` | behind `origin/main` | `origin/main` tip |
|---|---|---|---|
| zodl-ios | 244 | **0** | `512fa1c8` (2026-08-01, Michal, merge #1966 release/3.8.1) |
| SDK | 277 | **12** | `468d1e9f` (2026-08-03, nuttycom, merge #1914 maint-v2.8.x) |

Those 12 SDK commits are the whole story of this task — see §4.

### FFI build mode

`LocalPackages/` exists ⇒ **local FFI mode**. `libzcashlc.xcframework` carries three slices:
`ios-arm64`, `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64`. The Rust compiles from the
librustzcash rev above. Turning voting back on is a **Rust-graph change**, so it will require a
full FFI rebuild, not just a Swift build.

### Working-tree state at pin time

- zodl-ios: one modified file, `secant.xcodeproj/project.pbxproj` — `CURRENT_PROJECT_VERSION`
  10 → 11 across four configs. That is Lukas's Xcode build-number bump, not our change. Left
  uncommitted deliberately.
- SDK: clean.

### §1.5 · Movement since the pin — the same day (blind re-verification, 2026-08-10 ~17:30 UTC)

The pin in §1 held for hours, not days. A blind re-derivation (two delegated agents, neither
shown this document) found the world moved the same afternoon:

**SDK `origin/main` absorbed the ironwood-slipstream line.** PR #1954 (`merge/ironwood-slipstream`,
nuttycom, merged 2026-08-10) moved main `468d1e9f` → `a1234039`. That merge carries the lineage our
own stack descends from, so our relation to main collapsed from **277 ahead / 12 behind** to
**35 ahead / 17 behind** (merge-base `ab4685d2` → `9d0277de`). The 17 we are behind now contain
exactly what this task wants from upstream: the #1855 voting-restore trio, the rc.3 adoption,
`0076d56a` (slipstream dependency pin shifted to `slipstream-internal`), and the Keystone
batch-signing redaction pin `1a544bf4`.

**Main's voting pin moved rc.1 → rc.3, and the git patch is gone.** `origin/main` Cargo.toml now
reads `zcash_voting = { version = "2.0.0-rc.3" }` resolving from crates.io, with **no**
`[patch.crates-io]` zcash_voting entry — §4.2's wiring description is superseded. Main's
librustzcash patch rev also moved to `41a1e17c…` (ours: `13ce6c4e…`), so absorbing main is an
FFI-generation move plus a full rebuild, not a plain merge.

**The ported Swift wrapper drifted within hours.** `commitVote` on main no longer takes
`networkId:` (the rc.3 adoption derives it internally); the wrapper is now 1,940 LOC. Diff work
must target main-of-today, not main-of-this-morning.

**crates.io is the canonical channel — and rc.1 was never on it.** Published: 0.11.0 (Jun 3),
1.0.0 (Jun 7, max stable), 2.0.0-rc.2 (Jul 28), rc.3 (Aug 5), rc.4 (Aug 7), rc.5 (Aug 8,
max_version). 2.0.0-rc.1 was **never published** — which is *why* the old wiring needed a git
pin, and why §5's "which git ref?" framing was partly malformed: for published rcs the
distribution is crates.io, and the zodl-inc/valargroup fork divergence stops mattering unless we
need unreleased commits.

**Android moved today too.** zodl-android #2408 (maint/v3.9.x → main) MERGED; #2406/#2157 still
OPEN on maint bases and still growing (#2157 now 14 files, +505/−124); no main-targeted successor
PRs exist yet in either Android repo.

**valargroup is still hot.** Since rc.5: `main`@`a7a8a45` (#168 "bound vote tree sync", Aug 8)
and `fix/bind-round-auth-to-round-id`@`f2f7c0a` (**Aug 10**, "Bind the advertised PIR layout into
round-auth v2 signatures") — an rc.6 era is forming. The plan must carry the pin as a rule
("newest published rc at pin time, floor rc.3") with a re-check gate, not a frozen number.

**Consequences for the open items:** D1 (§4.3) became cheap — 17 commits, exactly the ones we
want. Q1 reshapes from "ask the crate owners which git ref" into a decision rule we can own.
Q2 largely dissolves for published versions. One §2.1 arithmetic error found and fixed (48 files,
not 47) — the only authoring error the blind pass surfaced.

---

## §2 · Code overview — the anatomy of CHP

### §2.0 · Ownership — whose code is this? (ruled 2026-08-10)

**The voting core is 100% a third-party dependency: Valar Group's `zcash_voting` crate.** We own
zero cryptography. Home repo `valargroup/zcash_voting`; `zodl-inc/zcash_voting` is only our
pin-target fork, and since #1954 the SDK resolves the crate from crates.io like any other
dependency. Everything the crate does — Halo 2 delegation + vote-commitment proofs, ElGamal share
encryption, governance PCZT construction, Merkle/VAN witnesses, note eligibility, the voting
SQLite DB, PIR fetch and commitment-tree sync — is theirs, exactly as `orchard` or `librustzcash`
are theirs.

What is OURS is adapters and presentation: the C FFI (§2.3, thin marshalling), the Swift wrapper
(§2.2, typed projection), and the app (§2.1 — UI flows, vote-server REST client,
config/endorsement verification, draft storage, hotkey keychain storage).

The dependency is **two-level**: Valar's *crate* at compile time and Valar's *servers* at runtime
(vote-chain server, PIR endpoints, commitment-tree service). The wire protocol is theirs too —
which is why the crate pin is forced by server behavior (§6.1's `tx1_effects` 400), not by taste.

**Design consequences, binding for the spec:**

1. **Their API is the contract** — and more so in 2.0 than in v1: the vote-assembly logic our
   layers used to hold (the six-call pipeline) was moved *into* the crate at our own request
   (dominik: "they moved some logic inside voting rust crate as we requested earlier from core
   team"). Our three layers are designed as a faithful, semantics-free projection of the crate's
   API into Swift and SwiftUI.
2. **No semantics in the adapters.** The one known place our layer added logic the crate never
   does — Android's round-phase writes during PCZT construction (§6.2) — is precisely what broke
   multi-bundle rounds. Any FFI/SDK addition beyond marshalling is a defect candidate by default.

Four layers, top to bottom. Sizes are current, on our branch.

### 2.1 App — `zodl-ios`

**15,071 lines of Swift across 48 files**, plus 5 test files and **297 `coinVote.*` string keys**
in the catalog.

| Area | Path | What it is |
|---|---|---|
| Feature screens | `secant/Sources/Features/Voting/` (23 files) | Proposal list/detail, results, tallying, confirm-submission, delegation signing, ineligible, no-rounds, wallet-syncing, error surfaces, chain-config settings |
| Flow coordinator | `secant/Sources/Features/CoordFlows/VotingCoordFlow/` (4 files) | `VotingCoordFlowCoordinator`, `…Store`, `…View`, `RoundSession` |
| Network client | `secant/Sources/Dependencies/VotingAPIClient/` (5 files) | Vote-server + PIR HTTP, `RoundAuthenticator` (Ed25519 round signatures), `ServerHealthTracker` |
| Crypto client | `secant/Sources/Dependencies/VotingCryptoClient/` (3 files) | The bridge to the SDK. Calls `VotingRustBackend` — **this is where the app touches the FFI** |
| Storage | `secant/Sources/Dependencies/VotingStorageClient/` (3 files) | Drafts + vote records |
| Metadata | `secant/Sources/Dependencies/VotingMetadataProvider/` (3 files) | Round metadata cache |
| Models | `secant/Sources/Dependencies/VotingModels/` (7 files) | `Proposal`, `VotingRound`, `VoteChoice`, `StaticVotingConfig`, `VotingServiceConfig`, `VotingSessionState` |
| Keychain | `secant/Sources/Dependencies/WalletStorage/StoredVotingHotkey.swift` | Per-round hotkey (a full BIP-39 mnemonic — see §7.3) |

Entry point: one row in Settings (`SettingsView.swift:37-44` → `.coinholderPollingTapped`),
presenting `VotingCoordFlow` as a `fullScreenCover`.

Note the shape has changed since the May review: the old monolithic `VotingStore` +
`VotingStore+Delegation/Session/Submission/Navigation/Helpers` split has been refactored into the
CoordFlow architecture above. **The May-15 review at
`~/Dev/Xcode/GitHub/LukasKorba/coinholder-polling-review.md` describes files that no longer
exist** — its *findings* mostly still apply, its *line references* do not. Treat it as a
findings list, not a map.

### 2.2 SDK Swift — `zcash-swift-wallet-sdk`

**Four files, all currently absent from our branch:**

```
Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift
Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift
Sources/ZcashLightClientKit/Rust/Voting/VotingConstants.swift
Sources/ZcashLightClientKit/Rust/Voting/PirSnapshotResolver.swift
```

This is the typed Swift wrapper over the `zcashlc_voting_*` C symbols. The app calls it directly
(`VotingCryptoClientLiveKey` imports `ZcashLightClientKit` and calls `VotingRustBackend.…`), so
its absence is what makes the app's voting code unbuildable even if you flip the app's flag.

### 2.3 SDK Rust (the FFI) — `rust/src/voting*`

**4,469 lines across 16 files, exposing 66 `extern "C"` functions.** All present on disk, none
compiled (see §3.3).

| File | Surface |
|---|---|
| `voting.rs` | DB open/free, wallet id, hotkey generation, bundle setup, PCZT build, tree state, note witnesses, PIR precompute, **`zcashlc_voting_build_and_prove_delegation`**, delegation submission (plain + Keystone-signed), VAN position, PIR proof validation |
| `voting/rounds.rs` | init round, round state, list rounds, votes, clear round, delete skipped bundles |
| `voting/recovery.rs` | tx-hash store/read (delegation + vote), commitment bundle, VC position, **`recover_committed_vote`**, Keystone signature store/read, clear recovery state |
| `voting/share_tracking.rs` | share nullifier, scheduled submit-at, record/read share delegations, unconfirmed, mark confirmed, sent servers |
| `voting/tree.rs` | sync vote tree, generate VAN witness, reset tree client |
| `voting/ffi_types.rs` | the free-functions for returned structs |
| `voting/{notes,delegation,vote,db,json,helpers,util,progress,constants,test_helpers}.rs` | supporting |

### 2.4 Voting core — the `zcash_voting` crate

Not a file in our repos: an external crate. **This is the layer that moved**, and the layer
dominik's Slack message is about ("they moved some logic inside voting rust crate as we requested
earlier from core team"). See §5 — it is the most volatile thing in this whole task.

---

## §3 · The three off-switches

CHP is off in three independent places. All three must flip. Verified 2026-08-10 on our branch.

### 3.1 App — `#if VOTING_ENABLED`, and the flag is defined nowhere

56 Swift files carry `#if VOTING_ENABLED`. The flag appears in **zero** `.pbxproj`,
`.xcconfig`, or `.xcscheme` entries — `SWIFT_ACTIVE_COMPILATION_CONDITIONS` across all 11 build
configurations lists only `DEBUG`, `UNREDACTED`, `SECANT_TESTNET`, `SECANT_MAINNET`,
`SECANT_DISTRIB`. So the entire feature — screens, coordinator, clients, models, tests — is
compiled out of every configuration.

`origin/main` of zodl-ios also has zero. **iOS has not re-enabled anything; only the SDK side
moved.**

### 3.2 SDK Swift — the wrapper was deleted

`248d46f9` (2026-07-25, Danny Willems) — *"[#1806] Remove the Swift voting surface (voting
disabled on 2.5.x)"* — deleted the four files in §2.2. That commit **is** an ancestor of our HEAD.

### 3.3 SDK Rust — cfg gate + commented-out dependency

`rust/src/lib.rs:107-111`:

```rust
// Voting is gated off on this line: the `zcash_voting` dependency is commented out in
// Cargo.toml (see there), so the module and its `zcashlc_voting_*` symbols are not compiled.
// The sources are retained so the surface can be reinstated by re-enabling the dependency.
#[cfg(zcash_voting)]
mod voting;
```

`zcash_voting` is never set as a cfg, so `mod voting` is dead. Three matching stanzas in
`Cargo.toml` are commented out:

- `:107` — `# zcash_voting = { version = "2.0.0-rc.1", optional = true }` (and `# zeroize = "1"`)
- `:137` — `#voting = ["dep:zcash_voting"]` in `[features]`
- `:186` — `# zcash_voting = { git = "https://github.com/valargroup/zcash_voting.git", rev = "e53e74487d31ad0f5713580fb2f0222b53ae9db8" }` in `[patch.crates-io]`

`[lints.rust] unexpected_cfgs` explicitly allow-lists `cfg(zcash_voting)` so the dead gate does
not warn.

**Note the stale org in that commented pin:** `valargroup`. The crate has since moved — §5.

---

## §4 · What upstream already did — the #1855 restore

This is the single most important fact on the task, and it matches nuttycom's Slack message
verbatim ("main itself has polling re-enabled already").

### 4.1 The three commits

All on `origin/main` of the SDK. **None are ancestors of our HEAD.**

| Commit | Date | Author | Subject |
|---|---|---|---|
| `7d8e9b15` | 2026-07-26 | nuttycom | `[#1855] Reinstate the voting module on the Ironwood stack` |
| `1e8c247e` | 2026-07-26 | nuttycom | `[#1855] Restore the Swift voting surface against the ported FFI` |
| `a250cb76` | 2026-07-26 | nuttycom | `[#1855] Document the voting reinstatement and its breaking changes` |

Note the first one's subject: **"on the Ironwood stack"**. The reinstatement was done *against*
Ironwood, not before it. That is the opposite of what "get polling working again with Ironwood"
would suggest if we assumed we were starting from scratch.

### 4.2 What main's wiring looks like

> **Superseded the same day — see §1.5.** After PR #1954, main pins `zcash_voting = "2.0.0-rc.3"`
> from crates.io and the `[patch.crates-io]` zcash_voting stanza below no longer exists. The
> morning snapshot is kept for the record.

Read out of `origin/main` 2026-08-10 (morning):

```rust
// rust/src/lib.rs:96 — no cfg, no feature
mod voting;
```

```toml
# Cargo.toml — unconditional, not optional, no feature gate
zcash_voting = { version = "2.0.0-rc.1" }
zcash_keys   = { version = "0.16", features = ["orchard"] }
incrementalmerkletree = { version = "0.8", default-features = false }
zeroize = "1"

[patch.crates-io]
zcash_voting = { git = "https://github.com/zodl-inc/zcash_voting", rev = "3c9900e56081966b74dd57a0c880c782f4f602bb" }
```

And all four Swift files in `Sources/ZcashLightClientKit/Rust/Voting/` are present.

Two things to notice. First, the `voting` **feature is gone** — voting is now an unconditional
dependency, not an opt-in. Second, the crate's home moved **`valargroup` → `zodl-inc`**.

### 4.3 The 12 commits we are behind — and the decision they force

```
468d1e9f  Merge pull request #1914 from zcash/merge/maint-v2.8.x
4104d332  Merge remote-tracking branch 'upstream/maint/v2.8.x' into merge/maint-v2.8.x
f51ed74a  Merge pull request #1854 from zcash/merge/maint-2.7.x
fb21631e  Merge branch 'maint/v2.8.x' into merge/maint-2.7.x
172b3b1d  Merge branch 'release/v2.8.0-rc.1' into merge/maint-2.7.x
a250cb76  [#1855] Document the voting reinstatement and its breaking changes   ← restore
1e8c247e  [#1855] Restore the Swift voting surface against the ported FFI      ← restore
7d8e9b15  [#1855] Reinstate the voting module on the Ironwood stack            ← restore
52416cab  Keep design docs and plans in a gitignored .plans directory
ed8ec4f9  Merge branch 'maint/v2.7.x' into merge/maint-2.7.x
769809a2  Merge pull request #1832 from pacu/pacu/1831-agents-md
70716b34  [#1831] Add AGENTS.md with security-critical API rules
```

Merge base: `ab4685d2` (2026-07-29).

**[DECISION NEEDED — D1]** nuttycom's guidance is *"chp work should be based on main"*. Taken
literally that means cutting from `origin/main`, which would drop the 277 SDK / 244 zodl commits
of migration work Lukas is currently building and shipping from. That cannot be what's meant for
us — his message was addressed to dominik, whose Android branch was based on a `maint/` line.

The equivalent-in-spirit move for our side is: **merge `origin/main` forward into
`chp-re-enable`**, which brings the three #1855 commits (plus 9 merge/doc commits) onto our
stack. That is what I'd recommend, and it is what the plan in §8 assumes. It needs Lukas's word
before I do it, because it is the first irreversible-ish step and it touches the branch he
builds from.

---

## §5 · The crate ladder — the volatile layer

> **Amended same day — see §1.5.** The SDK-main row moved to rc.3/crates.io hours after this
> table was written, and the publication facts reshape it: crates.io carries 0.11.0, 1.0.0,
> rc.2, rc.3, rc.4, rc.5 (max) — and **rc.1 was never published**. Treat the table below as the
> morning snapshot; the operative pin rule is in §1.5.

`zcash_voting` has moved through five release candidates in eleven days, across two orgs. This
table is the reason §1 exists.

| Where | Ref | Head | Date | Crate version |
|---|---|---|---|---|
| Our branch | — | *(commented out)* | — | — |
| Our commented-out pin | `valargroup/zcash_voting` | `e53e7448` | — | 2.0.0-rc.1 (stale org) |
| **SDK `origin/main` pin** | `zodl-inc/zcash_voting` | `3c9900e5` | 2026-07-30 | **2.0.0-rc.1** |
| `zodl-inc` default branch | `zodl-inc/zcash_voting` `main` | `c9b06e92` | 2026-06-03 | 0.10.2 *(old — main is behind)* |
| **Ironwood line** | `zodl-inc/zcash_voting` `merge/valargroup-ironwood` | `d1b7eed8` | 2026-08-06 | **2.0.0-rc.3** |
| **Newest release** | `valargroup/zcash_voting` `adam/release-zcash-voting-2.0.0-rc.5` | `d98fc12b` | 2026-08-08 | **2.0.0-rc.5** |
| tx1_effects source | `valargroup/zcash_voting` `adam/ironwood-delegation-signing-effects` | `7d9e91b6` | 2026-08-07 | — |

### 5.1 What main's pin is missing (8 commits)

`3c9900e5 … merge/valargroup-ironwood` is **0 behind / 8 ahead**:

```
0d224b1d  2026-07-30  Specify delegation signing transaction
0c057d0c  2026-07-30  Clarify delegation note and export format
b5bc1683  2026-07-30  State TX1 cannot become a Zcash transaction
d6995429  2026-07-30  Merge PR #151 agent/specify-delegation-signing-tx1
98fe6496  2026-08-05  Fix and run the end-to-end Ironwood delegation proof test (#152)   ← Ironwood
79d3b7b0  2026-08-05  Reject non-Ironwood/V3 notes at NoteInfo ingestion (#153)          ← Ironwood
ea385645  2026-08-05  Prepare zcash_voting 2.0.0-rc.3 (#155)
d1b7eed8  2026-08-06  Merge upstream/main into merge/valargroup-ironwood
```

**#152 and #153 are the Ironwood work.** #153 in particular — *reject non-Ironwood/V3 notes at
NoteInfo ingestion* — is the crate learning what an Ironwood note is at the point where voting
power is counted. Any "voting sees no eligible notes on Ironwood" symptom should be read against
that commit first.

### 5.2 rc.5 vs the Ironwood line — they have diverged

`d1b7eed8 … adam/release-zcash-voting-2.0.0-rc.5` = **13 ahead / 11 behind — diverged.**

rc.5 (on `valargroup`, 2026-08-08) carries, beyond rc.3:

```
53a69bcd  Require pir_layout handshake and pin runtime two-tier PIR (#162)
7f715a59  Add local PIR smoke harness (#166)
0b9a24ad  v2.0.0-rc.4
786a9ba5  v2.0.0-rc.4 crates
60f468a4  update vote commitment tree crates
5ed0c56b  Display Keystone voting memos (#170)
d98fc12b  Release zcash_voting 2.0.0-rc.5
```

And `adam/ironwood-delegation-signing-effects` carries `6f5b390a Add Ironwood delegation signing
effects` (2026-08-06) — **that is the tx1_effects source Android adopted** (§6).

**[OPEN — Q1]** Which ref do we ride? The Android PRs say they target `zcash_voting 2.0.0-rc.4`.
rc.4/rc.5 live on `valargroup`; the Ironwood merge line lives on `zodl-inc`; they have diverged
both ways. Somebody who owns the crate (Adam / nuttycom / dominik) needs to say which ref is the
one CHP-on-Ironwood should pin. I will not guess this — picking wrong costs a full FFI rebuild
and produces confusing failures at the PIR/proof layer.

**[OPEN — Q2]** No `2.0.0-rc.4` commit exists in `zodl-inc/zcash_voting`; it is only on
`valargroup`. Is `zodl-inc` meant to be the canonical fork going forward (SDK main points at it),
and if so does it need rc.4/rc.5 merged in?

### §5.5 · The ladder, taught (dug from tags, CHANGELOG @ v2.0.0-rc.5, and diffs — 2026-08-10)

Derived by a delegated dig through the crate's own history (full clone, tag-to-tag diffs,
CHANGELOG, PR bodies) — not from memory or Slack.

**The two axes.** "Old vs new voting" is two migrations that overlapped:

- **API generation** — the rework the CEO doc calls "the commitVote consolidation" is the crate's
  *"v2 voting api"* arc: it starts inside crate **1.0.0** (`0b5fffb7 feat!: v2 voting api
  (#120)`, Jun 7) and completes through rc.1's restructuring (governance PCZT construction moved
  behind `VotingDb::build_governance_pczt`; round-init + delegation APIs require an explicit
  network). Exactly which rung introduced `commit_vote` itself is a per-tag grep the API-diff
  fleet owes us → **[TO VERIFY — V3]**.
- **Dependency generation** — **Ironwood arrives at 2.0.0-rc.1**: V3-notes-only, compile flag
  gone, librustzcash 0.30/0.24/0.22 family, **Rust ≥ 1.88**.

Our app was written against the pre-1.0 API on pre-Ironwood deps — both axes moved under it.

**The rungs:**

| Version | Date | Published? | Essence |
|---|---|---|---|
| 0.11.0 | Jun 3 | crates.io only — **never git-tagged** | last of the old-API line |
| **1.0.0** | Jun 7 | yes (max stable) | "v2 voting api" lands (#120) |
| 2.0.0-rc.1 | Jul 25 | **tag only — never published** | the Ironwood port (a "2.0.0 final" prep commit exists — walked back to rc.1) |
| rc.2 | Jul 28 | yes | dependency alignment only (shardtree-0.7 vote tree, librustzcash rc.4 family); direct push, no release PR |
| **rc.3** | Aug 5 | yes — both SDK mains sit here | fail-early: `NoteInfo::from_orchard_note` rejects non-Ironwood/V3 at ingestion (previously failed only during proof construction — **after** the PCZT was built and signed); librustzcash rc.7 family |
| **rc.4** | Aug 7 | yes | **the wire release** — tx1_effects, PIR handshake, required `pir_layout` config, deferred PCZT anchor, per-helper-only share JSON (`all_enc_shares` removed); direct push, no release PR |
| **rc.5** | Aug 8 | yes (max) | one Keystone fix: zero-value hotkey outputs marked with their user-facing address so signer devices display the bundle memo. rc.4→rc.5 = 3 commits / 2 source files |

**tx1_effects, precisely** (rc.4; `zcash_voting/src/tx1.rs`, commits `c66c32e3` #156 +
`989bc681` #164): an **821-byte versioned blob** — `version[1]=0x01 ‖ action[820]`, action =
cv_net‖nullifier‖rk‖cmx‖ephemeral_key (5×32) + enc_ciphertext (580) + out_ciphertext (80).
Version 1 fixes the profile to NU6.3, one Ironwood V3 bundle, flags 0x07, +1-zatoshi value
balance, one action. It replaces the client-supplied `sighash` **on the wire only**
(`DelegationSubmissionWire.sighash` → `.tx1_effects`; wire tests assert `sighash` absent).
Internally sighash survives — it is still what Keystone/software signers actually sign and is
still stored in `bundles.pczt_sighash`. Purpose: the **server derives the signing digest itself**
instead of trusting a client hash — which is the entire mechanism behind Android's
`400: tx1 effects must be 821 bytes, got 0`.

**The PIR handshake, precisely** (rc.4; PR #162, `53a69bcd`): `connect_pir` /
`connect_pir_blocking` are NEW functions taking an explicit `PirLayout` from resolved dynamic
config; they **fail closed** (`VotingError::InvalidInput`) when the server's advertised
`/root.pir_layout` mismatches, before any private query. **Client-side** enforcement per the
code; an rc.3 client has no such code path at all (bare re-exported `PirClient` with a
compiled-in layout — mismatches went undetected). **Config schema consequence:** dynamic voting
config now **requires** top-level `pir_layout {pir_depth, tier0_layers, tier1_layers}` —
an app-layer parsing change AND a deployment precondition (the config service must serve it; the
QA test round must carry it). Feeds CEO items 4 and 5.

**Post-rc.5 — the rc.6 forecast and its landmine.** Merged-unreleased: #168 bounds vote-tree
sync (8 MiB response cap, 60 s timeout, per-round locks — DoS hardening for the caller-supplied
node URL). Open: #169 (PIR layout validation alignment) and **#172 round-auth v2** — binds
round_id + the advertised PIR layout into the round-authentication signature preimage and states
its own rollout precondition: a paired vote-sdk change plus **re-signing all active rounds before
wallets adopt it**. Hence:

> **Pin rule v2 (supersedes §1.5's rule):** newest **published** crates.io rc **whose runtime
> preconditions the deployed Valar infra meets** — today **rc.5** (strictly preferred over rc.4:
> the Keystone memo fix is ours to ship). Floor rc.3. Every future re-pin checks the CHANGELOG
> for #172-style coordination preconditions before taking it.

**Graph-coherence good news:** the librustzcash family requirements did NOT move between rc.3
and rc.5 (`zcash_client_backend ^0.24.0-rc.7`, `zcash_client_sqlite ^0.22.0-rc.7`, `pczt
^0.9.2`, `zcash_keys ^0.16.1`, `zcash_protocol ^0.10.4`, `orchard ^0.15` +
`unstable-voting-circuits`, `zcash_primitives ^0.30.0`); all rc.3→rc.5 churn is confined to the
PIR/tree family (pir-client/pir-types → rc.4, imt-tree 0.2.1, vote-commitment-tree 0.4.0-rc.2 +
client 0.6.0-rc.2). So V2's "does it co-resolve with our git-pinned librustzcash rev" is ONE
check covering the whole 2.0 line. docs.rs builds exist for rc.5.

**Meta-lesson:** tags and crates.io are not interchangeable signals in this repo — 0.11.0 (and
0.3.1, 0.4.0, 0.5.10) were published without tags; 2.0.0-rc.1 was tagged without publishing;
rc.2/rc.4 shipped as direct pushes with no release PR. **Pin by crates.io; diff by tags.**

---

## §6 · The Android reference — MOB-1678

dominik's "record of what changed that we could use for iOS". Two open PRs, both on
`bugfix/MOB-1678`; he has said the final versions will be re-targeted at `main`.

| | PR | Base | Size |
|---|---|---|---|
| App | [zodl-inc/zodl-android#2406](https://github.com/zodl-inc/zodl-android/pull/2406) | `maint/v3.9.x` | 17 files, +374 / −126 |
| SDK | [zcash/zcash-android-wallet-sdk#2157](https://github.com/zcash/zcash-android-wallet-sdk/pull/2157) | `maint/v3.0.x` | 13 files, +494 / −122 |

Both verified end-to-end on-device: a live multi-bundle CHP round completing construction,
proving and submission.

### 6.1 Fix A — `tx1_effects` replaces `sighash`

**Symptom:** `delegate-vote` submissions rejected with HTTP 400 —
`invalid message field: tx1 effects must be 821 bytes, got 0`.

**Cause:** the vote-chain server now requires a versioned `tx1_effects` blob (`zcash_voting`
2.0.0-rc.4). The app was still sending the legacy `sighash` field.

**Fix:** thread `tx1_effects` from the JNI/FFI layer up into the API request body.

**iOS bearing:** this crosses all three of our layers — the Rust FFI must expose it, the Swift
wrapper must carry it, `VotingAPIClientLiveKey` must put it on the wire. Our
`zcashlc_voting_get_delegation_submission` / `…_with_keystone_sig` are the symbols to look at.

### 6.2 Fix B — stop writing round-level phase during bundle construction

**Symptom:** multi-bundle rounds crash constructing bundle 1+ —
`no alpha for round=…, bundle=1`.

**Cause:** `build_governance_pczt_for_bundle` advanced the *round's* phase to
`HotkeyGenerated` / `DelegationConstructed` during construction. That write was a **zodl-SDK
addition the crate itself never does**. Once bundle 0 was proved, constructing bundle 1 was
hard-rejected as a phase regression ("refusing to regress round phase"), leaving bundle 1's
`alpha` NULL, which then crashed `build_and_prove_delegation`.

**Fix:** remove every round-level phase write and gate from the voting flow. Expose the crate's
own **per-bundle `DelegationPhase`** (`delegationPhasesNative`) and the sanctioned setup-reset
recovery path (`resetVotingSessionStateNative`). Base every "should I (re)construct / prove /
submit this bundle" decision on the per-bundle phase, with an overwrite-refusal-aware retry so a
`resetVotingSessionState` recovery cannot leave a stale `Proved` read pointing at NULL data.

**iOS bearing:** this is the one that matters most for us, because it is a *bug we may have
inherited by construction* — it lives in the SDK's own additions over the crate, and the iOS SDK
was written from the same brief as the Android one. **[TO VERIFY — V1]** does our
`zcashlc_voting_build_pczt` write round phase the way Android's did? The answer decides whether
we port a fix or discover we never had the bug.

### 6.3 Also on the Android app PR

One unrelated carry: `MigrationSendingVM` no longer bypasses `DRIVE_LOCK`. Not ours.

---

## §7 · Ironwood — what is actually known

### 7.1 The crate is Ironwood-aware, at rc.3+

`#152` (end-to-end Ironwood delegation proof test) and `#153` (reject non-Ironwood/V3 notes at
NoteInfo ingestion) landed 2026-08-05 on `merge/valargroup-ironwood`. So "make polling work with
Ironwood" is substantially **a pin-and-wire problem, not a protocol problem** — the protocol work
exists, upstream, and nuttycom's `7d8e9b15` reinstated the FFI module against it.

### 7.2 Our Ironwood floor

Our librustzcash pin `13ce6c4e` already carries the Ironwood work our own stack rides (per the
IW-6 re-ride: engine on librustzcash `main`, valargroup graph retired). **[TO VERIFY — V2]** that
the `zcash_voting` ref we pick resolves against `13ce6c4e` as a single graph instance — a voting
crate built against a different librustzcash generation will not co-resolve. This is the same
class of failure the Cargo.toml comment in our own repo warns about.

### 7.3 Carried-forward security findings

From the May-15 review, still open and still relevant — file paths have changed, findings have
not:

- **No Tor, no TLS/SPKI pinning** on vote/PIR/helper traffic. `ServerHealthTracker` probes every
  configured server every 60 s while the screen is alive. Voting de-anonymises the user's IP to
  every vote server and PIR endpoint.
- **Dynamic config is not hash-pinned**; `vote_servers` / `pir_endpoints` are not signed. A
  hostile CDN can swap the endpoint list for servers that report truthful chain data while
  harvesting IP + timing.
- **The hotkey is a full BIP-39 mnemonic** in the keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no biometric ACL), and `accountTag` is
  hardcoded `""` — one voting identity shared across all accounts on the device.
- **Drafts + vote records live in `UserDefaults` plaintext**.
- Seed/mnemonic bytes are not zeroized after use.

These are not this task's scope, but they should not be silently re-enabled either.
**[OPEN — Q3]** does re-enabling CHP require any of these closed first? That is Andrea's and
security's call, not mine.

## §7.5 · The design thesis — same experience, new spine (ratified with Lukas, 2026-08-10)

Lukas's formulation, adopted as the campaign's governing principle: **the app's voting UI/flows/UX
are complete — merely wired to an obsolete library generation. The crate is Valar's, taken as-is
at the pinned rc. The work is confined to the middle: use the new library, serve the existing
experience. No custom ideas, no invented code.**

Two rejected alternatives, for the record:

- *Compat shim in the SDK* (reproduce the old six-call pipeline on top of `commitVote` so the app
  stays byte-identical) — rejected: semantics-in-the-adapter (§2.0 rule 2), the very pattern
  behind Android's multi-bundle bug, and dishonest anyway — the intermediate artifacts no longer
  exist as separable steps.
- *Rebuild the UI against the new API* — rejected: violates the goal, the no-crafting rule, and
  discards 15k lines of working, product-approved surface.

**Precision — where the "middleman" boundary actually sits.** The app is three strata; only the
outermost is frozen ground:

| Stratum | Contents | Fate |
|---|---|---|
| Views + strings + flow topology | 23 screen files, 297 `coinVote.*` keys, CoordFlow structure, Figma parity | **FROZEN — zero changes** |
| Stores/effects | the TCA reducers that sequenced the old six-call pipeline | minimal rewiring where the pipeline lived (six calls → one) |
| Dependency clients | `VotingCryptoClient`, `VotingAPIClient`, models/config parsing | **adaptation surface** — the app's designed seam; part of the middleman |

So the middleman = FFI → SDK Swift wrapper → app dependency clients. The first two are largely
inherited from main's #1855 restore (the merge); the third is ours to reconcile.

**Four unavoidable leak points** — deltas that provably cannot be absorbed below the app's client
layer; none touches a pixel or a string:

1. **Hotkey model** — *amended by the panel (§11.4/D5): this point as first written OVERSTATED
   the change.* The app never derived the hotkey from the wallet seed — it already generates
   random material (`randomMnemonic()`) and keeps a per-account `StoredVotingHotkey` in the
   keychain. The real delta is **format only**: mnemonic phrase → the SDK's `storedSecret` bytes
   (~60 lines, one struct + call sites). And because the feature never shipped (§11.5/N3),
   **no migration code exists to write** — an old-format record is simply "no hotkey".
2. **Pipeline consolidation** — the six client members die; `commitVote` replaces them; store
   effects that sequenced them collapse to one call + progress callback.
3. **Wire/config** — `tx1_effects` threaded into the delegation submission body
   (`VotingAPIClient`), and required `pir_layout` parsing (config models).
4. **Per-bundle `DelegationPhase` consumption** (post-V1) — construct/prove/submit decisions read
   the crate's own phase, replacing any round-level invention.

**Empirical proof of the shape:** Android shipped exactly this thesis — same UI, adapters
reconciled — in 17 app files (+374/−126) and ~14 SDK files (+505/−124), verified on a live
multi-bundle round. *Amended by the panel (§11.4/D1): their PRs are the **wire-fix recipe book,
not the sizing template*** — Android's app already sat on the `commitVote` API before those PRs,
so their diff shows only the last (rc.3→rc.4) delta, while our app additionally owes the
six-call→`commitVote` collapse. iOS sizing comes from §11.4/D4, not from Android's line counts.
This mission remains an **adoption, not a build**.

**The guard:** if any state in the new model needs a screen or a string that does not exist,
it is identified and handed to product — never drafted here. The plan carries an explicit
**"zero new strings, zero new screens" verification gate**; deviations are product decisions,
not engineering ones.

---

## §8 · Plan sketch (not yet approved)

Ordered so each step is independently gateable. Nothing here has been started.

1. **D1 decision** (§4.3) — merge `origin/main` forward into `chp-re-enable`, or re-base off main.
2. **Q1 decision** (§5.2) — which `zcash_voting` ref to pin.
3. **SDK Rust**: adopt main's wiring — `mod voting` ungated, dependency + patch stanza restored at
   the chosen ref. Full FFI rebuild, all needed slices.
4. **SDK Swift**: the four `Rust/Voting/*.swift` files back, reconciled against the ported FFI.
5. **V1 audit** (§6.2) — check our `build_pczt` for the round-phase write. Port Fix B if present.
6. **Fix A** (§6.1) — `tx1_effects` end-to-end: FFI → Swift wrapper → `VotingAPIClientLiveKey` —
   plus the rc.4 config-schema adoption (required `pir_layout`) in the app's config parser, and
   the matching QA precondition that the test round's dynamic config serves it (§5.5).
7. **App**: define `VOTING_ENABLED` in the right configurations — *which* is itself a question
   (internal-only? testnet? all?). **[OPEN — Q4]**
8. **Gates**: full zodl suite + testnet `generic/platform=iOS` build + a live multi-bundle round
   on device, mirroring Android's acceptance.

---

## §9 · Working rules for this task

1. **Pin before you move.** Any new crate/rev/branch that enters the graph gets a row in §5 with
   its date and version, in the same commit that introduces it.
2. **Ironwood-first.** A `zcash_voting` ref that is not on the Ironwood line is not a candidate,
   however new it is.
3. **Do not invent the answer to Q1/Q2.** Crate ownership is Adam's / nuttycom's / dominik's.
   Ask; do not pick.
4. **Android is a reference, not a spec.** Their fixes were verified on their stack. Every port
   gets checked against our code before it is applied — §6.2 may be a bug we never had.
5. **No UI or copy invention.** CHP has 297 existing `coinVote.*` keys. If a state needs words
   that do not exist, that is identified and handed to product — never drafted here.
6. **Security findings in §7.3 are carried, not cleared.** Re-enabling does not close them.
7. **Commit trailers and branches** follow the existing conventions: zodl → `origin`
   (`zodl-inc/zodl-ios`); SDK checkout is push-guarded, Lukas pushes it by hand.

---

## §11 · Base-on-main merge + the four-proposal panel — verdicts (2026-08-10, night)

### 11.1 · The merge (executed under nuttycom's ruling)

Delegated to an Opus agent; result: **SDK `chp-re-enable` = `a3823651`** (merge of `origin/main`
into the stack; message amended for truthfulness), **36 ahead / 0 behind** main, `cargo check`
REAL exit 0 on the full graph **including the reinstated voting module**, only `Cargo.toml` +
`Cargo.lock` conflicted. Local only — Lukas pushes by hand.

Two briefing premises were **refuted by the compiler** (the delegate correctly disobeyed and
documented): (1) main's librustzcash rev `41a1e17c` cannot resolve against this stack — it
carries `zcash_pool_migration` rc.6 / `zcash_client_sqlite` rc.7, older than our rc.7/rc.8
floors; the revs are divergent lineages and ours (`13ce6c4e`, 08-07) is strictly newer and
already satisfies rc.3's needs (zcash_keys 0.16.1, zcash_protocol 0.10.4, pczt 0.9.3). The pin
**stays at ours**. (2) Main never raised the manifest floors — those versions ride the patch
rev. The slipstream dependency likewise stays ours (`zodl-slipstream` from crates.io).

**Accidental discovery:** the delegate's first lock attempt let cargo freshly resolve voting →
it pulled **rc.5** and hit a real `E0061` at `rust/src/voting/delegation.rs:420` (connect now
takes 3 args) — the first *located* rc.3→rc.5 code change, found for free. Checkouts were then
restored (zodl → `migration/gardening-test`, SDK → `fable/gardening-test`); CHP docs continue
via the worktree `../zodl-ios-chp-docs` on `chp-re-enable`.

### 11.2 · Panel setup

Four independent investigators, identical minimal briefs, one variable per axis; verbatim
reports preserved in `docs/chp-panel/`. Firewalls: none saw this document, the thesis, or each
other (physical: CHP.md absent from the read tree); blind arms barred from all Android
materials; SDK read via pinned SHAs only.

| | Sonnet | Opus |
|---|---|---|
| **+ Android PR** | A-S | A-O |
| **Blind** | B-S | B-O |

### 11.3 · The convergence spine — unanimous across all four (two of them blind)

1. The feature is complete and cleanly off behind one never-defined flag; flipping it is a
   build-settings line, no pbxproj surgery (files already in targets).
2. The merge is the foundation — "land what `a3823651` already proved; don't re-derive."
3. Target **rc.5, pinned exactly** (`=2.0.0-rc.5` — cargo otherwise resolves 1.0.0); rc.3's
   wire is server-rejected.
4. **Let the compiler enumerate the app gap**: flip the flag on a scratch/internal config and
   treat the error list as the authoritative work list.
5. UI/views/strings untouched; the work lives in the dependency clients + ~3 regions of one
   coordinator (`VotingCoordFlowCoordinator.swift`, 3,766 lines).
6. Decode `pir_layout` in the app config — the live service **already serves it**
   (`{pir_depth:19, tier0_layers:12, tier1_layers:7}`; two arms probed independently).
7. Local FFI rebuild is mandatory (released XCFramework carries zero `zcashlc_voting_*`
   symbols); budget the halo2 voting-circuits tax (Android: CI 30→60 min) and honor the
   `--universal`-before-archive rule; gate with `nm -gU` for `zcashlc_voting_commit_vote`.
8. Ironwood = the 2.0 crate line itself ("no custom compile flag" since rc.1; V3-only ingestion
   since rc.3) — no separate protocol work.

### 11.4 · Divergences, adjudicated

- **D1 — A-S underscoped the app work** (renames only; missed the six→one collapse). Cause: the
  Android PR shows only Android's *last* delta — their app already sat on `commitVote`. Ruling:
  the collapse is real (three arms + this document's own reads); **the PR is a wire-recipe
  book, not a sizing template** (§7.5 amended). Lesson: the reference *helped* Opus and
  *anchored* Sonnet.
- **D2 — does rc.4's PIR change hit our SDK glue?** B-S inferred no ("uses `with_transport`");
  B-O predicted yes at `delegation.rs:419/461/542`. The compiler had already ruled (11.1's
  accidental E0061): **yes**. Compiler beats inference.
- **D3 — adopt Android's `DelegationPhase` surface?** A-S said add proactively; A-O **proved
  the bug absent** (zero `update_round_phase_forward` / `require_round_phase_not_after`
  occurrences in our tree) — Android's apparatus exists to route around an Android-only
  invention. Ruling: **skip it** (§2.0 no-semantics + YAGNI). Noted as possible later
  recovery-surface work (A-O's R3), not now.
- **D4 — sizing.** Consensus after netting D1: **~30 lines SDK + ~240 lines app (largely
  deletions)** against 17,647 existing voting lines; **2–4 focused days to a testnet round**
  plus FFI build time; B-S's "~1 week" includes full E2E + soak, not a contradiction.
- **D5 — hotkey.** Format-only change, no migration (never shipped). §7.5 amended. A-O adds the
  one product-facing item: `storedSecret` is not seed-recoverable, so post-launch a lost secret
  strands delegated voting power — **product conversation before mainnet** (R5), not an
  engineering task, and squarely behind the zero-new-strings gate.

### 11.5 · Novel finds (credit per arm)

- **N1 (A-O) — a live Ironwood bug in our app:** `VotingCryptoClientLiveKey.swift:218` hardcodes
  consensus branch `0xC8E7_1055` (NU6); Ironwood is **`0x37a5_165b`**, and rc.5's
  `VotingShieldedProtocol::for_branch_id` hard-rejects anything but NU6.3. Fix includes making
  the SDK's `nu63ConsensusBranchID` public instead of re-hardcoding. *This is the concrete
  "with Ironwood support" item at the app layer.*
- **N2 (A-O) — R1, the only genuine design risk:** `commitVote` takes
  `voteCommitmentTreePosition` up front (feeds `build_share_payloads`), but the app learns the
  position only after tx confirmation (`leaf_index` parse). Whether payloads built with a
  provisional position survive the later `record_vc_position` correction is unresolved from
  source. **Settled by one Rust test before any app code** — equal-bytes ⇒ pure rewiring;
  unequal ⇒ a pre-commit position source is needed and the plan changes. B-O independently
  flagged the same region (the old two-phase store dance).
- **N3 (B-O) — never shipped ⇒ zero data migration.** No stored hotkeys, votes, or round state
  exist in the wild; every compat question collapses to "just change it".
- **N4 (B-O/B-S) — live infra already on the rc.4+ contract** (pir_layout served); **B-S:
  9 vote-server operators in the prod config incl. `zvote.zodl.com`** — a server we operate,
  QA-relevant.
- **N5 (A-O) — upstream wrote the migration guide:** `a250cb76` rewrote MIGRATING.md +
  rust/CHANGELOG with the exact app-facing delta. Spec input, free.
- **N6 (A-O) — the six-method disposition table** incl. `storeCommitmentBundle` →
  `recordVcPosition` and `decomposeWeight` removed-no-replacement; plus parameter-level deltas
  (network fixed at `open`; `markVoteSubmitted` requires tx hash; round IDs must be 64-hex
  canonical Pallas; `setupBundles` rejects empty note sets; `droppedCount` added).
- **N7 (B-O) — dead weight:** `encryptShares` + `decomposeWeight` have **zero consumers** in
  the app; delete, don't port. Also two corrections to the SDK's own module doc
  (`generate_delegation_inputs` NOT superseded; `decompose_weight` genuinely gone).
- **N8 (B-S) — standing structural risk:** the librustzcash-pin ↔ zcash_voting-floor coupling
  recurs at *every* future librustzcash bump, not just this one. Goes in the spec's maintenance
  notes.
- **N9 (B-S/A-O) — isolation + test assets:** `VotingRustBackend` was never hooked into the
  `Synchronizer` protocol (voting cannot destabilize sync); 1,527 lines of SDK offline voting
  tests + the app's gated test files come back for free.

### 11.6 · Amendments this panel forced on this document

§7.5 leak-point 1 corrected (hotkey format-only); §7.5 sizing-template caveat added; **V1
CLOSED** (bug absent, proven by grep — replaced by a light app-layer sweep for any home-grown
phase gate, A-S's point); **Q4 gains its working answer** (flag on `zodl-internal` +
`zodl-testnet` first; `zodl-production` only after soak — panel consensus, Lukas confirms at
design review). The orchestrator's analysis was overruled twice; that was the design.

### 11.7 · Consolidated ladder (panel synthesis — input to the spec, not the spec)

0. ~~R1 test first~~ **R1 RESOLVED → W2 (§11.9)**: no design work; step 5 below simply follows
   the sanctioned 7-step sequence + 3 traps verbatim. Optionally still: probe whether the
   testnet vote-chain accepts `sighash` (A-O's V4) — informational only, the rc.5 wire is the
   target regardless.
1. **rc.5 bump** on the merged SDK (`=2.0.0-rc.5`): thread `PirLayout`
   (`delegation.rs:419/461/542` + the FFI struct feeding precompute/prove), carry
   `tx1_effects` on the delegation-submission surface, drop `all_enc_shares` in `json.rs`.
   ~30–100 lines, Android's diffs as recipes.
2. **Full FFI rebuild** (`init-local-ffi.sh`; `--universal` before any archive) + `nm -gU`
   symbol gate.
3. **SDK gates:** `swift build` + OfflineTests (voting suite included, unmodified).
4. **Flag on** `zodl-internal`/`zodl-testnet` → compiler enumerates the app work list.
5. **App adaptations** (largely deletions): six→one `commitVote` collapse (coordinator
   ~`:1872-1930` + recovery paths ~`:2171`/`~:3463`; `storeCommitmentBundle`→`recordVcPosition`;
   delete the two zero-consumer members), hotkey format swap (~60 lines, no migration),
   **N1 branch-ID fix** (publicize the SDK constant), `sighash`→`tx1_effects` + single-share
   JSON, `pir_layout` decode, static-config URL re-pin (checksummed live URL).
6. **Tests back on** (app + SDK suites).
7. **Testnet E2E round** — note only one round is registered in prod with a fixed snapshot;
   plan around the crate's local-PIR harness (#166) and `zvote.zodl.com`.
   Production flag: after soak, and after the R5 product conversation.

### 11.9 · R1 verdict — W2, sanctioned correction path (Opus delegate, 2026-08-10 late)

**The panel's one "could-turn-into-design-work" item is closed as rewiring.** Decided at rungs
1+2 of the evidence ladder (crate source at `v2.0.0-rc.5` + Android's shipping code,
independently agreeing); the rung-3 experiment was superseded by an analytical proof.

- `vc_tree_position` is **not a cryptographic input** — exhaustive sweep of `zkp1/zkp2/
  precompute/action`, the cast-vote sighash (`vote_commitment.rs:142-177`), and the share
  nullifier (`share.rs:41-66`): zero references. It is one metadata scalar in the helper-share
  wire JSON (`wire_codec.rs:59-62`), explicitly late-bindable (`VoteShareWire::with_late_bound`).
- **The RNG confound is structurally void**: only ONE commit happens; `record_vc_position`
  rewrites a single `u64` in the stored recovery JSON (`vote.rs:812-834`) — every randomized
  artifact (proof, enc_shares, blinds, sigs) is carried byte-identically.
- **No silent failure mode**: commit never sets the position column (`vote.rs:900-916`), so the
  first correction is always legal, and until it lands every consumer hard-errors —
  `"commitment bundle is stored without vc_tree_position; refusing to assume position 0"`
  (`storage/queries.rs:2479-2483`). The crate's own test (`vote.rs:1925-1980`) runs exactly our
  scenario: commit@456 → record 789 → replay ok at 789, refused at 790.

**The sanctioned sequence (spec-verbatim), per bundle/proposal:**

1. `commitVote(..., voteCommitmentTreePosition: 0, ...)` — provisional; **do not submit the
   returned payloads**.
2. Broadcast the cast-vote tx (pre-confirmation resends via the submission accessor, never the
   commit result's payloads).
3. `markVoteSubmitted` (record the tx hash).
4. Await confirmation; parse `cast_vote` `leaf_index` = `"van_position,vc_position"`; take the
   **second** component.
5. `recordVcPosition(..., <confirmed vc_position>)` — idempotent on same-value replay.
6. **Re-call `commitVote` with the identical draft except the confirmed position** — it
   short-circuits into `commit_from_recovery` (**no re-proving**) and returns corrected
   payloads. (iOS ruling: this replay IS step 6 — our `getCommitmentBundle` returns raw
   recovery, not fresh payloads, so the replay path needs **zero FFI change**; adding a
   `recover_commit`-backed FFI to match Android's convenience is optional-later.)
7. Submit those payloads to the helper servers; record/confirm each share delegation.

**Three traps, encoded:** (T1) never replay the stale provisional draft once a tx hash exists —
`recovery_matches_draft` compares the position and a mismatch hard-errors ("submitted vote
that conflicts with requested draft"); update the cached draft to the confirmed position first.
(T2) commit **before** `record_vc_position` — the reverse order sets only the column and
self-heals only on a second record call; the sequence above avoids the state entirely.
(T3) the between-steps hard-errors are correct behavior — surface, don't swallow.

**Android corroboration:** their granular API doesn't even take a position at commit; their
`SubmitVotesUseCase` runs exactly this order (commit → submit → store hash → await → parse
`leaf_index` → `recordVcPosition` → submit shares), and their SDK test passes
`vcTreePosition = 0` literally.

**New open item — [OPEN — Q5]:** does the helper server cross-check the submitted
`tree_position` against its own VC-tree view (loud vs. silent failure on a wrong position)?
Server-side, outside the crate; does not change the app's obligations. One question to Valar,
non-blocking.

### 11.8 · Experiment readout

**The owner's hypothesis is confirmed and strengthened.** Raw Android numbers: ~85% mechanical /
~15% authored / 0% novel algorithm (A-S). A-O's correction goes further: the authored bucket was
almost entirely Android's own phase-bug payback, which we provably don't have — **iOS-applicable
transfer ≈ 48% mechanical + ~35 lines of adaptation; effectively 0% of their new logic
transfers.** Four arms, one spine: *"a lot of work, but simple work"* is now a measured result.
2×2 lessons: the reference PR helped the stronger model and anchored the cheaper one; blind
derivation caught the scope truth; convergence across firewalled arms is the strongest
overengineering guard we have. The one open technical question that could change the plan's
shape is R1 — which is why it is task zero.

---

## §10 · Log

| Date | What |
|---|---|
| 2026-08-10 | Starting point pinned (§1). `chp-re-enable` cut in both repos at `fea8d600` / `93a11081`. Three off-switches mapped (§3). #1855 restore found on SDK `main`, 12 commits ahead of us (§4). Crate ladder traced across both orgs (§5). Android MOB-1678 fixes read and summarised (§6). Open: D1, Q1–Q4, V1–V2. |
| 2026-08-10 (night 4) | **R1 RESOLVED → W2** (§11.9): `vc_tree_position` is metadata, not crypto (exhaustive circuit/sighash/nullifier sweep = zero refs); correction = one-u64 recovery-JSON rewrite, byte-identical everything else, "refusing to assume position 0" guard makes wrong-position unshippable; sanctioned 7-step sequence + 3 traps captured spec-verbatim; Android ships the identical order; iOS step 6 = idempotent commitVote replay, ZERO FFI change. RNG confound structurally void (one commit only). Rung 3 unnecessary. New Q5 (server-side tree_position cross-check — Valar, non-blocking). Last open technical question closed; design presentation unblocked. |
| 2026-08-10 (night 3) | CHP-M merge LANDED: SDK `chp-re-enable` = `a3823651` (36↑/0↓, cargo check exit 0 with voting compiled; pin stays `13ce6c4e` — main's `41a1e17c` refuted by the resolver; accidental rc.5 E0061 @ `delegation.rs:420` = first located bump task). Checkouts restored; docs → worktree. Four-proposal panel (2×2 model×PR) adjudicated → §11: spine ×8 unanimous, D1–D5 ruled, N1 branch-ID bug (`0xC8E7_1055`→`0x37a5_165b`), R1 vc_tree_position = the one design risk (test-first, task zero), zero-new-code CONFIRMED-strengthened (~48% mechanical + ~35 lines; 0% of Android's new logic transfers). §7.5 amended ×2 (panel overruled the orchestrator, as designed); V1 CLOSED; Q4 working answer = internal+testnet first. Verbatim reports: `docs/chp-panel/`. |
| 2026-08-10 (night 2) | Design thesis ratified with Lukas → §7.5: same experience, new spine — UI/strings/flows FROZEN, crate taken as-is, all delta absorbed in the middleman (FFI → SDK wrapper → app dependency clients); compat-shim and UI-rebuild alternatives rejected on record; four leak points named (hotkey model, six→one consolidation, tx1_effects+pir_layout, per-bundle phase); zero-new-strings/zero-new-screens gate added. nuttycom's base-on-main ruling in execution: delegated merge of origin/main into SDK chp-re-enable running, gate = cargo check on the full graph incl. the reinstated voting module. |
| 2026-08-10 (night) | Ladder dig (delegated, full-history clone + tag diffs): §5.5 written — two-axes model (API rework began in 1.0.0's #120; Ironwood at rc.1), tx1_effects anatomy (821-byte versioned blob, wire-only sighash replacement), PIR handshake = client-enforced + config now REQUIRES pir_layout (new app task + QA precondition), rc.4→rc.5 trivial (Keystone memo fix — we want it), rc.6 landmine (#172 requires re-signed rounds) ⇒ pin rule v2 (published rc + infra-precondition gate; today rc.5, floor rc.3), librustzcash family static across rc.3→rc.5 (V2 = one check), Rust ≥ 1.88 floor. New: V3 (which rung introduced commit_vote — API-diff fleet). |
| 2026-08-10 (eve) | Blind re-verification by two delegated agents (neither shown this doc): one authoring error found+fixed (§2.1 → 48 files); same-day movement recorded as §1.5 — SDK main absorbed ironwood-slipstream via #1954 (now 35↑/17↓), voting pin rc.1→rc.3 crates.io (patch stanza gone), librustzcash rev → `41a1e17c`, `commitVote` lost `networkId:`, rc.1 never published on crates.io, valargroup round-auth-v2 branch pushed today. D1 cheap; Q1 → pin *rule* (newest published rc, floor rc.3, re-check gate); Q2 dissolved for published versions. M2 (tx1_effects) + V1/M4 (round-phase audit) re-verified still standing on today's main. |
