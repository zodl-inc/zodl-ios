# Note split via same-address V2 change outputs — private-path migration unblocked

**Ticket:** MOB-1455 · **Date:** 2026-07-02 · **Status:** Approved design
**Supersedes (partially):** the earlier same-day finding "note-split impossible post-NU6.3"
(commit `2546aee4`, since dropped from the branch) — see "Correction" below.

## Correction to the earlier finding

The earlier finding correctly proved that post-NU6.3 Orchard V2 **payment outputs** are impossible
(`add_output` → `CrossAddressDisabled`; a fabricated same-address spend cannot be created for an
address the wallet does not control). Its conclusion — "fanning one V2 note into N notes is
structurally impossible" — was **overstated**. The orchard builder supports **multiple
wallet-controlled change outputs** in one cross-address-disabled bundle:

- `Builder::add_change_output` pushes onto a `Vec` with no count limit (orchard `builder.rs:915`).
- Bundle construction iterates **all** changes, pairing each with a fabricated zero-value spend *at
  the change output's own address*, wallet-controlled and signed by the normal flow
  (`builder.rs:1267-1287`). The same-address rule is satisfied per action by construction; the change
  address only has to be **owned by the wallet's fvk**.
- Action counting generalizes: cross-address disabled ⇒ `actions = num_spends + num_outputs`
  (`builder.rs:125-131`), changes included, no cap.

So the restriction's true meaning: **V2 cannot pay third parties, but self-restructuring via change
outputs is sanctioned.** Splitting one V2 note into k wallet-owned V2 notes is exactly that.

## Why the fork's wallet layer still can't do it (and why that's OK)

`create_pczt_from_proposal` routes payments *and* change off one global flag
(`orchard_outputs_are_ironwood`, wallet.rs:1677/2253/2330): V6 ⇒ everything to Ironwood; V5 ⇒ Orchard
change but on the legacy circuit the server rejects. There is no proposal shape that expresses
"k current-circuit V2 changes in a V6 tx". **We bypass that one function** and drive the public
`zcash_primitives::transaction::builder::Builder` directly from `ZODLIronwoodMigrationRust` — no fork
or orchard changes (both are out of our control; we consume only their public APIs).

## Design

### The split transaction (crate `ZODLIronwoodMigrationRust`, `sign_split` internals replaced)

1. **Select inputs:** all spendable Orchard V2 notes (usually one). Note + commitment-tree position
   come from the existing selection path; reuse the current reserved/locks handling.
2. **Fetch witnesses:** `WalletCommitmentTrees::with_orchard_tree_mut` +
   `witness_at_checkpoint_id_caching` at the wallet's natural anchor — the exact pattern of
   fork wallet.rs:1768-1814.
3. **Build:** `Builder::new(params, target_height, BuildConfig::Standard { orchard_anchor: Some(a),
   ironwood_anchor: None, .. })`, then per input `add_orchard_spend(fvk, note, merkle_path)`, then per
   denomination `add_orchard_change_output(fvk, internal_ovk, internal_address, value, empty_memo)`.
   Change address = `orchard_fvk.address_at(0, Scope::Internal)` (same as the fork's own change);
   scanner stores the outputs as spendable `note_version = 2` notes.
4. **Balance/fee:** `build_for_pczt(OsRng, Zip317FeeRule::standard())` computes the fee itself
   (`5000 × (num_spends + k)` zatoshi, MIN_ACTIONS≥2) and requires exact balance. Denomination values
   come from `plan_denominations`; the **last denomination absorbs the exact-fee residual** so
   `Σ(inputs) − Σ(changes) = fee` exactly. `NoteSplitProposal.fee` reports the exact fee.
5. **Assemble PCZT:** `build_for_pczt` result → pczt `Creator`/`IoFinalizer` roles (pattern at fork
   wallet.rs:2861 ff).
6. **Prove/sign/serialize:** the existing `build_signed_pczt` steps 2–4 run unchanged —
   `orchard_proving_key()` is already the `OrchardPostNu6_3` key; the sign-all-indices loop signs the
   real spends *and* the fabricated change-spends (all wallet-keyed). V6 is selected automatically
   (`build_for_pczt` picks V6 whenever the OrchardPostNu6_3 builder is in use).

### Everything else is unchanged

- **Crate:** `plan_denominations`, phases/store, `is_tx_mined` prep-confirmation detection,
  `propose_migration_transfers`, migration transfers (V6 → Ironwood), immediate path.
- **SDK:** FFI surface (`zcashlc_migration_sign_note_split`), `submitNoteSplit`, broadcast logging.
- **App:** the entire migration flow — the note-split screen simply starts succeeding.

### On-chain shape & privacy

The split is a V6 tx with a single `OrchardPostNu6_3` bundle: `num_spends + k` shuffled actions,
`disableCrossAddress` set, value balance = +fee. Amounts and addresses stay shielded; observers learn
only the fee and the action count. Each subsequent nightly transfer publicly reveals one **round
denomination** crossing the turnstile (bundle value balances are public — inherent to any design).
The total balance is never revealed as one number. This matches the originally approved privacy
profile. The server already accepts `OrchardPostNu6_3` bundles with `disableCrossAddress` (every
immediate-path migration tx is one), so the split adds only "more actions" and "no Ironwood bundle"
to a known-accepted shape.

## Risks & fallback

1. **Server rejects a V6 tx with only an Orchard bundle** (Zebra rule we cannot see client-side).
   Fallback, same mechanism: **combined variant** — the split tx also crosses the first denomination
   (k−1 V2 changes + 1 Ironwood output via `add_ironwood_output` + `ironwood_anchor`), making the tx
   shape identical to the accepted immediate tx plus change fan-out. This is a small code delta, done
   only if the pure split is rejected on the test server.
2. **Unseen consensus cap on OrchardPostNu6_3 outputs/actions.** Settled by the same one broadcast.
3. **Exact-fee mismatch** between `plan_denominations` and the builder — deterministic math; covered
   by unit tests.

## Testing

- **Crate unit tests:** exact-fee/residual math (`Σ inputs − Σ changes = 5000×(spends+k)`);
  denomination plan unchanged elsewhere.
- **On-server validation (user):** fresh wallet with Orchard funds → private path → split broadcasts
  and confirms → notes fan out (DB `orchard_received_notes.note_version = 2`, k rows) → schedule
  proposes N transfers → first transfer crosses. The existing 508 Swift tests must stay green
  (no SDK/app changes expected).

## Out of scope

- Peel-chain design (serial crossings) — documented alternative, not needed if this works.
- Any change to fork/orchard/server (out of our control by constraint).
