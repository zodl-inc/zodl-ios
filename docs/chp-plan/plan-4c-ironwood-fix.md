## TASK 4C

### Task 4C: ironwood-root regression fix [gate-7 finding #1]

*Code blocks by: Opus (4C amendment delegate). The Rust is written-from-reading against the
reverted fix `8a40d1f9`, `zcash_voting 2.0.0-rc.5`'s cached crate source
(`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/zcash_voting-2.0.0-rc.5/`), the pinned
librustzcash rev `13ce6c4e…`, and the SDK worktree at `b5262ac5`; it compiles at this task's own
steps 4C.9/4C.10 and executes at 4C.11.*

Gate-7 finding #1: every delegation attempt against live testnet round
`0199de7afa96ff1495c4a14920f5e483dbd3f300f6bc685daa58a739f7af9723` (snapshot 4179680) fails with
`cached TreeState orchard root does not match round nc_root`. It is not an environment problem and
not a convention subtlety — **the SDK reads the wrong shielded pool's tree.** Voting notes live in
the **Ironwood** pool; a round's `nc_root` is the Ironwood note-commitment tree's root at the
snapshot height. `rust/src/voting/delegation.rs` and `rust/src/voting/util.rs` read
`TreeState::orchard_tree()`. Orchard and Ironwood are separate pools with separate trees
(`zcash_client_backend`'s own doc: *"The Ironwood tree is Orchard-shaped, but Ironwood is a
distinct pool tracked separately from Orchard"*), so the comparison can never succeed, on any
chain, against any server. Proven byte-exactly against the real round and the wallet's real server
(`testnet.zec.rocks:443`, `GetTreeState` at 4179680):

```
orchard_root :  dbf39126a2ef11a57c612e89a449b1d17a70dc3bffd886ea66f64bb1a0678515
ironwood_root:  0dd6cb7f1ed6f14a96d87259dbfbc8c1b199806cc17105be4ae746cd4343362f
round nc_root:  0dd6cb7f1ed6f14a96d87259dbfbc8c1b199806cc17105be4ae746cd4343362f
```

The SDK is also internally inconsistent today: `rust/src/voting/notes.rs:89` already *selects*
voting notes with `get_unspent_ironwood_notes_at_historical_height` (the feature branch's work,
which the merge kept), while `delegation.rs` witnesses those same Ironwood notes against the
Orchard tree.

**This is a regression, not a new bug.** It was found and fixed on 2026-07-17 by `8a40d1f9`
(*"[#1806] Compile voting for Ironwood and read the Ironwood note tree"* — its message already
names *"validated the Orchard root against the round's Ironwood nc_root, which can never
match"*), and silently discarded on 2026-08-06 by merge `eea6cde8`, which resolved the conflicted
`rust/src/voting` sources in favour of `main`'s independent `[#1855]` port for a real reason (the
feature branch called `build_vote_commitment`/`sign_cast_vote`, `pub(crate)` in the published
crate). `main`'s port forked from before the Ironwood fix and never had it, so choosing it
reinstated the pre-fix code **and deleted the two regression tests that would have screamed.**
This task re-lands the fix's substance on today's tree and crate, and puts those tests back so a
third loss is loud.

**Files:**
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/delegation.rs`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/util.rs`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift` (doc comment only)
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`

**Interfaces:**
- Consumes: `zcash_voting::witness::generate_note_witnesses` (rc.5 `src/witness.rs:48`, exported by
  `pub mod witness;` at `src/lib.rs:43`) — the same entry point `8a40d1f9` routed through, still
  public and unchanged in shape by the 1.0 → 2.0 move;
  `zcash_client_backend::proto::service::TreeState::ironwood_tree()` (pinned rev, `proto.rs:419`).
- Produces: **no new FFI symbol, and no change to any existing one.**
  `zcashlc_voting_generate_note_witnesses` and `zcashlc_voting_extract_nc_root` keep their exact
  C signatures; only the bytes they compute change. Step 4C.14 asserts that at the `nm` level.
- No app-side (Zodl) change is implicated: the Swift wrappers are byte/JSON pass-throughs and only
  one doc comment is stale.

**What the crate's call validates — the redundancy verdict (read before deleting anything).**
`witness::generate_note_witnesses` does, in this order (`rc.5 src/witness.rs:48-155`):

| # | Check | Ours had it? |
|---|---|---|
| 1 | loads the round's cached `TreeState`, params **and stored network** from the voting DB | ours loaded the first two |
| 2 | `validate_wallet_network`: wallet DB's network type vs the round's stored network | **no — new, fail-closed** |
| 3 | `TreeState::decode` | yes |
| 4 | `u32::try_from(snapshot_height)`, explicit reject | yes (same message) |
| 5 | `VotingShieldedProtocol::for_height` — rejects any snapshot height that is not NU6.3 | **no — new, fail-closed** |
| 6 | reads `tree_state.ironwood_tree()` | **no — read `orchard_tree()`: the bug** |
| 7 | `validate_cached_tree_state_for_round`: `tree_state.height == params.snapshot_height` **and** frontier root `== params.nc_root` | yes — **both**, same two checks, same order |
| 8 | non-empty frontier required | yes |
| 9 | `generate_ironwood_witnesses_at_historical_height` | ours called the `orchard` sibling |
| 10 | generated path count == note count | yes |

⇒ **Our hand-rolled `validate_cached_tree_state_for_round` is fully subsumed by the crate's — item
7 is our function, word for word, fed the right root — so deleting it loses nothing and the crate
adds two checks we never had.** What the crate does *not* do is cache: `generate_note_witnesses`
computes only, so the FFI keeps its existing `handle.db.store_witnesses(...)` call unchanged.

**Why not `precompute::stored_note_witnesses`.** It is exactly `witness::generate_note_witnesses`
plus `db.replace_bundle_witnesses(round_id, bundle_index, &witnesses)` (`rc.5 src/precompute.rs:69-83`),
and that store is *not* the store this FFI does today. `VotingDb::store_witnesses`
(`src/storage/operations.rs:688-708`) short-circuits when the cached count already equals the
witness count; `replace_bundle_witnesses` (`:715-726`) never short-circuits, additionally requires
the bundle's note-position rows to pre-exist and match exactly, and always deletes+reinserts inside
a transaction. Swapping them would smuggle a second, unreviewed behavior change into a regression
fix. This task calls the generation half only.

---

- [ ] **Step 4C.1: Preconditions.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git log --oneline -3 && git status --short | grep -v '^??' ; grep -c 'orchard_tree()' rust/src/voting/delegation.rs rust/src/voting/util.rs
```

Expected: HEAD is `b5262ac5 [#1855] Add the software delegation-signing passthrough zcash_voting 2.0
prescribes` (Task 4B), a clean tree (no staged/modified output), and **`rust/src/voting/delegation.rs:1`**
plus **`rust/src/voting/util.rs:1`**. If either grep count is `0` the fix is already in — stop and
report. If HEAD is not 4B's commit, stop and check the ladder before continuing.

- [ ] **Step 4C.2: `util.rs` — read the Ironwood tree.** In `rust/src/voting/util.rs`, replace:

```rust
/// Extract the Orchard note commitment tree root from a protobuf-encoded TreeState.
///
/// Returns the 32-byte nc_root as `*mut FfiBoxedSlice`, or null on error.
```

with:

```rust
/// Extract the Ironwood note commitment tree root from a protobuf-encoded TreeState.
///
/// Voting rounds anchor to the Ironwood pool — `zcash_voting 2.0` supports no
/// other shielded protocol — so a round's `nc_root` is the root of the Ironwood
/// tree, not the Orchard one. They are distinct pools with distinct trees whose
/// roots never coincide on a live chain, so reading the wrong field does not
/// degrade gracefully: it fails every round, always.
///
/// Returns the 32-byte nc_root as `*mut FfiBoxedSlice`, or null on error.
```

Then, in the same function's body, replace:

```rust
        let orchard_ct = tree_state
            .orchard_tree()
            .map_err(|e| anyhow!("failed to parse orchard tree from TreeState: {}", e))?;
        let nc_root = orchard_ct.root().to_bytes().to_vec();
```

with:

```rust
        let ironwood_ct = tree_state
            .ironwood_tree()
            .map_err(|e| anyhow!("failed to parse ironwood tree from TreeState: {}", e))?;
        let nc_root = ironwood_ct.root().to_bytes().to_vec();
```

- [ ] **Step 4C.3: `delegation.rs` — drop the three imports the hand-rolled block owned.** At the
top of `rust/src/voting/delegation.rs`, replace:

```rust
use anyhow::anyhow;
use ff::PrimeField;
use ffi_helpers::panic::catch_panic;
use incrementalmerkletree::Position;
use pasta_curves::pallas;
use prost::Message;
use zcash_client_backend::proto::service::TreeState;
use zcash_voting::{self as voting, zkp1};
```

with:

```rust
use anyhow::anyhow;
use ff::PrimeField;
use ffi_helpers::panic::catch_panic;
use pasta_curves::pallas;
use zcash_voting::{self as voting, zkp1};
```

(`ff::PrimeField` stays — `parse_path` still calls `pallas::Base::from_repr`. `Position`, `Message`
and `TreeState` become test-only; step 4C.6 re-imports the latter two inside `mod tests`, which
already imports `Position` itself.)

- [ ] **Step 4C.4: `delegation.rs` — delete the hand-rolled validator.** Replace:

```rust
use super::progress::ProgressBridge;

/// Validate that a cached lightwalletd `TreeState` is anchored to the voting
/// round it will be used for.
///
/// Witness generation trusts the cached Orchard frontier as the historical
/// checkpoint input. The generated Merkle path can verify against that
/// frontier's own root, so we must also enforce that the frontier is exactly
/// the round snapshot: same block height and same note commitment tree root.
fn validate_cached_tree_state_for_round(
    tree_state: &TreeState,
    orchard_root: &[u8],
    params: &voting::VotingRoundParams,
) -> anyhow::Result<()> {
    if tree_state.height != params.snapshot_height {
        return Err(anyhow!(
            "cached TreeState height {} does not match round snapshot_height {}",
            tree_state.height,
            params.snapshot_height
        ));
    }

    if orchard_root != params.nc_root.as_slice() {
        return Err(anyhow!(
            "cached TreeState orchard root does not match round nc_root"
        ));
    }

    Ok(())
}

// =============================================================================
// VotingDatabase methods — Delegation proof
// =============================================================================
```

with:

```rust
use super::progress::ProgressBridge;

// =============================================================================
// VotingDatabase methods — Delegation proof
// =============================================================================
```

- [ ] **Step 4C.5: `delegation.rs` — route witness generation through the crate.** In
`zcashlc_voting_generate_note_witnesses`, replace this whole block:

```rust
        let (tree_state_bytes, params) = {
            let wallet_id = handle.db.wallet_id();
            let conn = handle.db.conn();
            let tree_state_bytes =
                voting::storage::queries::load_tree_state(&conn, &round_id_str, &wallet_id)
                    .map_err(|e| anyhow!("load_tree_state failed: {}", e))?;
            let params =
                voting::storage::queries::load_round_params(&conn, &round_id_str, &wallet_id)
                    .map_err(|e| anyhow!("load_round_params failed: {}", e))?;
            (tree_state_bytes, params)
        };

        // Decode the tree state
        let tree_state = TreeState::decode(tree_state_bytes.as_slice())
            .map_err(|e| anyhow!("failed to decode TreeState protobuf: {}", e))?;
        let orchard_ct = tree_state
            .orchard_tree()
            .map_err(|e| anyhow!("failed to parse orchard tree from TreeState: {}", e))?;
        let frontier_root = orchard_ct.root();
        let frontier_root_bytes = frontier_root.to_bytes();
        validate_cached_tree_state_for_round(&tree_state, &frontier_root_bytes[..], &params)?;
        let frontier = orchard_ct.to_frontier();
        let nonempty_frontier = frontier.take().ok_or_else(|| {
            anyhow!("empty orchard frontier — no orchard activity at snapshot height")
        })?;

        // Convert note positions to Merkle positions
        let positions: Vec<Position> = core_notes
            .iter()
            .map(|n| Position::from(n.position))
            .collect();

        // `BlockHeight` is u32-backed; `snapshot_height` is u64. A wallet that
        // somehow synced past u32::MAX blocks is impossible in protocol terms,
        // but reject it explicitly rather than silently truncating.
        let snapshot_height = u32::try_from(params.snapshot_height).map_err(|_| {
            anyhow!(
                "snapshot_height {} does not fit in u32",
                params.snapshot_height
            )
        })?;
        let checkpoint_height = zcash_protocol::consensus::BlockHeight::from_u32(snapshot_height);

        // Generate witnesses from wallet DB shard data + frontier
        let merkle_paths = wallet_db
            .generate_orchard_witnesses_at_historical_height(
                &positions,
                nonempty_frontier,
                checkpoint_height,
            )
            .map_err(|e| {
                anyhow!(
                    "generate_orchard_witnesses_at_historical_height failed: {}",
                    e
                )
            })?;

        if merkle_paths.len() != core_notes.len() {
            return Err(anyhow!(
                "generated {} Merkle paths for {} notes",
                merkle_paths.len(),
                core_notes.len()
            ));
        }

        // Convert MerklePaths to WitnessData
        let root_bytes = frontier_root_bytes.to_vec();
        let witnesses: Vec<voting::WitnessData> = merkle_paths
            .into_iter()
            .zip(core_notes.iter())
            .map(|(path, note)| {
                let auth_path: Vec<Vec<u8>> = path
                    .path_elems()
                    .iter()
                    .map(|h| h.to_bytes().to_vec())
                    .collect();
                voting::WitnessData {
                    note_commitment: note.commitment.clone(),
                    position: note.position,
                    root: root_bytes.clone(),
                    auth_path,
                }
            })
            .collect();
```

with:

```rust
        // `zcash_voting` owns shielded-protocol-aware witness generation and has
        // since 2.0. It loads this round's cached `TreeState` and stored params,
        // checks the wallet DB's network against the round's, resolves the
        // shielded protocol for the snapshot height (Ironwood — the crate
        // supports no other, and rejects a pre-NU6.3 snapshot outright), reads
        // the **Ironwood** note-commitment tree out of the cached `TreeState`,
        // binds that frontier to the round (same height, same `nc_root` — the
        // check this SDK used to hand-roll), and generates the historical
        // Ironwood Merkle paths from the wallet's own shard data.
        //
        // Do not re-hand-roll this against the Orchard tree. Voting notes live
        // in the Ironwood pool — `notes.rs` already selects them with
        // `get_unspent_ironwood_notes_at_historical_height` — so an Orchard root
        // can never equal a round's `nc_root`, on any chain, against any server.
        // That hand-rolled version is what `8a40d1f9` deleted and what the
        // `eea6cde8` merge silently brought back.
        let witnesses = voting::witness::generate_note_witnesses(
            &handle.db,
            &round_id_str,
            &core_notes,
            &wallet_db,
        )
        .map_err(|e| anyhow!("failed to generate voting note witnesses: {}", e))?;
```

The following `// Verify and cache in voting DB` / `handle.db.store_witnesses(...)` block and the
JSON response stay exactly as they are: the crate generates, this FFI still caches.

Then update that function's doc comment — replace:

```rust
/// Generate Merkle inclusion witnesses for the notes in a bundle and cache
/// them in the voting DB.
///
/// `notes_json` is a JSON-encoded `Vec<NoteInfo>`.
```

with:

```rust
/// Generate Merkle inclusion witnesses for the notes in a bundle and cache
/// them in the voting DB.
///
/// The witnesses come from the **Ironwood** note-commitment tree. Voting notes
/// live in the Ironwood pool and a round's `nc_root` is that tree's root at the
/// snapshot height; `zcash_voting` picks the pool, validates the cached
/// `TreeState` against the round, and generates the paths. This function only
/// marshals.
///
/// `notes_json` is a JSON-encoded `Vec<NoteInfo>`.
```

- [ ] **Step 4C.6: `delegation.rs` tests — imports and shared constants.** In `mod tests`, replace:

```rust
    use incrementalmerkletree::frontier::{CommitmentTree, Frontier};
    use incrementalmerkletree::{Position, Retention};
    use orchard::tree::MerkleHashOrchard;
    use zcash_client_backend::data_api::WalletCommitmentTrees;
    use zcash_client_sqlite::wallet::init::WalletMigrator;
```

with:

```rust
    use incrementalmerkletree::frontier::{CommitmentTree, Frontier};
    use incrementalmerkletree::{Position, Retention};
    use orchard::tree::MerkleHashOrchard;
    use prost::Message;
    use zcash_client_backend::data_api::WalletCommitmentTrees;
    use zcash_client_backend::proto::service::TreeState;
    use zcash_client_sqlite::wallet::init::WalletMigrator;
```

Then replace:

```rust
    const TEST_ROUND_ID: &str = "round1";
    const TEST_WALLET_ID: &str = "wallet-id";
```

with:

```rust
    const TEST_ROUND_ID: &str = "round1";
    const TEST_WALLET_ID: &str = "wallet-id";

    /// Testnet NU6.3 activation (`zcash_protocol` TEST_NETWORK: `Nu6_3 =>
    /// 4_134_000`). `zcash_voting` resolves the shielded protocol from the
    /// round's snapshot height and rejects anything that is not NU6.3, so these
    /// fixtures cannot use the pre-Ironwood height-100 rounds they used to.
    const SNAPSHOT_HEIGHT: u64 = 4_134_000;
    /// A later wallet checkpoint, so witness generation has to use the cached
    /// historical frontier rather than the wallet's current tree.
    const LATER_HEIGHT: u32 = 4_134_100;

    /// The Orchard-shaped commitment-tree frontier both pools use. Ironwood is
    /// Orchard-*shaped* — same hash, same depth — while being a separate pool
    /// with a separate tree, which is exactly why reading the wrong one compiles
    /// cleanly and fails only against a live round.
    type VotingFrontier =
        Frontier<MerkleHashOrchard, { orchard::NOTE_COMMITMENT_TREE_DEPTH as u8 }>;
```

- [ ] **Step 4C.7: `delegation.rs` tests — the fixture builders read Ironwood.** Delete the
`tree_state_at_height` helper, which only ever fed the three unit tests of the deleted validator
(step 4C.8 deletes those three tests; between these two steps the module does not compile, which is
expected — the gates run at 4C.11, not between edits) — replace:

```rust
    fn tree_state_at_height(height: u64) -> TreeState {
        TreeState {
            network: "test".to_string(),
            height,
            hash: String::new(),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: String::new(),
            ironwood_tree: String::new(),
        }
    }

    fn round_params(snapshot_height: u64, nc_root: Vec<u8>) -> voting::VotingRoundParams {
```

with:

```rust
    fn round_params(snapshot_height: u64, nc_root: Vec<u8>) -> voting::VotingRoundParams {
```

Then replace the `TreeState` builder — this is the regression guard the whole task hangs on:

```rust
    fn tree_state_from_frontier(
        height: u64,
        frontier: &Frontier<MerkleHashOrchard, { orchard::NOTE_COMMITMENT_TREE_DEPTH as u8 }>,
    ) -> TreeState {
        let commitment_tree = CommitmentTree::from_frontier(frontier);
        let mut orchard_tree_bytes = Vec::new();
        write_commitment_tree(&commitment_tree, &mut orchard_tree_bytes)
            .expect("serialize Orchard tree state");

        TreeState {
            network: "test".to_string(),
            height,
            hash: String::new(),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: bytes_to_hex(&orchard_tree_bytes),
            ironwood_tree: String::new(),
        }
    }
```

with:

```rust
    fn commitment_tree_hex(frontier: &VotingFrontier) -> String {
        let commitment_tree = CommitmentTree::from_frontier(frontier);
        let mut tree_bytes = Vec::new();
        write_commitment_tree(&commitment_tree, &mut tree_bytes)
            .expect("serialize note commitment tree state");
        bytes_to_hex(&tree_bytes)
    }

    /// A frontier deliberately unlike any Ironwood frontier these tests seed.
    fn orchard_decoy_frontier() -> VotingFrontier {
        let mut frontier = VotingFrontier::empty();
        assert!(frontier.append(merkle_hash(77)));
        assert!(frontier.append(merkle_hash(78)));
        frontier
    }

    /// Build the cached round `TreeState` the FFI will read.
    ///
    /// The Ironwood slot carries the voting frontier; the Orchard slot carries a
    /// **different** decoy tree, on purpose. Voting rounds anchor `nc_root` to
    /// the Ironwood pool, so any code path that reads the Orchard tree instead
    /// computes a root that cannot match the round, and every witness test in
    /// this module fails closed. That is precisely the regression `8a40d1f9`
    /// fixed and the `eea6cde8` merge lost — keep the decoy.
    fn tree_state_from_frontier(height: u64, ironwood_frontier: &VotingFrontier) -> TreeState {
        TreeState {
            network: "test".to_string(),
            height,
            hash: String::new(),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: commitment_tree_hex(&orchard_decoy_frontier()),
            ironwood_tree: commitment_tree_hex(ironwood_frontier),
        }
    }
```

Then seed the wallet's Ironwood tree instead of its Orchard tree — replace:

```rust
    fn seed_wallet_orchard_tree(
        wallet_path: &std::path::Path,
        snapshot_height: u64,
        later_height: u32,
        marked_positions: &[Position],
    ) -> (
        Frontier<MerkleHashOrchard, { orchard::NOTE_COMMITMENT_TREE_DEPTH as u8 }>,
        Vec<MerkleHashOrchard>,
    ) {
```

with:

```rust
    /// Seed the wallet's **Ironwood** commitment tree — the pool voting notes
    /// live in, and the pool `zcash_voting` generates historical witnesses from.
    fn seed_wallet_ironwood_tree(
        wallet_path: &std::path::Path,
        snapshot_height: u64,
        later_height: u32,
        marked_positions: &[Position],
    ) -> (VotingFrontier, Vec<MerkleHashOrchard>) {
```

and, in that same function, replace:

```rust
        let mut frontier_tree: Frontier<
            MerkleHashOrchard,
            { orchard::NOTE_COMMITMENT_TREE_DEPTH as u8 },
        > = Frontier::empty();
```

with:

```rust
        let mut frontier_tree: VotingFrontier = Frontier::empty();
```

and replace:

```rust
        wallet_db
            .with_orchard_tree_mut(|tree| {
```

with:

```rust
        wallet_db
            .with_ironwood_tree_mut(|tree| {
```

and replace:

```rust
            .expect("seed wallet Orchard tree");
```

with:

```rust
            .expect("seed wallet Ironwood tree");
```

Finally, the round these fixtures store must be a testnet round: the wallet DB is
`Network::TestNetwork` and the FFI is called with `NETWORK_ID_TESTNET`, and `zcash_voting` now
checks the two against each other (and resolves NU6.3 from the stored network). Replace:

```rust
        queries::insert_round(
            &conn,
            TEST_WALLET_ID,
            voting::Network::Mainnet,
            &params,
            None,
        )
        .expect("insert round");
```

with:

```rust
        // Testnet, to match the wallet DB these tests open and the
        // `NETWORK_ID_TESTNET` the FFI is called with: `zcash_voting` rejects a
        // wallet whose network differs from the round's, and resolves the
        // Ironwood protocol from the stored network's NU6.3 activation height.
        queries::insert_round(
            &conn,
            TEST_WALLET_ID,
            voting::Network::Testnet,
            &params,
            None,
        )
        .expect("insert round");
```

(`open_memory_voting_db()` deliberately stays on `NETWORK_ID_MAINNET`: this FFI takes its own
`network_id` for the wallet DB and the crate reads the round's network from the DB row, so the
handle's network is not consulted on this path. Do not "fix" it — other tests in this module use
that handle with mainnet rounds.)

- [ ] **Step 4C.8: `delegation.rs` tests — retire the validator's unit tests, convert the FFI ones,
add the regression test.** The three unit tests below tested the function step 4C.4 deleted; their
behaviour is covered end-to-end by `generate_note_witnesses_rejects_stale_tree_state_height_through_ffi`
and `..._root_through_ffi`, which exercise the same two rejections through the FFI (now against the
crate's copy of the check). Replace:

```rust
    #[test]
    fn cached_tree_state_validation_accepts_matching_round() {
        let root = [7; 32];
        let tree_state = tree_state_at_height(100);
        let params = round_params(100, root.to_vec());

        assert!(validate_cached_tree_state_for_round(&tree_state, &root, &params).is_ok());
    }

    #[test]
    fn cached_tree_state_validation_rejects_height_mismatch() {
        let root = [7; 32];
        let tree_state = tree_state_at_height(99);
        let params = round_params(100, root.to_vec());

        let error = validate_cached_tree_state_for_round(&tree_state, &root, &params)
            .expect_err("height mismatch must be rejected");
        assert!(
            error
                .to_string()
                .contains("does not match round snapshot_height")
        );
    }

    #[test]
    fn cached_tree_state_validation_rejects_root_mismatch() {
        let tree_state = tree_state_at_height(100);
        let params = round_params(100, vec![7; 32]);

        let error = validate_cached_tree_state_for_round(&tree_state, &[8; 32], &params)
            .expect_err("root mismatch must be rejected");
        assert!(error.to_string().contains("does not match round nc_root"));
    }

    #[test]
    fn validate_pir_proof_accepts_valid() {
```

with:

```rust
    #[test]
    fn validate_pir_proof_accepts_valid() {
```

Then convert the five witness tests to the module-level Ironwood heights and the renamed seeder.
Replace:

```rust
        const SNAPSHOT_HEIGHT: u64 = 100;
        const LATER_HEIGHT: u32 = 200;
        const BUNDLE_INDEX: u32 = 7;

        let wallet_path = temp_sqlite_path("generate_witnesses_success_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_orchard_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

with:

```rust
        const BUNDLE_INDEX: u32 = 7;

        let wallet_path = temp_sqlite_path("generate_witnesses_success_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_ironwood_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

Replace:

```rust
        const SNAPSHOT_HEIGHT: u64 = 100;
        const LATER_HEIGHT: u32 = 200;
        const BUNDLE_INDEX: u32 = 8;

        let wallet_path = temp_sqlite_path("generate_witnesses_multi_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(1), Position::from(2), Position::from(4)];

        let (frontier_tree, leaves) =
            seed_wallet_orchard_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

with:

```rust
        const BUNDLE_INDEX: u32 = 8;

        let wallet_path = temp_sqlite_path("generate_witnesses_multi_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(1), Position::from(2), Position::from(4)];

        let (frontier_tree, leaves) =
            seed_wallet_ironwood_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

Replace:

```rust
        const SNAPSHOT_HEIGHT: u64 = 100;
        const LATER_HEIGHT: u32 = 200;
        const BUNDLE_INDEX: u32 = 9;

        let wallet_path = temp_sqlite_path("generate_witnesses_stale_height_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_orchard_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

with:

```rust
        const BUNDLE_INDEX: u32 = 9;

        let wallet_path = temp_sqlite_path("generate_witnesses_stale_height_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_ironwood_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

Replace:

```rust
        const SNAPSHOT_HEIGHT: u64 = 100;
        const LATER_HEIGHT: u32 = 200;
        const BUNDLE_INDEX: u32 = 10;

        let wallet_path = temp_sqlite_path("generate_witnesses_stale_root_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_orchard_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

with:

```rust
        const BUNDLE_INDEX: u32 = 10;

        let wallet_path = temp_sqlite_path("generate_witnesses_stale_root_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_ironwood_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

Replace:

```rust
        const SNAPSHOT_HEIGHT: u64 = 100;
        const LATER_HEIGHT: u32 = 200;
        const BUNDLE_INDEX: u32 = 12;

        let wallet_path = temp_sqlite_path("generate_witnesses_empty_notes_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = Vec::new();

        let (frontier_tree, _leaves) =
            seed_wallet_orchard_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

with:

```rust
        const BUNDLE_INDEX: u32 = 12;

        let wallet_path = temp_sqlite_path("generate_witnesses_empty_notes_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = Vec::new();

        let (frontier_tree, _leaves) =
            seed_wallet_ironwood_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
```

The empty-frontier test names the pool in its own title; retitle it and use the alias. Replace:

```rust
    fn generate_note_witnesses_rejects_empty_orchard_frontier() {
        const SNAPSHOT_HEIGHT: u64 = 100;
        const BUNDLE_INDEX: u32 = 11;
```

with:

```rust
    fn generate_note_witnesses_rejects_empty_ironwood_frontier() {
        const BUNDLE_INDEX: u32 = 11;
```

and, in that same test, replace:

```rust
        let empty_frontier: Frontier<
            MerkleHashOrchard,
            { orchard::NOTE_COMMITMENT_TREE_DEPTH as u8 },
        > = Frontier::empty();
```

with:

```rust
        let empty_frontier: VotingFrontier = Frontier::empty();
```

Last, add the restored regression test. Append it as the final test in `mod tests` — replace the
module's closing lines:

```rust
        let returned = decode_witnesses(result);
        assert!(returned.is_empty());
        assert_cached_witnesses_match(db, BUNDLE_INDEX, &returned);

        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&wallet_path);
    }
}
```

with:

```rust
        let returned = decode_witnesses(result);
        assert!(returned.is_empty());
        assert_cached_witnesses_match(db, BUNDLE_INDEX, &returned);

        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&wallet_path);
    }

    /// The load-bearing Ironwood-era behaviour, and the regression `8a40d1f9`
    /// fixed before the `eea6cde8` merge silently reverted it: voting notes live
    /// in the Ironwood pool, so witnesses must come from the Ironwood commitment
    /// tree and verify against the round's Ironwood `nc_root` — even though the
    /// cached `TreeState` also carries a different Orchard tree. Reading the
    /// Orchard tree yields a root that can never equal a round's `nc_root`,
    /// which is what shipped against live testnet round `0199de7a…9723` at
    /// snapshot 4179680 and failed every delegation attempt.
    ///
    /// If this test is ever deleted or weakened by a merge, the wrong-pool bug
    /// comes back silently. It is the guard, not decoration.
    #[test]
    fn generate_note_witnesses_uses_ironwood_tree() {
        const BUNDLE_INDEX: u32 = 13;

        let wallet_path = temp_sqlite_path("generate_witnesses_uses_ironwood_wallet");
        let wallet_path_bytes = wallet_path.to_string_lossy().as_bytes().to_vec();
        let note_positions = vec![Position::from(1), Position::from(2)];

        let (frontier_tree, leaves) =
            seed_wallet_ironwood_tree(&wallet_path, SNAPSHOT_HEIGHT, LATER_HEIGHT, &note_positions);
        let ironwood_root = frontier_tree.root().to_bytes().to_vec();
        let orchard_root = orchard_decoy_frontier().root().to_bytes().to_vec();
        assert_ne!(
            ironwood_root, orchard_root,
            "the fixture needs distinguishable pools"
        );

        let tree_state = tree_state_from_frontier(SNAPSHOT_HEIGHT, &frontier_tree);
        assert!(
            !tree_state.orchard_tree.is_empty(),
            "the cached TreeState must carry the decoy Orchard tree"
        );

        let db = open_memory_voting_db();
        store_round_bundle_and_tree_state(
            db,
            SNAPSHOT_HEIGHT,
            BUNDLE_INDEX,
            &note_positions,
            ironwood_root.clone(),
            &tree_state,
        );

        let notes_json = notes_json_for_positions(&leaves, &note_positions);
        let result = call_generate_note_witnesses(
            db,
            BUNDLE_INDEX,
            &wallet_path_bytes,
            notes_json.as_ptr(),
            notes_json.len(),
        );
        assert!(
            !result.is_null(),
            "witness generation must succeed against the Ironwood tree"
        );

        let returned = decode_witnesses(result);
        assert_witnesses_match_positions(&returned, &leaves, &note_positions, &ironwood_root);
        for witness in &returned {
            assert_eq!(
                witness.root, ironwood_root,
                "witness root must be the round's Ironwood nc_root"
            );
            assert_ne!(
                witness.root, orchard_root,
                "witness root must not come from the Orchard tree"
            );
        }
        assert_cached_witnesses_match(db, BUNDLE_INDEX, &returned);

        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&wallet_path);
    }
}
```

- [ ] **Step 4C.9: `util.rs` tests — rename the empty-tree test and restore the both-trees
regression test.** Replace:

```rust
    #[test]
    fn extract_nc_root_returns_empty_orchard_root_for_empty_tree_state() {
```

with:

```rust
    #[test]
    fn extract_nc_root_returns_empty_ironwood_root_for_empty_tree_state() {
```

Then, immediately after that test's closing brace, add the restored regression test — replace:

```rust
        let root = boxed_slice_to_vec(result);
        assert_eq!(root.len(), 32);
        assert_eq!(root, Anchor::empty_tree().to_bytes().to_vec());
    }

    #[test]
    fn verify_witness_returns_zero_for_wrong_root() {
```

with:

```rust
        let root = boxed_slice_to_vec(result);
        assert_eq!(root.len(), 32);
        assert_eq!(root, Anchor::empty_tree().to_bytes().to_vec());
    }

    /// Voting rounds are anchored to the **Ironwood** note commitment tree, so
    /// when the cached `TreeState` carries both pools the extracted `nc_root`
    /// must be the Ironwood root, not the Orchard one. This is the second half
    /// of the `8a40d1f9` fix that the `eea6cde8` merge lost; without it, nothing
    /// in the suite notices which field this FFI reads.
    #[test]
    fn extract_nc_root_returns_ironwood_root_when_both_trees_present() {
        use ff::PrimeField;
        use incrementalmerkletree::frontier::{CommitmentTree, Frontier};
        use orchard::tree::MerkleHashOrchard;
        use pasta_curves::pallas;
        use zcash_primitives::merkle_tree::write_commitment_tree;

        const TREE_DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

        fn merkle_hash(tag: u64) -> MerkleHashOrchard {
            let repr = pallas::Base::from(tag).to_repr();
            MerkleHashOrchard::from_bytes(&repr).expect("small field element is canonical")
        }

        fn frontier_with(tags: &[u64]) -> Frontier<MerkleHashOrchard, TREE_DEPTH> {
            let mut frontier = Frontier::empty();
            for tag in tags {
                assert!(frontier.append(merkle_hash(*tag)));
            }
            frontier
        }

        fn tree_hex(frontier: &Frontier<MerkleHashOrchard, TREE_DEPTH>) -> String {
            let commitment_tree = CommitmentTree::from_frontier(frontier);
            let mut tree_bytes = Vec::new();
            write_commitment_tree(&commitment_tree, &mut tree_bytes)
                .expect("serialize note commitment tree state");
            hex::encode(tree_bytes)
        }

        let orchard_frontier = frontier_with(&[1, 2, 3]);
        let ironwood_frontier = frontier_with(&[7, 8]);
        assert_ne!(
            orchard_frontier.root().to_bytes(),
            ironwood_frontier.root().to_bytes(),
            "test needs distinguishable roots"
        );
        let tree_state = TreeState {
            network: "test".to_string(),
            height: 100,
            hash: String::new(),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: tree_hex(&orchard_frontier),
            ironwood_tree: tree_hex(&ironwood_frontier),
        };
        let tree_state_bytes = tree_state.encode_to_vec();

        let result = unsafe {
            zcashlc_voting_extract_nc_root(tree_state_bytes.as_ptr(), tree_state_bytes.len())
        };

        let root = boxed_slice_to_vec(result);
        assert_eq!(
            root,
            ironwood_frontier.root().to_bytes().to_vec(),
            "nc_root must come from the Ironwood tree"
        );
    }

    #[test]
    fn verify_witness_returns_zero_for_wrong_root() {
```

(`hex` is already a `[dev-dependencies]` entry, so `hex::encode` needs no manifest change. Assert
that before compiling if you like: `grep -n '^hex' Cargo.toml` → `126:hex = "0.4"`.)

- [ ] **Step 4C.10: Swift doc comment.** In
`Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`, replace:

```swift
    /// Extract the 32-byte Orchard note-commitment-tree root from a
    /// protobuf-encoded `TreeState`.
```

with:

```swift
    /// Extract the 32-byte Ironwood note-commitment-tree root from a
    /// protobuf-encoded `TreeState`.
    ///
    /// Voting rounds anchor to the Ironwood pool, so a round's `nc_root` is the
    /// Ironwood tree's root at the snapshot height — not the Orchard tree's.
```

No functional Swift change: this wrapper is a byte pass-through and its signature is unchanged.

- [ ] **Step 4C.11: Rust format + compile gates.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo fmt && cargo fmt -- --check && set -o pipefail && cargo check 2>&1 | tee /tmp/chp-t4c-cargo.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, only the pre-existing `migration_plan_cache.rs:77` warning. An
`unused_imports` warning for `Position`/`Message`/`TreeState` means step 4C.3 or 4C.6 was applied
half-way — fix it, do not `#[allow]` it.

- [ ] **Step 4C.12: Rust test gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo test --lib voting 2>&1 | tee /tmp/chp-t4c-cargotest.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, **`test result: ok. 71 passed; 0 failed`**. The arithmetic, from Task 4B's
72: **−3** (`cached_tree_state_validation_accepts_matching_round`, `…_rejects_height_mismatch`,
`…_rejects_root_mismatch` — the unit tests of the function step 4C.4 deleted; their behaviour is
still covered by the two `generate_note_witnesses_rejects_stale_tree_state_*_through_ffi` tests,
end to end) **+2** (`generate_note_witnesses_uses_ironwood_tree`,
`extract_nc_root_returns_ironwood_root_when_both_trees_present`) **= 71**. Renames do not move the
count. Any other number → something outside this task moved the suite; surface it.

If a witness test fails with `HistoricalWitnessUnavailable` or `HistoricalFrontierInvalid`, do
**not** loosen the assertion or lower the height — report it with the failing test name and the
full error. It would mean the Ironwood shard-tree fixture needs different wallet state than the
Orchard one did, which is a finding, not a nuisance.

- [ ] **Step 4C.13: Symbol baseline — capture BEFORE the rebuild.** This task must not add, remove
or rename a single FFI symbol. Snapshot the current exports first. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && test -d LocalPackages/libzcashlc.xcframework && FW=$(find LocalPackages -name 'libzcashlc' -path '*macos*' | head -1) && nm -gU "$FW" | grep -o '_zcashlc_voting_[a-z0-9_]*' | sort -u > /tmp/chp-t4c-symbols-before.txt; wc -l < /tmp/chp-t4c-symbols-before.txt
```

Expected: a non-zero count (the voting FFI surface Task 5 built). If `LocalPackages/` does not
exist, Task 5 never ran in this worktree — run `./Scripts/init-local-ffi.sh` first (cold, budget
30–60 min for the halo2 voting circuits), then redo this step.

- [ ] **Step 4C.14: Slice rebuild — Rust changed, so the library must be rebuilt.** Three arms are
in use. `rebuild-local-ffi.sh` accepts `ios-sim | ios-device | macos` plus `--universal`, and
**`--universal` is mandatory for `macos` and `ios-sim`**: a host-arch-only rebuild silently
downgrades a formerly-universal slice, which breaks Xcode ARCHIVE (macOS) and any
`generic/platform=iOS Simulator` destination with hundreds of undefined `_zcashlc_*` symbols (it has
bitten this repo repeatedly; the script itself prints a `⚠️ DOWNGRADE` warning when you do it). The
script rebuilds one slice and *preserves* the others, so run all three; they are incremental
against Task 5's `target/` artifacts (minutes each, not the cold init's 30–60). `ios-device`
rejects `--universal` — it is arm64-only by definition. Run, in order:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; ./Scripts/rebuild-local-ffi.sh macos --universal 2>&1 | tee /tmp/chp-t4c-ffi-macos.log | tail -6; echo "REAL_EXIT=$?"
```

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; ./Scripts/rebuild-local-ffi.sh ios-sim --universal 2>&1 | tee /tmp/chp-t4c-ffi-iossim.log | tail -6; echo "REAL_EXIT=$?"
```

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; ./Scripts/rebuild-local-ffi.sh ios-device 2>&1 | tee /tmp/chp-t4c-ffi-iosdev.log | tail -6; echo "REAL_EXIT=$?"
```

Expected for each: `REAL_EXIT=0` and a `Rebuilt <target> (...) in LocalPackages/libzcashlc.xcframework`
line. The `⚠️  preserved existing slice …` lines are normal — that is the script keeping the arms
you are not currently rebuilding. A `⚠️  DOWNGRADE:` line means a `--universal` flag was dropped;
re-run that arm with it. Then verify the archs actually inside each slice:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && for p in macos simulator ios-arm64; do FW=$(find LocalPackages -name 'libzcashlc' -path "*$p*" | head -1); echo "$p -> $(lipo -archs "$FW")"; done
```

Expected: `macos -> arm64 x86_64`, `simulator -> arm64 x86_64`, `ios-arm64 -> arm64`. Anything
narrower is the downgrade trap — rebuild that arm with `--universal`.

- [ ] **Step 4C.15: Symbol-stability assert (the `nm` gate) + header assert.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && FW=$(find LocalPackages -name 'libzcashlc' -path '*macos*' | head -1) && nm -gU "$FW" | grep -o '_zcashlc_voting_[a-z0-9_]*' | sort -u > /tmp/chp-t4c-symbols-after.txt; diff /tmp/chp-t4c-symbols-before.txt /tmp/chp-t4c-symbols-after.txt; echo "SYMBOL_DIFF_EXIT=$?"; grep -c '_zcashlc_voting_generate_note_witnesses\|_zcashlc_voting_extract_nc_root' /tmp/chp-t4c-symbols-after.txt
```

Expected: **no `diff` output at all**, `SYMBOL_DIFF_EXIT=0`, and the grep count is **2**. Any diff
line means this task changed the FFI surface, which it must not — stop and report the exact symbol.
Then confirm the generated header is unchanged in shape:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -c 'zcashlc_voting_extract_nc_root\|zcashlc_voting_generate_note_witnesses' target/Headers/zcashlc.h && git status --short target/ | head -3
```

Expected: `2`, and no tracked change under `target/` (it is a build directory).

- [ ] **Step 4C.16: Swift gates.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; swift build 2>&1 | tee /tmp/chp-t4c-build.log | tail -3; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`. Then:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; swift test --filter OfflineTests 2>&1 | tee /tmp/chp-t4c-test.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, **873 executed, 0 failures** — the count Task 6 recorded. This task adds no
Swift test and changes no Swift behaviour, so the count must not move; if your recorded baseline
differs from 873, use yours and say so in the report. Any failure here after a green
`cargo test --lib voting` points at a stale slice — re-check step 4C.14's `lipo` output.

- [ ] **Step 4C.17: CHANGELOG.** In `CHANGELOG.md`, under `# Unreleased` → `## Fixed`, append this
bullet at the end of that section — immediately before the blank line and the `## Added` heading
that starts `### Custom (regtest-style) networks`:

```markdown
- Voting delegation reads the **Ironwood** note-commitment tree, not the Orchard one. Voting notes
  live in the Ironwood pool and a round's `nc_root` is the Ironwood tree's root at the snapshot
  height, but `zcashlc_voting_generate_note_witnesses` decoded the Orchard tree out of the cached
  `TreeState`, validated that Orchard root against the round's Ironwood `nc_root`, and generated
  witnesses from the wallet's Orchard commitment tree; `VotingRustBackend.extractNcRoot(treeState:)`
  computed the Orchard root too. The two pools are tracked separately and their roots never
  coincide, so every delegation failed with `cached TreeState orchard root does not match round
  nc_root` — on every chain, against every server, for every round. Witness generation now goes
  through `zcash_voting`'s own Ironwood-aware path, which additionally rejects a wallet database
  whose network differs from the round's and a snapshot height that is not NU6.3, and `extractNcRoot`
  returns the Ironwood root. Two regression tests seed a `TreeState` carrying *both* pools and
  assert the Ironwood one wins, so the wrong-pool read cannot return unnoticed.
```

- [ ] **Step 4C.18: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add rust/src/voting/delegation.rs rust/src/voting/util.rs Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift CHANGELOG.md && git commit -m "[#1855] Fix the voting snapshot validation to read the Ironwood tree, restoring the reverted 8a40d1f9" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Expected: one commit, four files. `LocalPackages/` and `target/` are build artifacts — do not add
them. **Do not push:** the SDK remote is push-guarded and Lukas pushes by hand (T16 hands him the
command).

---

**NOTE FOR UPSTREAM.** This regression is not local to the CHP branch. Merge `eea6cde8` landed on
`zcash/zcash-swift-wallet-sdk`'s own `merge/ironwood-slipstream`, and `main`'s `[#1855]` port —
the side that merge deliberately chose, for the sound reason that the feature branch called
`build_vote_commitment`/`sign_cast_vote` while both are `pub(crate)` in the published crate — is
the side that never carried `8a40d1f9`. So upstream `main` reads `TreeState::orchard_tree()` in
both `rust/src/voting/delegation.rs` and `rust/src/voting/util.rs` today, with no test that would
notice, exactly as this branch did before this task. The fix cannot be delivered by reverting that
merge (its resolution is still correct on the compile-against-rc.5 question); it has to be
re-landed on top, which is precisely what this task's diff is. **Task 4C's commit is therefore the
upstream fix candidate** — it applies to `main`'s port as written, touches only the two Rust files
plus one Swift doc comment and the changelog, adds no dependency and changes no FFI symbol. When it
goes up, carry the two regression tests with it: they are the reason a third silent loss becomes a
red test run instead of a dead voting round, and their absence is the whole reason this shipped.
