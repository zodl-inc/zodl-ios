# Note Split via Same-Address V2 Change Outputs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the migration note-split so it fans one Orchard V2 note into k wallet-owned V2 notes via multiple same-address change outputs in a V6 transaction, driving the `zcash_primitives::Builder` directly from `ZODLIronwoodMigrationRust`.

**Architecture:** The fork's `create_pczt_from_proposal` cannot express "k current-circuit V2 changes in a V6 tx" (one global routing flag), so a new crate module `split.rs` replicates the narrow slice we need: select spendable V2 notes → fetch witnesses from the wallet's commitment tree → `Builder::new` + `add_orchard_spend`×n + `add_orchard_change_output`×k → `build_for_pczt` (auto-V6, `OrchardPostNu6_3` circuit) → `Creator`/`IoFinalizer` → PCZT. The existing prove/sign/serialize pipeline is extracted into a shared helper and reused unchanged. SDK and app code do not change.

**Tech Stack:** Rust (crate `ZODLIronwoodMigrationRust`), valargroup librustzcash fork + zcash/orchard fork consumed as **read-only** git dependencies via their public APIs, `pczt` roles, `shardtree`.

**Spec:** `docs/superpowers/specs/2026-07-02-note-split-same-address-change-design.md` (zodl-ios repo).

## Global Constraints

- **Never modify** the librustzcash fork or orchard crate (`~/.cargo/git/checkouts/...`) — they are read-only dependencies; local edits are not shippable and cargo won't even rebuild them (fingerprinted by git revision).
- Crate repo: `/Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust`, branch `1455-final-fixes`.
- App repo: `/Users/chlup/Developing/zec/work/ironwood/zodl-ios`, branch `michal/MOB-1455-4-ironwood-final-fixes`. SDK repo not touched by this plan.
- Crate tests: `cargo test` from the crate root (default features include `librustzcash-backend`).
- FFI rebuild: `/Users/chlup/Developing/zec/work/ironwood/zcash-swift-wallet-sdk/Scripts/rebuild-local-ffi.sh ios-sim` (never `cargo build --manifest-path` for the xcframework).
- Any `xcodebuild` invocation MUST include `-skipMacroValidation`; app scheme is `zodl-internal`, workspace `secant.xcworkspace`.
- Commit messages: `[MOB-1455] <title>`, ending with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- ZIP-317 marginal fee is 5 000 zatoshi/action; grace floor 2 actions; cross-address-disabled bundles count `actions = num_spends + num_outputs` (changes included).

---

### Task 1: Fee and exact-balance helpers (`split.rs` core math)

**Files:**
- Modify: `ZODLIronwoodMigrationRust/Cargo.toml` (add `shardtree` optional dep + feature entry)
- Modify: `ZODLIronwoodMigrationRust/src/error.rs` (add `From<ShardTreeError<E>>`)
- Modify: `ZODLIronwoodMigrationRust/src/lib.rs` (register `mod split`)
- Create: `ZODLIronwoodMigrationRust/src/split.rs` (helpers + unit tests in-file)

**Interfaces:**
- Produces: `pub(crate) fn split_fee(n_spends: usize, n_changes: usize) -> u64` and `pub(crate) fn adjust_outputs_for_exact_balance(selected_total: u64, fee: u64, outputs: &[u64]) -> Result<Vec<u64>, MigrationError>` — consumed by Tasks 2–4.

- [ ] **Step 1: Add the `shardtree` dependency and feature entry**

In `ZODLIronwoodMigrationRust/Cargo.toml`, add to `[dependencies]` (next to the other optional backend deps, e.g. after the `orchard` line):

```toml
shardtree = { version = "0.6.2", optional = true }
```

and add `"dep:shardtree",` to the `librustzcash-backend` feature list (after `"dep:pczt",`).

- [ ] **Step 2: Add the ShardTree error conversion**

In `ZODLIronwoodMigrationRust/src/error.rs`, add (near the other `From` impls; `MigrationError::Pipeline(String)` already exists):

```rust
/// Commitment-tree access during the direct-builder note split. Gated with the backend feature
/// because `shardtree` is only pulled in there.
#[cfg(feature = "librustzcash-backend")]
impl<E: core::fmt::Debug> From<shardtree::error::ShardTreeError<E>> for MigrationError {
    fn from(e: shardtree::error::ShardTreeError<E>) -> Self {
        MigrationError::Pipeline(format!("commitment tree: {e:?}"))
    }
}
```

- [ ] **Step 3: Register the module**

In `ZODLIronwoodMigrationRust/src/lib.rs`, in the backend-modules block (next to `mod backend;`):

```rust
#[cfg(feature = "librustzcash-backend")]
mod split;
```

- [ ] **Step 4: Write the failing tests**

Create `ZODLIronwoodMigrationRust/src/split.rs` containing ONLY the test module for now:

```rust
// Note split via same-address V2 change outputs (design spec
// docs/superpowers/specs/2026-07-02-note-split-same-address-change-design.md, zodl-ios repo).
//
// Post-NU6.3 the `OrchardPostNu6_3` protocol disables cross-address transfers: payment outputs are
// rejected (`CrossAddressDisabled`), but the orchard builder sanctions any number of
// wallet-controlled **change** outputs, each paired with a fabricated zero-value spend at the
// change's own address. The fork's `create_pczt_from_proposal` routes all V6 Orchard-destined
// outputs (payments AND change) to Ironwood, so this module drives the public
// `zcash_primitives::transaction::builder::Builder` directly instead.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_fee_is_marginal_fee_times_actions() {
        // Cross-address disabled: actions = spends + changes; ZIP-317 marginal fee 5000.
        assert_eq!(split_fee(1, 2), 15_000);
        assert_eq!(split_fee(1, 9), 50_000);
        assert_eq!(split_fee(2, 3), 25_000);
    }

    #[test]
    fn split_fee_applies_the_two_action_grace_floor() {
        assert_eq!(split_fee(1, 0), 10_000);
        assert_eq!(split_fee(0, 1), 10_000);
    }

    #[test]
    fn adjust_keeps_outputs_when_balance_is_exact() {
        let adjusted =
            adjust_outputs_for_exact_balance(1_000_000, 15_000, &[500_000, 485_000]).unwrap();
        assert_eq!(adjusted, vec![500_000, 485_000]);
    }

    #[test]
    fn adjust_absorbs_the_residual_in_the_last_output() {
        // Planned against an estimated fee; the exact fee differs → last output absorbs the delta.
        let adjusted =
            adjust_outputs_for_exact_balance(1_000_000, 15_000, &[500_000, 400_000]).unwrap();
        assert_eq!(adjusted, vec![500_000, 485_000]);
        let adjusted =
            adjust_outputs_for_exact_balance(1_000_000, 15_000, &[500_000, 500_000]).unwrap();
        assert_eq!(adjusted, vec![500_000, 485_000]);
    }

    #[test]
    fn adjust_rejects_a_nonpositive_last_output() {
        assert!(adjust_outputs_for_exact_balance(1_000_000, 15_000, &[985_000, 10_000]).is_err());
    }

    #[test]
    fn adjust_rejects_fee_exceeding_total_and_empty_outputs() {
        assert!(adjust_outputs_for_exact_balance(10_000, 15_000, &[5_000]).is_err());
        assert!(adjust_outputs_for_exact_balance(1_000_000, 15_000, &[]).is_err());
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `cargo test --manifest-path /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust/Cargo.toml split::`
Expected: FAIL to compile — `split_fee` / `adjust_outputs_for_exact_balance` not found.

- [ ] **Step 6: Implement the helpers**

Add above the test module in `split.rs`:

```rust
use crate::error::MigrationError;

/// ZIP-317 marginal fee per logical action (zatoshi).
const MARGINAL_FEE_ZATOSHI: u64 = 5_000;
/// ZIP-317 grace floor on the action count.
const GRACE_ACTIONS: u64 = 2;

/// Exact ZIP-317 fee for the split transaction. The bundle disables cross-address transfers, so
/// each spend and each change output occupies its own action: `actions = n_spends + n_changes`
/// (floored at the grace count). No sapling or transparent components exist in a split.
pub(crate) fn split_fee(n_spends: usize, n_changes: usize) -> u64 {
    let actions = (n_spends as u64).saturating_add(n_changes as u64);
    MARGINAL_FEE_ZATOSHI * actions.max(GRACE_ACTIONS)
}

/// Make the planned outputs balance exactly: `Σ(outputs) = selected_total − fee`, with the last
/// output absorbing the residual (the denomination plan was made against an estimated fee and the
/// wallet's balance snapshot; the builder requires an exact balance). Errors when the fee exceeds
/// the selected total, when there are no outputs, or when absorption would make the last output
/// non-positive.
pub(crate) fn adjust_outputs_for_exact_balance(
    selected_total: u64,
    fee: u64,
    outputs: &[u64],
) -> Result<Vec<u64>, MigrationError> {
    let required: u64 = selected_total
        .checked_sub(fee)
        .ok_or_else(|| {
            MigrationError::Pipeline(format!(
                "note split: fee {fee} exceeds selected total {selected_total}"
            ))
        })?;
    let mut adjusted = outputs.to_vec();
    let current: u64 = adjusted.iter().sum();
    let last = adjusted
        .last_mut()
        .ok_or_else(|| MigrationError::Pipeline("note split: no outputs to adjust".into()))?;
    let new_last = (*last as i128) + (required as i128) - (current as i128);
    if new_last <= 0 {
        return Err(MigrationError::Pipeline(format!(
            "note split: residual absorption drives the last output to {new_last} zatoshi"
        )));
    }
    *last = new_last as u64;
    Ok(adjusted)
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cargo test --manifest-path /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust/Cargo.toml split::`
Expected: PASS (6 tests).

- [ ] **Step 8: Commit**

```bash
cd /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust
git add Cargo.toml src/error.rs src/lib.rs src/split.rs
git commit -m "[MOB-1455] Add note-split fee and exact-balance helpers" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Direct-builder split PCZT construction

**Files:**
- Modify: `ZODLIronwoodMigrationRust/src/split.rs` (add selection + build pipeline)

**Interfaces:**
- Consumes: `split_fee`, `adjust_outputs_for_exact_balance` (Task 1); crate types `Db<P>` (`backend.rs`), `ReservedInputSource` (`reserved_source.rs`), `MigrationError`.
- Produces:
  - `pub(crate) fn select_spendable_v2_notes<P: Parameters>(db: &Db<P>, account: AccountUuid, migration_locks: &BTreeSet<(String, u32)>) -> Result<Vec<ReceivedNote<ReceivedNoteId, orchard::note::Note>>, MigrationError>`
  - `pub(crate) fn build_split_pczt<P: Parameters>(db: &mut Db<P>, network: &P, account: AccountUuid, usk: &UnifiedSpendingKey, migration_locks: &BTreeSet<(String, u32)>, outputs: &[u64]) -> Result<(pczt::Pczt, Vec<u64>), MigrationError>` — returns the unproven PCZT plus the residual-adjusted output values.

- [ ] **Step 1: Add imports and the note-selection helper**

At the top of `split.rs` (above the helpers from Task 1), add:

```rust
use std::collections::BTreeSet;

use rand::rngs::OsRng;
use zcash_client_backend::data_api::wallet::input_selection::InputSelectorError;
use zcash_client_backend::data_api::wallet::ConfirmationsPolicy;
use zcash_client_backend::data_api::{InputSource, TargetValue};
use zcash_client_backend::wallet::ReceivedNote;
use zcash_client_sqlite::{AccountUuid, ReceivedNoteId};
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_primitives::transaction::builder::{BuildConfig, Builder};
use zcash_primitives::transaction::fees::zip317::FeeRule as Zip317FeeRule;
use zcash_protocol::consensus::{BlockHeight, Parameters};
use zcash_protocol::memo::MemoBytes;
use zcash_protocol::value::Zatoshis;
use zcash_protocol::ShieldedProtocol;

use crate::backend::Db;
use crate::reserved_source::ReservedInputSource;
```

(If `InputSelectorError` ends up unused after Step 2, drop that line.) Then the selection helper:

```rust
/// All spendable Orchard **V2** notes for `account`, excluding migration-locked notes. Selection
/// goes through [`ReservedInputSource`] so its (txid, output_index) lock filtering applies; V3
/// (Ironwood) notes are filtered out defensively — at split time none should exist yet.
pub(crate) fn select_spendable_v2_notes<P: Parameters>(
    db: &Db<P>,
    account: AccountUuid,
    migration_locks: &BTreeSet<(String, u32)>,
) -> Result<Vec<ReceivedNote<ReceivedNoteId, orchard::note::Note>>, MigrationError> {
    let (target, _anchor) = db
        .get_target_and_anchor_heights(ConfirmationsPolicy::default().trusted())?
        .ok_or(MigrationError::NotSynced)?;
    let total = crate::backend::pool_balances(db, account)?.orchard_spendable;
    if total == 0 {
        return Err(MigrationError::Pipeline(
            "note split: no spendable Orchard balance".into(),
        ));
    }
    let reserved: BTreeSet<ReceivedNoteId> = BTreeSet::new();
    let source = ReservedInputSource {
        inner: db,
        reserved: &reserved,
        migration_locks,
    };
    let notes = source
        .select_spendable_notes(
            account,
            TargetValue::AtLeast(Zatoshis::const_from_u64(total)),
            &[ShieldedProtocol::Orchard],
            target,
            ConfirmationsPolicy::default(),
            &[],
        )
        .map_err(|e| MigrationError::Pipeline(format!("note split: select notes: {e:?}")))?
        .take_orchard();
    Ok(notes
        .into_iter()
        .filter(|n| n.note().version() == orchard::note::NoteVersion::V2)
        .collect())
}
```

NOTE for the implementer: check `backend.rs` — `Db` and `pool_balances` are `pub(crate)` already; `get_target_and_anchor_heights` needs `use zcash_client_backend::data_api::WalletRead;` in scope (add it to the import block if the compiler asks). If `select_spendable_notes` returns its error as a concrete DB error rather than `InputSelectorError`, adapt the `map_err` accordingly — the surrounding `format!("{e:?}")` pattern stays.

- [ ] **Step 2: Add the build pipeline**

Below the selection helper:

```rust
/// Build the note-split transaction as an unproven PCZT: spend every spendable V2 note and fan the
/// value into one same-address change output per planned denomination. Runs entirely on public
/// fork APIs (the fork's `create_pczt_from_proposal` cannot keep V6 Orchard outputs in the V2
/// pool). Returns the PCZT and the residual-adjusted output values actually used.
///
/// The bundle is `OrchardPostNu6_3` (current circuit): `Builder::new` derives the protocol from
/// the target height's consensus branch, and `build_for_pczt` selects `V6` because that builder is
/// in use. Change outputs are sanctioned under the cross-address restriction — the orchard builder
/// pairs each with a fabricated zero-value spend at the change's own address, signed by the normal
/// signing flow with the wallet's spend-authorizing key.
pub(crate) fn build_split_pczt<P: Parameters>(
    db: &mut Db<P>,
    network: &P,
    account: AccountUuid,
    usk: &UnifiedSpendingKey,
    migration_locks: &BTreeSet<(String, u32)>,
    outputs: &[u64],
) -> Result<(pczt::Pczt, Vec<u64>), MigrationError> {
    // --- immutable phase: select the notes to consolidate ---
    let notes = select_spendable_v2_notes(db, account, migration_locks)?;
    if notes.is_empty() {
        return Err(MigrationError::Pipeline(
            "note split: no spendable Orchard V2 notes".into(),
        ));
    }
    let selected_total: u64 = notes.iter().map(|n| n.note().value().inner()).sum();
    let fee = split_fee(notes.len(), outputs.len());
    let adjusted = adjust_outputs_for_exact_balance(selected_total, fee, outputs)?;

    let (target, natural_anchor) = crate::backend::target_and_anchor(db)?;
    let anchor_height = BlockHeight::from_u32(natural_anchor);

    // --- mutable phase: anchor root + witness per spent note ---
    let (anchor, spends) = db.with_orchard_tree_mut::<_, _, MigrationError>(|tree| {
        let anchor: orchard::Anchor = tree
            .root_at_checkpoint_id(&anchor_height)?
            .ok_or_else(|| {
                MigrationError::Pipeline(format!(
                    "note split: anchor not found at height {anchor_height}"
                ))
            })?
            .into();
        let mut spends: Vec<(orchard::note::Note, orchard::tree::MerklePath)> = Vec::new();
        for received in &notes {
            let merkle_path = tree
                .witness_at_checkpoint_id_caching(
                    received.note_commitment_tree_position(),
                    &anchor_height,
                )?
                .ok_or_else(|| {
                    MigrationError::Pipeline(format!(
                        "note split: witness checkpoint pruned at {anchor_height}"
                    ))
                })?;
            spends.push((*received.note(), merkle_path.into()));
        }
        Ok((anchor, spends))
    })?;

    // --- build: n spends + k same-address change outputs, exact balance ---
    let mut builder = Builder::new(
        network.clone(),
        BlockHeight::from_u32(target),
        BuildConfig::Standard {
            sapling_anchor: None,
            orchard_anchor: Some(anchor),
            ironwood_anchor: None,
        },
    );
    let orchard_fvk = orchard::keys::FullViewingKey::from(usk.orchard());
    for (note, merkle_path) in spends {
        builder
            .add_orchard_spend::<std::convert::Infallible>(orchard_fvk.clone(), note, merkle_path)
            .map_err(|e| MigrationError::Pipeline(format!("note split: add spend: {e:?}")))?;
    }
    let change_address = orchard_fvk.address_at(0u32, orchard::keys::Scope::Internal);
    let internal_ovk = orchard_fvk.to_ovk(orchard::keys::Scope::Internal);
    for value in &adjusted {
        builder
            .add_orchard_change_output::<std::convert::Infallible>(
                orchard_fvk.clone(),
                Some(internal_ovk.clone()),
                change_address,
                Zatoshis::const_from_u64(*value),
                MemoBytes::empty(),
            )
            .map_err(|e| MigrationError::Pipeline(format!("note split: add change: {e:?}")))?;
    }

    let build_result = builder
        .build_for_pczt(OsRng, &Zip317FeeRule::standard())
        .map_err(|e| MigrationError::Pipeline(format!("note split: build: {e:?}")))?;

    // --- assemble the PCZT (Creator → IoFinalizer), mirroring the fork's create_pczt tail ---
    let created = pczt::roles::creator::Creator::build_from_parts(build_result.pczt_parts)
        .ok_or_else(|| MigrationError::Pipeline("note split: pczt creation failed".into()))?;
    let finalized = pczt::roles::io_finalizer::IoFinalizer::new(created)
        .finalize_io()
        .map_err(|e| MigrationError::Pipeline(format!("note split: io finalize: {e:?}")))?;

    Ok((finalized, adjusted))
}
```

NOTES for the implementer (API drift tolerances, all verified against the fork checkout):
- `BuildConfig::Standard` has exactly the fields `sapling_anchor`, `orchard_anchor`, `ironwood_anchor` under the `nu6.3` cfg (this crate always builds with it — see `.cargo/config.toml` rustflags in the SDK workspace; the crate inherits the flag through the workspace build).
- `with_orchard_tree_mut::<F, A, E>` requires `E: From<ShardTreeError<...>>` — satisfied by the Task 1 `From` impl; keep the explicit `::<_, _, MigrationError>` turbofish.
- If `sapling_anchor: None` makes type inference fail on the `Option`, annotate `Option<sapling::Anchor>`... it will not: the struct field types fix it.
- If `Creator::build_from_parts` is missing, the `pczt` dependency needs the `zcp-builder` feature — it is already in the crate's feature list; if the compiler still complains, mirror whatever feature `zcash_client_backend`'s `pczt` dependency enables in the fork's `zcash_client_backend/Cargo.toml`.
- `notes.len()` for the fee is computed **after** the V2 filter — correct by construction.

- [ ] **Step 3: Compile and run the crate tests**

Run: `cargo test --manifest-path /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust/Cargo.toml`
Expected: PASS (all existing tests + the 6 from Task 1; `build_split_pczt` is compile-verified — exercising it requires a synced wallet DB, the crate's documented integration gap).

- [ ] **Step 4: Commit**

```bash
cd /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust
git add src/split.rs
git commit -m "[MOB-1455] Build the note split directly on the tx builder (k same-address V2 changes)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Wire `sign_split` to the new pipeline; retire the V5 path

**Files:**
- Modify: `ZODLIronwoodMigrationRust/src/backend.rs`

**Interfaces:**
- Consumes: `crate::split::build_split_pczt` (Task 2).
- Produces: `pub(crate) fn prove_sign_finalize(pczt: pczt::Pczt, usk: &UnifiedSpendingKey) -> Result<SignedPczt, MigrationError>`; `propose_migration_transfer` and `build_signed_pczt` lose their `tx_version` parameter (always V6); `sign_split` keeps its signature but returns notes whose stored values are the residual-adjusted ones.

- [ ] **Step 1: Extract `prove_sign_finalize` from `build_signed_pczt`**

In `backend.rs`, `build_signed_pczt` currently is: (1) `create_pczt_from_proposal_with_tx_version` → (2) prove → (3) sign → (4) finalize/serialize/extract. Move steps 2–4 verbatim into a new function placed directly after `build_signed_pczt`:

```rust
/// Prove, sign, finalize, and serialize an assembled PCZT. Shared by the migration transfers
/// (whose PCZT comes from the fork's `create_pczt_from_proposal_with_tx_version`) and the note
/// split (whose PCZT comes from `split::build_split_pczt`). The Orchard bundle is
/// `OrchardPostNu6_3` in both cases, so one proving key serves; the Ironwood proof only runs when
/// the PCZT carries an Ironwood bundle (migration transfers).
pub(crate) fn prove_sign_finalize(
    pczt: pczt::Pczt,
    usk: &UnifiedSpendingKey,
) -> Result<SignedPczt, MigrationError> {
    let mut prover = pczt::roles::prover::Prover::new(pczt);
    if prover.requires_orchard_proof() {
        prover = prover
            .create_orchard_proof(orchard_proving_key())
            .map_err(|e| MigrationError::Pipeline(format!("orchard proof: {e:?}")))?;
    }
    if prover.requires_ironwood_proof() {
        prover = prover
            .create_ironwood_proof(ironwood_proving_key())
            .map_err(|e| MigrationError::Pipeline(format!("ironwood proof: {e:?}")))?;
    }
    let pczt = prover.finish();

    // Sign every Orchard spend that is ours — including the note split's fabricated zero-value
    // change-spends, which are wallet-controlled. Action positions are randomized (qleak), so we
    // try every index and ignore wrong-key actions, terminating on InvalidIndex.
    let mut signer = pczt::roles::signer::Signer::new(pczt)
        .map_err(|e| MigrationError::Pipeline(format!("pczt signer init: {e:?}")))?;
    let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());
    for index in 0.. {
        match signer.sign_orchard(index, &ask) {
            Err(pczt::roles::signer::Error::InvalidIndex) => break,
            Ok(())
            | Err(pczt::roles::signer::Error::OrchardSign(
                orchard::pczt::SignerError::WrongSpendAuthorizingKey,
            )) => {}
            Err(e) => return Err(MigrationError::Pipeline(format!("sign orchard: {e:?}"))),
        }
    }
    let pczt = signer.finish();

    let pczt = pczt::roles::spend_finalizer::SpendFinalizer::new(pczt)
        .finalize_spends()
        .map_err(|e| MigrationError::Pipeline(format!("finalize spends: {e:?}")))?;
    let raw_pczt = pczt.serialize();
    let tx = pczt::roles::tx_extractor::TransactionExtractor::new(pczt)
        .extract()
        .map_err(|e| MigrationError::Pipeline(format!("extract tx: {e:?}")))?;
    Ok(SignedPczt {
        txid: tx.txid(),
        raw_pczt,
    })
}
```

Then shrink `build_signed_pczt` to: create the PCZT (always `TxVersion::V6`) and delegate:

```rust
/// Drive the full PCZT pipeline for a proposal: create the PCZT at V6, then prove, sign, and
/// serialize. Migration transfers cross Orchard-destined outputs into Ironwood per the fork's
/// `orchard_outputs_to_ironwood` rule; the note split does NOT go through here (see
/// `split::build_split_pczt`).
pub(crate) fn build_signed_pczt<P: Parameters>(
    db: &mut Db<P>,
    network: &P,
    account: AccountUuid,
    usk: &UnifiedSpendingKey,
    proposal: &Proposal<Zip317FeeRule, ReceivedNoteId>,
) -> Result<SignedPczt, MigrationError> {
    let pczt = create_pczt_from_proposal_with_tx_version::<
        _,
        _,
        std::convert::Infallible,
        _,
        std::convert::Infallible,
        _,
    >(
        db,
        network,
        account,
        OvkPolicy::Sender,
        proposal,
        TxVersion::V6,
    )
    .map_err(|e| MigrationError::Pipeline(format!("create pczt: {e:?}")))?;
    prove_sign_finalize(pczt, usk)
}
```

- [ ] **Step 2: Drop the V5 machinery**

Still in `backend.rs`:
1. Delete `legacy_orchard_proving_key()` (the whole function and its doc comment).
2. In `propose_migration_transfer`: remove the `tx_version: TxVersion` parameter and its doc comment; replace the change-strategy `if matches!(tx_version, TxVersion::V5) { base.with_legacy_orchard_change() } else { base }` block with just `base` (keep the `let change_strategy = ...` binding, simplified); change the `Some(tx_version)` argument in `propose_transaction(...)` to `Some(TxVersion::V6)`.
3. Update the caller in `sign_schedule` (currently passes `TxVersion::V6` twice): drop the last argument from both the `propose_migration_transfer(...)` call and the `build_signed_pczt(...)` call.
4. Header comment of the proving-keys section: update the sentence about the V5 legacy circuit to say the split now also proves with the `OrchardPostNu6_3` key.

- [ ] **Step 3: Rewrite `sign_split`**

Replace the entire body of `sign_split` (keep the signature) with:

```rust
/// Build, sign (as a PCZT), and persist the note-split (denomination prep) transaction: spend the
/// wallet's V2 notes and fan the value into one **same-address change output** per planned
/// denomination. Change outputs are the one operation the post-NU6.3 cross-address restriction
/// sanctions for retaining V2 value, so the split stays in the Orchard pool on the current
/// (`OrchardPostNu6_3`) circuit. Stored note values are the residual-adjusted ones actually built.
#[allow(clippy::too_many_arguments)]
pub(crate) fn sign_split<P: Parameters>(
    db: &mut Db<P>,
    conn: &rusqlite::Connection,
    network: &P,
    account: AccountUuid,
    usk: &UnifiedSpendingKey,
    run_id: &str,
    account_str: &str,
    outputs: &[u64],
) -> Result<SignedPczt, MigrationError> {
    let locks = store::locked_note_refs(conn, account_str)?;
    let (pczt, adjusted_outputs) =
        crate::split::build_split_pczt(db, network, account, usk, &locks, outputs)?;
    let signed = prove_sign_finalize(pczt, usk)?;
    store::insert_prep_tx(
        conn,
        run_id,
        &signed.txid.to_string(),
        &signed.raw_pczt,
        "pending",
    )?;
    let prepared: Vec<store::PreparedNote> = adjusted_outputs
        .iter()
        .enumerate()
        .map(|(i, &value_zatoshi)| store::PreparedNote {
            txid_hex: signed.txid.to_string(),
            output_index: i as u32,
            value_zatoshi,
            note_version: 2,
            nullifier_hex: None,
            lock_state: "locked".to_string(),
        })
        .collect();
    store::insert_prepared_notes(conn, run_id, &prepared)?;
    Ok(signed)
}
```

Also remove imports that became unused (`self_payment_request_multi` stays only if still referenced — if `sign_split` was its last caller, delete `build_self_payment_multi`, `self_payment_request_multi`, AND their unit test `build_self_payment_creates_single_payment_for_amount`? No — that test exercises `build_self_payment` (singular), which `self_payment_request` still uses for transfers; delete only the *multi* pair and any test that references the multi pair specifically).

- [ ] **Step 4: Run the crate tests**

Run: `cargo test --manifest-path /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust/Cargo.toml`
Expected: PASS. Also expect zero warnings about unused code (`TxVersion` import stays — still used by `build_signed_pczt`).

- [ ] **Step 5: Commit**

```bash
cd /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust
git add src/backend.rs
git commit -m "[MOB-1455] Sign the note split via the direct builder; retire the V5 legacy path" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Exact split fee in `prepare_note_split`

**Files:**
- Modify: `ZODLIronwoodMigrationRust/src/context.rs`

**Interfaces:**
- Consumes: `split::split_fee`, `split::select_spendable_v2_notes` (Tasks 1–2).
- Produces: `prepare_note_split` reports the exact ZIP-317 fee in `NoteSplitProposal.fee` (previously the flat `FEE_ESTIMATE_ZATOSHI`).

- [ ] **Step 1: Compute the exact fee**

In `context.rs`, replace the body of `prepare_note_split` with:

```rust
    /// Compute the optimal note split for the spendable Orchard balance. Each output note is
    /// self-funding (`power_of_ten + buffer`); any residual stays in Orchard. The reported fee is
    /// the exact ZIP-317 fee for the split transaction (`5000 × (spends + outputs)`, floored at 2
    /// actions); at signing time the last output absorbs any drift between this plan and the
    /// then-current balance.
    pub fn prepare_note_split(&self) -> Result<NoteSplitProposal, MigrationError> {
        let total = self.orchard_spendable()?;
        let plan =
            plan_denominations(total, FEE_ESTIMATE_ZATOSHI).map_err(MigrationError::Pipeline)?;
        // Pre-split there are no migration locks yet, so no exclusions apply.
        let db = self.open_wallet()?;
        let locks = std::collections::BTreeSet::new();
        let n_spends =
            crate::split::select_spendable_v2_notes(&db, backend::account_uuid(self.account_uuid), &locks)?
                .len()
                .max(1);
        Ok(NoteSplitProposal {
            output_notes: plan.migration_outputs.clone(),
            fee: crate::split::split_fee(n_spends, plan.migration_outputs.len()),
        })
    }
```

(Adapt the account expression to whatever `sign_note_split` in the same file already uses — it calls `backend::account_uuid(self.account_uuid)`; reuse that exact form. Drop the `.clone()` if `plan` is consumed.)

- [ ] **Step 2: Run the crate tests**

Run: `cargo test --manifest-path /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust/Cargo.toml`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/chlup/Developing/zec/work/ironwood/ZODLIronwoodMigrationRust
git add src/context.rs
git commit -m "[MOB-1455] Report the exact ZIP-317 fee from prepare_note_split" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Rebuild the FFI and the app

**Files:** none (verification only; no SDK/app source changes in this plan).

- [ ] **Step 1: Rebuild the xcframework**

Run: `/Users/chlup/Developing/zec/work/ironwood/zcash-swift-wallet-sdk/Scripts/rebuild-local-ffi.sh ios-sim`
Expected: ends with `Rebuilt ios-sim (arm64) in LocalPackages/libzcashlc.xcframework`. The crate is a path dependency, so no `cargo clean` is needed (that was only ever required for in-place edits to the git-checkout fork — which this plan forbids).

- [ ] **Step 2: Build the app from the CLI**

Run:
```bash
cd /Users/chlup/Developing/zec/work/ironwood/zodl-ios
xcodebuild build -workspace secant.xcworkspace -scheme zodl-internal -destination 'generic/platform=iOS Simulator' -skipMacroValidation -quiet
```
Expected: `BUILD SUCCEEDED` (warnings tolerated). If the build fails with a stale-dependency-graph error after the xcframework swap, delete the DerivedData `Intermediates.noindex` for this workspace and retry once; if it still fails, STOP and fall back per the global CLI-first rule.

- [ ] **Step 3: No commit** — nothing changed in this task; it gates the handoff.

---

### Task 6: On-server validation (user-run) and outcome handling

**Files:** none yet (outcome-dependent).

- [ ] **Step 1: Hand off the sim test**

Ask the user to: create a fresh test wallet with Orchard funds (their tool), sync, take the migration SmartBanner → **private path** → "Split Your Wallet Funds" → Confirm, and watch the `zodl.migration` os_log output for the broadcast result.

- [ ] **Step 2: Interpret**

- **Broadcast accepted, split confirms, k notes appear** (`orchard_received_notes` gains k rows with `note_version = 2`), Transfer Plan then proposes N transfers → design validated end-to-end. Proceed to Step 3.
- **Rejected with `could not validate orchard proof` or a cross-address/consensus error** → STOP; report the exact `code` + `message` to the user and decide together between the spec's fallback (fold the first Ironwood crossing into the split tx so the tx shape matches the already-accepted immediate tx) and escalation to the qleak team. The fallback gets its own plan.
- **Local build error before broadcast** → normal debugging within this plan's code (the error text pinpoints the failing stage: select / anchor / witness / add spend / add change / build / io finalize).

- [ ] **Step 3: On success — refresh the stale app comment**

In `zodl-ios/secant/Sources/Features/CoordFlows/MigrationCoordFlowCoordinator.swift` (the `.entry(.delegate(.chose(mode)))` case), replace the NOTE sentence claiming the split is rejected at consensus with:

```swift
                } else if migrationSDK.isNoteSplitNeeded() {
                    // Private path denominates the balance into multiple transfers, which requires a
                    // note split (one Orchard note per denomination) first. The split fans the balance
                    // into same-address V2 change outputs — the one V2-retaining operation the
                    // post-NU6.3 cross-address restriction sanctions.
                    state.path.append(.noteSplit(MigrationNoteSplit.State()))
```

- [ ] **Step 4: Commit (app repo)**

```bash
cd /Users/chlup/Developing/zec/work/ironwood/zodl-ios
git add secant/Sources/Features/CoordFlows/MigrationCoordFlowCoordinator.swift
git commit -m "[MOB-1455] Update the note-split comment now that the split broadcasts" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** selection/witness/builder/fee/assembly (§Design 1–5) → Tasks 1–2; unchanged prove/sign reuse (§Design 6) → Task 3; exact fee reporting → Task 4; "everything else unchanged" → no SDK/app source tasks (Task 6 Step 3 is a comment refresh only); risks/fallback → Task 6 Step 2; testing section → Tasks 1 (unit), 5 (builds), 6 (on-server).
- **Types:** `split_fee(usize, usize) -> u64` and `adjust_outputs_for_exact_balance(u64, u64, &[u64]) -> Result<Vec<u64>, MigrationError>` used identically in Tasks 1/2/4; `build_split_pczt` consumed in Task 3 with the exact signature produced in Task 2; `prove_sign_finalize(pczt::Pczt, &UnifiedSpendingKey)` defined and consumed in Task 3.
- **Known API-drift tolerances** are called out inline (Task 2 notes) rather than left to surprise.
