# CHP_PLAN — App lane (Tasks 7–14)

Authored by the Sonnet app delegate. Every code block below was written by this delegate and is
spliced verbatim into `CHP_PLAN.md`. Verification is entirely static (grep/read against the real
trees) — the app cannot build until the SDK lane's Tasks 1–6 land, so every claim about what the
compiler will say is labeled "expected — confirmed at the T7 enumeration gate."

---

## CORRECTIONS

Spec/skeleton claim vs. tree reality. Reality wins in every row below; the tasks implement reality.

1. **Line-number drift (all "~" approximations in the spec are off by 1–14 lines, direction
   noted).** Real anchors, verified 2026-08-11 against `zodl-ios @ 4cbf054f`:
   `mnemonic.toSeed` hotkey sites are `:1771/:2044/:2630/:2836` (spec said
   `:1770/:2043/:2629/:2835`); the A1 "main path" region is `:1875-1966` (spec said
   `:1872-1930` — the region actually runs ~35 lines longer, through the share-posting loop);
   the first recovery region is `:2159-2210` inside `reducePollShareStatus` (spec said `:2171`
   — that line is mid-block, the callable unit starts at `:2151`); the second recovery region is
   the standalone function `tryRecoverInflightVote` at `:3419-3505` (spec said `:3463` — that
   line is mid-function). `VotingCryptoClientLiveKey.swift:218` is exactly right (verified: the
   line is `let consensusBranchId: UInt32 = 0xC8E7_1055`).

2. **`VotingCryptoClientTestKey.swift` needs ZERO edits for Task 8 or Task 10.** Its entire
   content is:
   ```swift
   #if VOTING_ENABLED
   import ComposableArchitecture
   import Foundation

   extension VotingCryptoClient: TestDependencyKey {
       static let testValue = Self()
   }
   #endif
   ```
   `@DependencyClient` synthesizes an "unimplemented" fatal-error default for every declared
   member automatically; there are no explicit per-member overrides here to update when members
   are added or removed. Likewise `WalletStorageTestKey.swift`'s
   `importVotingHotkey: { _, _ in }` (Task 10) ignores both parameters regardless of type, so a
   parameter-type change there requires no edit either. Both are noted in their tasks below as
   "Verify: no change" steps, not silently dropped.

3. **The spec's "storeCommitmentBundle" is the app's `storeVoteCommitmentBundle` client
   member, and it has three live call sites before Task 8, not zero.** `VotingCryptoClient`
   has no member literally named `storeCommitmentBundle`; the design doc's shorthand refers to
   `storeVoteCommitmentBundle` (`VotingCryptoClientInterface.swift:226-232`), whose `LiveKey`
   implementation calls `backend.storeCommitmentBundle(...)` — a function that does **not
   exist** anywhere in the current `VotingRustBackend.swift` (confirmed: grepping every
   `public func`/`public static func` in that 1940-line file for `storeCommitmentBundle` finds
   nothing; persistence is now internal to `commitVote`). Its coordinator call sites are
   `VotingCoordFlowCoordinator.swift:1888`, `:1937`, `:3460` — all three real and live today.
   "Zero consumers" is Task 8's own **acceptance condition** (checked by grep *after* Task 8
   deletes the member and its three call sites), not a pre-existing fact.

4. **The Keystone decision procedure resolves with certainty, not compiler guesswork — and it
   is bigger than the spec's framing.** `VotingRustBackend.swift:1439-1485` now has exactly
   **one** `getDelegationSubmission`, and its doc comment is unambiguous: *"This is the only
   remaining path: `zcash_voting` no longer derives account keys or signs on the caller's
   behalf, so the SpendAuth signature and the ZIP-244 sighash must come from the wallet's
   signer — whether that signer is a Keystone device or the wallet itself."* Signature:
   `getDelegationSubmission(roundId: String, bundleIndex: UInt32, signature: [UInt8], sighash:
   [UInt8]) throws -> VotingDelegationSubmission`. This confirms the spec's predicted landing
   for the **Keystone** site (`storeKeystoneSignature` already persists the signature
   elsewhere; the "plain submission accessor" — now re-typed to take `signature:`/`sighash:`
   instead of `senderSeed:`/`networkId:`/`accountIndex:` — is a 1:1 fit, since Keystone already
   has an externally-produced signature+sighash in hand). Task 8 implements this cleanly.
   **But** the same unified function is what the app's **software (non-Keystone)** delegation
   path also called, under the OLD name `getDelegationSubmission(roundId:bundleIndex:
   senderSeed:networkId:accountIndex:)` (`VotingCoordFlowCoordinator.swift:3557`, `:3591`,
   inside `runDelegationPipeline`). That path has no externally-produced signature — it relied
   on the crate deriving the key and signing internally from the seed, which no longer happens.
   Grepping every member of `VotingCryptoClient`, `WalletStorageInterface.swift`, and
   `SDKSynchronizerInterface.swift` for a "sign this PCZT with a seed, locally, no hardware"
   primitive finds none (`SDKSynchronizerInterface.swift`'s PCZT surface — lines 318-323 plus
   the migration batch-signing block at 216-268 — is entirely proposal-based or
   Keystone-QR-based, never seed-based). **This is a genuine architecture gap, not a call-site
   wiring problem**, and it is outside A1's six-member table. Task 8 fixes the Keystone site in
   full and surfaces the software-path gap as an explicit, separately-flagged finding rather
   than inventing signing code (forbidden by §0.2) or silently leaving it broken.

5. **`generateHotkey`, `buildVotingPczt` (→ `buildPczt`), and `buildAndProveDelegation` in
   `VotingCryptoClientLiveKey.swift` are stale against the real SDK for reasons that predate
   and exceed A1's table**, and all three are hotkey-secret-shaped, so Task 10 (A3) — not Task 8
   — repairs them:
   - `generateHotkey` (LiveKey `:180-188`) calls `backend.generateHotkey(seed: seed)`, an
     instance method that does not exist. The real function is
     `public static func generateHotkey(networkId: UInt32) throws -> VotingHotkey`
     (`VotingRustBackend.swift:1280`) — no seed in, `VotingHotkey.storedSecret: [UInt8]` out.
   - `buildVotingPczt` (LiveKey `:190-267`) constructs `VotingBuildPcztParams` with seven flat
     fields (`fvk`, `hotkeyRawAddress`, `coinType`, `seedFingerprint`, `accountIndex`,
     `roundName`, `addressIndex`) that do not exist on the type. The real
     `VotingBuildPcztParams` (`VotingTypes.swift:483-503`) has exactly five fields:
     `roundId, bundleIndex, notes, keys: VotingDelegationKeyInputs, consensusBranchId`, where
     `VotingDelegationKeyInputs` (`:458-478`) bundles `fvk, hotkeyStoredSecret, seedFingerprint,
     accountIndex, roundName`.
   - `buildAndProveDelegation` (LiveKey `:298-333`) passes a flat `hotkeyRawAddress:` argument
     that the real function does not take; `buildAndProveDelegation(_ params:
     VotingDelegationProofParams, pirEndpoints:expectedSnapshotHeight:pirResolver:progress:)`
     (`VotingRustBackend.swift:1522`) takes the same `keys: VotingDelegationKeyInputs` bundle.
   - `generateDelegationInputs` (both overloads, `VotingRustBackend.swift:483` and `:517`)
     already take `hotkeyStoredSecret: [UInt8]` as their second parameter, not a derived seed —
     so once Task 10 threads the stored secret through, these two calls need no other change.

6. **The app's `VotingHotkey` model (`VotingModels.swift:257-267`) has a stale shape and no
   verified address encoder.** It is `{ secretKey: Data, publicKey: Data, address: String }`.
   The SDK's `VotingHotkey` (`VotingTypes.swift:50-57`) is
   `{ storedSecret: [UInt8], rawOrchardAddress: [UInt8], addressIndex: UInt32 }` — raw bytes,
   no string. `RoundStateInfo.hotkeyAddress: String?` and
   `VotingCoordFlow.Action.hotkeyLoaded(roundId: String, address: String)`
   (`VotingCoordFlowStore.swift:264`) both require a displayable string. Grepping the app and
   the SDK for a raw-Orchard-address-to-string encoder (`grep -rln
   'func.*OrchardAddress.*String\|rawOrchardAddress'`) finds no encoder anywhere — only the two
   files that declare the raw-bytes field. Task 10 surfaces this as a named finding rather than
   inventing an encoding.

7. **`markVoteSubmitted`'s app-level member is missing the `txHash` parameter the SDK requires.**
   Interface today: `(_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32) async
   throws -> Void` — 3 args. Real SDK: `markVoteSubmitted(roundId:bundleIndex:proposalId:txHash:)
   throws` (`VotingRustBackend.swift:380-408`) — 4 args, `txHash` required ("submission is
   recorded by persisting the transaction, so that a restarted wallet resumes polling for it").
   Task 9 threads it through the interface, `LiveKey`, and both call sites (`:1966`, `:3503`).

8. **T14's "5 flag-gated test files return unmodified (zero porting)" claim is FALSE, and worse
   than the spec's own prescribed grep would catch — headline correction, two independent
   deviations, not one.** The spec's own T14 grep pattern (`buildVoteCommitment|signCastVote|
   buildSharePayloads|encryptShares|decomposeWeight|storeCommitmentBundle|
   getDelegationSubmissionWithKeystoneSig` + `VotingSharePayload|sharePayloads`) finds exactly
   one hit — `VotingCoordFlowCoordinatorTests.swift:1025`,
   ```swift
   dependencies.votingCrypto.getDelegationSubmissionWithKeystoneSig = { _, bundleIndex, sig, sighash in
   ```
   inside `configureKeystoneAuthorizationDependencies(...)` — a real, load-bearing stub (backs
   the Keystone batch-authorization test scenarios), not dead code. **But that pattern itself
   has a blind spot**: it greps for the removed property `.sharePayloads` and the SDK-side type
   `VotingSharePayload`, neither of which matches the *app-level* type `SharePayload` this
   plan's Task 9 also re-shapes. A broader pass (every symbol touched by T8–T13, not just the
   spec's named list) finds a second, larger deviation:
   `VotingServiceConfigTests.swift:931-948`'s `makeRecoverySharePayload(index:)` constructs the
   **old 9-field** `SharePayload(sharesHash:proposalId:voteDecision:encShare:treePosition:
   allEncShares:shareComms:primaryBlind:submitAt:)`, consumed by 7 call sites across two test
   suites (`ShareResubmissionFallbackTests`, `ShareDelegationPostFallbackTests`, lines
   637-818) that exercise `resubmitSharePayload`/`delegateSharePayloads` directly. Good news on
   inspection: every one of those 7 call sites' assertions checks only server-selection/retry
   *behavior* (`postShare: { server, _ in ... }` — the body parameter is discarded, `_`), never
   the payload's internal fields — so this is a **contained, mechanical fix to one helper
   function**, not a rewrite of the test logic. Task 14 specifies both fixes as their own
   explicit steps. Neither is the "zero porting" the spec promised.

9. **`PirSnapshotResolver`'s "already parses `pir_depth`, half exists" claim is true only by
   coincidence of key name.** `PirSnapshotResolver.swift:242,249` does have
   `let pirDepth: Int?` / `case pirDepth = "pir_depth"` — but it is decoding the **PIR server's
   own `/root` `RootInfo` response** (used for snapshot-height matching), a completely separate
   struct from the app's `VotingServiceConfig` (`secant/Sources/Dependencies/VotingModels/
   VotingServiceConfig.swift`), which has **no** `pir_layout`/`pirDepth` field at all today. The
   two are unrelated code paths that happen to share a JSON key name; nothing is reusable
   across them. Task 12 adds the real, independent top-level decode to `VotingServiceConfig`.

10. **Task 13's URL is verified two independent ways and they agree exactly.** (a)
    `gh pr diff 2406 --repo zodl-inc/zodl-android` is reachable and its diff contains the literal
    replacement line. (b) `curl` against the live endpoint + `shasum -a 256`, run independently.
    Both give `sha256:c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d`. See
    `## VERIFICATION EVIDENCE` for the transcripts.

11. **Two `storeVanPosition` call sites become redundant once `confirmVoteSubmission` lands;
    four do not.** `storeVanPosition` is called at six coordinator sites. Two (`:1923` in the
    main vote-cast loop, `:3448` in `tryRecoverInflightVote`) persist the **vote**-side VAN leaf
    position parsed by hand from `leaf_index` — this is exactly the atomic write
    `confirmVoteSubmission` now performs internally (its result carries `vanLeafPosition`), so
    Task 9 deletes both calls along with the hand-parse that fed them. The other four (`:2914`,
    `:3064`, `:3606`, `:3632`) persist the **delegation**-side VAN position inside
    `reduceKeystoneAllBundlesSigned` / `runDelegationPipeline` — an unrelated flow (A2 is the
    *vote* sequence, not the delegation sequence) — and Task 9 does not touch them.

12. **The share-posting transport does not need a new `VotingAPIClient` member — `SharePayload`
    itself is the right place to absorb the shape change.** `VotingAPIClient.delegateShares`/
    `.resubmitShare` (`VotingAPIClientInterface.swift:72-81`) are typed on `[SharePayload]`/
    `SharePayload` (`VotingModels.swift:518-548`), a 9-field struct whose fields
    (`sharesHash, encShare, allEncShares, shareComms, primaryBlind, ...`) are hand-assembled
    into the wire dict by `sharePostBody(for:roundIdHex:submitAt:)`
    (`VotingAPIClientLiveKey.swift:352-380`). None of those fields exist on the crate's
    `recoverWireJson` output — it is a single opaque wire-JSON `String` per share index, and its
    own SDK doc comment says *"POST it verbatim; do not decode, re-shape or re-encode it."*
    Task 9 collapses `SharePayload` to `{ wireJson: String, shareIndex: UInt32 }` and changes
    `sharePostBody` to parse that string straight into the `[String: Any]` body
    (`JSONSerialization.jsonObject(with:)`) instead of hand-building one — this keeps
    `delegateShares`/`resubmitShare`'s **signatures** exactly as-is ("existing transport
    members" is honored literally), changes only the two files §7.5 already names as the
    adaptation surface (`VotingModels.swift`, `VotingAPIClientLiveKey.swift`), and satisfies
    "POST verbatim" (the string is parsed once for the `[String: Any]` calling convention
    already in use, never inspected or altered).

13. **What looked like a share-nullifier gap resolves cleanly — the SDK dropped the parameter,
    not the app's ability to poll.** `computeShareNullifier(voteCommitment:shareIndex:
    primaryBlind:)` itself is unchanged (still needs a `primaryBlind` the app can no longer
    source — see below), but that no longer matters for share-status tracking:
    `VotingRustBackend.recordShareDelegation` (`VotingRustBackend.swift:1142-1149`) is now
    `(roundId:bundleIndex:proposalId:shareIndex:sentToURLs:submitAt:)` — **six** arguments, no
    `nullifier:` — with a doc comment stating why: *"The share's nullifier is no longer
    supplied by the caller: `zcash_voting` derives it from the committed vote's recovery
    state."* The app's own `VotingShareDelegation` (unchanged) still carries `.nullifier:
    String`, now populated by the crate; `getShareDelegations`/`getUnconfirmedDelegations`
    (both unchanged) read it back for `fetchShareStatus`'s nullifier-keyed polling. Task 9 drops
    the now-nonexistent `nullifier:` argument from the app's `recordShareDelegation` member and
    stops calling `computeShareNullifier` for this purpose entirely — it was never needed as an
    *input* to recording, only as a workaround for the old SDK requiring one.

14. **Task 8's app-level `commitVote` member is designed to return the existing
    `(VoteCommitmentBundle, CastVoteSignature)` pair, not a new type.** `VotingCommit`'s SDK
    fields map onto `VoteCommitmentBundle`'s existing (mostly-defaulted) fields with one
    exception — `voteAuthSig`, previously `signCastVote`'s separate output — so the app-level
    `commitVote` returns the same two-value shape `submitVoteCommitment(bundle:signature:)`
    already consumes verbatim. This keeps `VotingAPIClientInterface.swift` (an explicitly frozen
    "transport role" file per `CHP_DESIGN.md` §7.5) completely untouched, at the cost of one
    field, `sharesHash: Data`, being populated with an unused empty `Data()` — verified dead for
    this call: `VotingAPIClientLiveKey.swift:912-933`'s wire-body construction never reads
    `bundle.sharesHash`, `.shareBlindFactors`, `.shareComms`, `.alphaV`, or `.encShares`.

---

## VERIFICATION EVIDENCE

**pbxproj build-configuration anchors** (`secant.xcodeproj/project.pbxproj`, read directly, all
line numbers exact at HEAD `4cbf054f`):

| Target | Config UUID | Lines | Current `SWIFT_ACTIVE_COMPILATION_CONDITIONS` |
|---|---|---|---|
| zodl-testnet | `9E41FFB82CB2814500783CFD` | 873-901 (Debug) | `"DEBUG UNREDACTED SECANT_TESTNET"` |
| zodl-testnet | `9E41FFB92CB2814500783CFD` | 903-930 (Release-Testflight) | `SECANT_TESTNET` |
| zodl-testnet | `9E41FFBA2CB2814500783CFD` | 932-959 (Release-AppStore) | `SECANT_TESTNET` |
| zodl-internal | `9E5AB47F2C94777800065483` | 1159-1187 (Debug) | `"DEBUG UNREDACTED SECANT_MAINNET"` |
| zodl-internal | `9E5AB4802C94777800065483` | 1189-1216 (Release-Testflight) | `SECANT_MAINNET` |
| zodl-internal | `9E5AB4812C94777800065483` | 1218-1245 (Release-AppStore) | `SECANT_MAINNET` |
| zodl-production | `9E4AB2B52BA1BEE900F5D6DB` | 961-1000 (Debug) | `"DEBUG UNREDACTED SECANT_MAINNET"` — **left alone** |
| zodl-production | `9E4AB2B62BA1BEE900F5D6DB` | 1001-1039 (Release-Testflight) | `SECANT_MAINNET` — **left alone** |
| zodl-production | `9E4AB2BF2BA1C05100F5D6DB` | 1120-1158 (Release-AppStore) | `"SECANT_MAINNET SECANT_DISTRIB"` — **left alone** |

Target→config-list mapping traced through `PBXNativeTarget` (lines 269-389) →
`XCConfigurationList` (lines 1270-1298); confirmed each list holds exactly 3 configs
(Debug/Release-Testflight/Release-AppStore) and no `VOTING_ENABLED` exists anywhere in the file
today (`grep -c VOTING_ENABLED project.pbxproj` → 0).

**Member reference counts** (all via `grep -n`, `zodl-ios @ 4cbf054f`):

| Symbol | Hits | Where |
|---|---|---|
| `buildVoteCommitment(` (coordinator call) | 1 | `:1876` |
| `signCastVote(` (coordinator call) | 1 | `:1890` |
| `buildSharePayloads(` (coordinator call) | 3 | `:1926`, `:2171`, `:3463` |
| `storeVoteCommitmentBundle(` (coordinator call) | 3 | `:1888`, `:1937`, `:3460` |
| `.encryptShares`/`.decomposeWeight` (coordinator call) | 0 | only referenced inside `VotingCryptoClientLiveKey.swift` itself (`:337-353`) |
| `getDelegationSubmissionWithKeystoneSig(` (coordinator call) | 1 | `:2900` |
| `getDelegationSubmission(` (coordinator call, plain) | 2 | `:3557`, `:3591` |
| `markVoteSubmitted(` (coordinator call) | 2 | `:1966`, `:3503` |
| `mnemonic.toSeed(` (all sites) | 7 | `:987` (hotkey gen), `:1771`/`:2044`/`:2630`/`:2836` (hotkey use), `:1777`/`:2834` (sender seed — untouched) |
| `leaf_index` (all sites) | 7 | `cast_vote` reads at `:1905`,`:1912`(split),`:3438`,`:3441`(split); `delegate_vote` reads at `:3062`,`:3684` (delegation flow — untouched by A2) |
| `storeVanPosition(` (all sites) | 6 | `:1923`,`:3448` (vote-side, deleted by T9); `:2914`,`:3064`,`:3606`,`:3632` (delegation-side, untouched) |
| `#if VOTING_ENABLED` | 50 files | full list captured; unchanged by any task here |
| Spec's own T14 grep pattern, across the 5 `zodlTests/VotingTests/*.swift` files | 1 | `VotingCoordFlowCoordinatorTests.swift:1025` only |
| Broader T8–T13-symbol grep (adds app-level `SharePayload(`/`resubmitSharePayload`/`markVoteSubmitted(`/etc.), same 5 files | 8 (1 + 7) | `VotingCoordFlowCoordinatorTests.swift:1025`; `VotingServiceConfigTests.swift:637,659,687,714,752,785,818` (all via one helper, `:931-948`) |

**Real current SDK signatures transcribed from `VotingRustBackend.swift`**
(`zcash-swift-wallet-sdk @ a3823651`, pre-Task-1-4, unaffected by the SDK lane's changes since
none of Tasks 1-4 touch these):

```swift
// :344-355
public func commitVote(
    roundId: String, bundleIndex: UInt32, hotkeyStoredSecret: [UInt8], proposalId: UInt32,
    choice: UInt32, numOptions: UInt32, voteCommitmentTreePosition: UInt64,
    vanWitness: VotingVanWitness, singleShare: Bool,
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> VotingVoteCommit

// :380-385
public func markVoteSubmitted(
    roundId: String, bundleIndex: UInt32, proposalId: UInt32, txHash: String
) throws

// :1439-1444
public func getDelegationSubmission(
    roundId: String, bundleIndex: UInt32, signature: [UInt8], sighash: [UInt8]
) throws -> VotingDelegationSubmission

// :1280
public static func generateHotkey(networkId: UInt32) throws -> VotingHotkey
// VotingHotkey (VotingTypes.swift:50-57): storedSecret/rawOrchardAddress/addressIndex

// :1046-1052, :1099
public func storeKeystoneSignature(roundId: String, bundleIndex: UInt32, sig: [UInt8], sighash: [UInt8], randomizedKey: [UInt8]) throws
public func getKeystoneSignatures(roundId: String) throws -> [VotingKeystoneSignatureRecord]

// :1006-1010
public func getCommitmentBundle(roundId: String, bundleIndex: UInt32, proposalId: UInt32) throws -> VotingStoredCommitmentBundle?
// VotingStoredCommitmentBundle (VotingTypes.swift:561-568): { bundleJson: String, voteCommitmentTreePosition: UInt64 }
```

`confirmVoteSubmission(roundId:bundleIndex:proposalId:txHash:eventsJson:) -> VotingVoteConfirmation`
and `static recoverWireJson(commitmentBundleJson:proposalId:shareIndex:voteCommitmentTreePosition:
submitAt:) -> String` are **not yet in the tree** — they are SDK-lane Task 3's deliverable, taken
verbatim from `## INTERFACES-FOR-APP` in `plan-sdk-tasks.md`.

**T13 URL verification** (both run 2026-08-11, independently, results identical):

```
$ gh pr diff 2406 --repo zodl-inc/zodl-android | grep -i "voting.valargroup\|checksum"
+        // The old pin (commit 2785311d, checksum bed0116f) is now frozen for backwards
-                "?checksum=sha256:bed0116f961226b256a574b52461ce81d9f5294a57e190987dc155f07eb1e431"
+            "https://voting.valargroup.org/prod/static-voting-config.json" +
+                "?checksum=sha256:c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d"

$ curl -s -o /tmp/svc.json -w "HTTP_STATUS=%{http_code}\n" "https://voting.valargroup.org/prod/static-voting-config.json"
HTTP_STATUS=200
$ shasum -a 256 /tmp/svc.json
c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d  /tmp/svc.json
```

Final URL (verified, complete, no placeholder):
`https://voting.valargroup.org/prod/static-voting-config.json?checksum=sha256:c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d`

---

## TASK 7

### Task 7: A7 — flag on (internal+testnet) = the enumeration gate

*Code blocks by: Sonnet (app delegate).*

**Files:**
- Modify: `secant.xcodeproj/project.pbxproj` (6 build configurations, exact UUIDs above)

**Interfaces:**
- Consumes: nothing (build-settings only).
- Produces: `/tmp/chp-t7-errors.txt` — the authoritative T8–T13 work list.

---

- [ ] **Step 7.1: Flip `zodl-testnet` Debug.** In `secant.xcodeproj/project.pbxproj`, in the
block `9E41FFB82CB2814500783CFD /* Debug */` (lines 873-901), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_TESTNET";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E41FFB92CB2814500783CFD /* Release-Testflight */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_TESTNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E41FFB92CB2814500783CFD /* Release-Testflight */ = {
```

(The trailing UUID line is included only so the match is unambiguous — it is not itself edited.)

- [ ] **Step 7.2: Flip `zodl-testnet` Release-Testflight.** In the same file, in the block
`9E41FFB92CB2814500783CFD /* Release-Testflight */` (lines 903-930), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_TESTNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E41FFBA2CB2814500783CFD /* Release-AppStore */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_TESTNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E41FFBA2CB2814500783CFD /* Release-AppStore */ = {
```

- [ ] **Step 7.3: Flip `zodl-testnet` Release-AppStore.** In the same file, in the block
`9E41FFBA2CB2814500783CFD /* Release-AppStore */` (lines 932-959), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_TESTNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
		9E4AB2B52BA1BEE900F5D6DB /* Debug */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_TESTNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
		9E4AB2B52BA1BEE900F5D6DB /* Debug */ = {
```

(The trailing UUID line here is `zodl-production`'s Debug block header — included only to prove
this edit stops before touching production, and is not itself modified.)

- [ ] **Step 7.4: Flip `zodl-internal` Debug.** In the same file, in the block
`9E5AB47F2C94777800065483 /* Debug */` (lines 1159-1187), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_MAINNET";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E5AB4802C94777800065483 /* Release-Testflight */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_MAINNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E5AB4802C94777800065483 /* Release-Testflight */ = {
```

- [ ] **Step 7.5: Flip `zodl-internal` Release-Testflight.** In the same file, in the block
`9E5AB4802C94777800065483 /* Release-Testflight */` (lines 1189-1216), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_MAINNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E5AB4812C94777800065483 /* Release-AppStore */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_MAINNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E5AB4812C94777800065483 /* Release-AppStore */ = {
```

- [ ] **Step 7.6: Flip `zodl-internal` Release-AppStore.** In the same file, in the block
`9E5AB4812C94777800065483 /* Release-AppStore */` (lines 1218-1245), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_MAINNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
/* End XCBuildConfiguration section */
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_MAINNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
/* End XCBuildConfiguration section */
```

(The trailing marker comment is the literal end of the `XCBuildConfiguration` section in this
file — included to prove this is the last of the six edits.)

- [ ] **Step 7.7: Verify exactly 6 hits, and that `zodl-production` has none.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -c 'VOTING_ENABLED' secant.xcodeproj/project.pbxproj
```

Expected: `6`. Then run — three separate per-block checks, not one range scan: a single
`Debug`-to-`Release-AppStore` awk range is unsafe here because `9E4AB2BA2BA1C05100F5D6DB /*
Release-AppStore */` (line 1040) is a *different*, non-`zodl-production` block that happens to
share that name and sit right after `zodl-production`'s Release-Testflight config — a range
ending there stops around line 1040 and never reaches `zodl-production`'s own real
Release-AppStore block, `9E4AB2BF2BA1C05100F5D6DB` (lines 1120-1158). Every boundary UUID below
also has a *second*, harmless-looking occurrence later in the file, inside its target's own
`XCConfigurationList` `buildConfigurations = (...)` reference array (e.g.
`9E4AB2B52BA1BEE900F5D6DB /* Debug */,` around line 1283) — an `awk` range re-opens on any
repeat match of its start pattern, so a boundary without the trailing ` = {` silently re-fires
there and can leak a second, unwanted chunk into the count (verified empirically: it happens to
add 0 in this file today only because those reference lines never contain the literal string
`VOTING_ENABLED` — not something to rely on). Anchoring every boundary on the block-definition
form, `UUID /* Name */ = {`, makes it match only the one real block header:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios
awk '/9E4AB2B52BA1BEE900F5D6DB \/\* Debug \*\/ = \{/,/9E4AB2B62BA1BEE900F5D6DB \/\* Release-Testflight \*\/ = \{/' secant.xcodeproj/project.pbxproj | grep -c VOTING_ENABLED
awk '/9E4AB2B62BA1BEE900F5D6DB \/\* Release-Testflight \*\/ = \{/,/9E4AB2BA2BA1C05100F5D6DB \/\* Release-AppStore \*\/ = \{/' secant.xcodeproj/project.pbxproj | grep -c VOTING_ENABLED
awk '/9E4AB2BF2BA1C05100F5D6DB \/\* Release-AppStore \*\/ = \{/,/9E5AB47F2C94777800065483 \/\* Debug \*\/ = \{/' secant.xcodeproj/project.pbxproj | grep -c VOTING_ENABLED
```

Expected: `0`, `0`, `0` — one per real `zodl-production` config (Debug, Release-Testflight, and
its actual Release-AppStore block via `9E4AB2BF2BA1C05100F5D6DB`, each isolated by scanning to
the *next* real block-definition header — `zodl-internal`'s own Debug config, in the third
check — so no later block's settings can leak in). Verified directly against the post-T7 tree:
these three commands print `41`, `40`, `40` total lines respectively (matching each block's true
span exactly, with no re-triggered second chunk), and `0`, `0`, `0` for the `VOTING_ENABLED`
count. Any other count on any of the four checks (this trio plus the total-6 check above) → the
edits landed in the wrong block; revert and redo before proceeding.

- [ ] **Step 7.8: Full internal-scheme build, capturing the complete log.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t7-full.log | tail -20; echo "REAL_EXIT=$?"
```

Expected: **`REAL_EXIT` non-zero** — this is the red-by-design step. A zero exit here is itself
a finding to surface (it would mean the flag flip alone didn't expose the six-item disposition
gap, contradicting every piece of evidence in this plan) — do not treat it as success without
reporting it first.

- [ ] **Step 7.9: Extract the authoritative error list.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -E '(error:|error [A-Z]+[0-9]+:)' /tmp/chp-t7-full.log | sort -u > /tmp/chp-t7-errors.txt; wc -l /tmp/chp-t7-errors.txt
```

Report the full contents of `/tmp/chp-t7-errors.txt` verbatim. Map every line to exactly one of:
Task 8 (the six-member disposition + the Keystone unification), Task 9 (the vote sequence +
`SharePayload`/transport reshape), Task 10 (hotkey container + `generateHotkey`/`buildVotingPczt`/
`buildAndProveDelegation`), Task 11 (the branch-ID literal), Task 12 (`pirLayout`), Task 13 (the
static-config URL — unlikely to be a compile error, but check), or the two explicit findings this
plan already carries forward from `## CORRECTIONS` items 4 and 6 (the software delegation-signing
gap; the hotkey-address encoding gap). **Any error that maps to none of these is a new finding —
surface it, do not silently fold it into an existing task's diff.**

- [ ] **Step 7.10: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant.xcodeproj/project.pbxproj && git commit -m "[MOB-1678] Enable VOTING_ENABLED for internal and testnet configurations" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 8

### Task 8: A1 — pipeline collapse (six members → `commitVote`) + the Keystone unification

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` items 3–5 and 14 first. This task closes: `buildVoteCommitment`,
`signCastVote`, `buildSharePayloads` (main-path call site only — the two recovery-path call
sites at `:2171`/`:3463` are Task 9's, since they are inseparable from the confirm/recover
rewrite), `encryptShares`, `decomposeWeight`, `storeVoteCommitmentBundle` (main-path call site
only — same reason for its other two sites), and the Keystone half of item 4's finding.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift:29` (step 8.0) and elsewhere (steps 8.1-8.4, 8.14)
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Verify (no edit expected): `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientTestKey.swift`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:144-155` (step 8.0, database open), `:1875-1893` (main construction), `:2900` (Keystone submission), `:3557`/`:3591`-region (step 8.14, software signing)

**Interfaces:**
- Consumes: `VotingRustBackend.open(path: String, networkId: UInt32) throws` (`VotingRustBackend.swift:72`, real, unaffected by the SDK lane); `VotingRustBackend.commitVote(roundId:bundleIndex:hotkeyStoredSecret:proposalId:choice:numOptions:voteCommitmentTreePosition:vanWitness:singleShare:progress:) async throws -> VotingVoteCommit` and `VotingRustBackend.getDelegationSubmission(roundId:bundleIndex:signature:sighash:) throws -> VotingDelegationSubmission` (both real, current, unaffected by SDK-lane Tasks 1–4 — see `## VERIFICATION EVIDENCE`); `VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)` (SDK-lane Task 4B, step 8.14).
- Produces: `VotingCryptoClient.openDatabase(_ path: String, _ networkId: UInt32) async throws -> Void`; `VotingCryptoClient.commitVote(...) async throws -> (bundle: VoteCommitmentBundle, signature: CastVoteSignature)`; `VotingCryptoClient.getDelegationSubmission(...)` re-typed to `(_ roundId: String, _ bundleIndex: UInt32, _ signature: Data, _ sighash: Data) async throws -> DelegationRegistration`, consumed by plan Task 9 (the confirm/recover rewrite) and by Task 8's own Keystone call-site fix; `VotingCryptoClient.signDelegationRequest(...)` (step 8.14).

---

- [ ] **Step 8.0: Thread `networkId` through the voting-database open call.** T7's red-build
enumeration surfaced a compile error no other step in this plan (or in `CHP_DESIGN.md` §3's
A1-A6 list) covers: `VotingCryptoClientLiveKey.swift`'s `DatabaseActor.open` calls
`b.open(path: path)`, but the real SDK signature is `open(path: String, networkId: UInt32)
throws` (`VotingRustBackend.swift:72` in the SDK worktree — this function is outside every
`Files:` list in the SDK lane's Tasks 1-4B, so it was never touched; the mismatch predates this
campaign). The app-level `openDatabase` member never carried a `networkId` parameter either.
Verify both anchors first:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "func open(path: String) throws" secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift
grep -n "public func open(path" ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift
```

Expected: one hit each — `DatabaseActor.open`'s old 1-arg signature in the app, and the real
2-arg `open(path:networkId:)` in the SDK. Then locate the one call site:

```bash
grep -n "votingCrypto.openDatabase" secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift
```

Expected: exactly one hit, `:155`, inside the `.serviceConfigLoaded` reducer case — the only
place the app opens the voting database. `networkId` is sourced the same way every other
`VotingCryptoClient` member in this file already does it (5 sites: `:808-810`, `:1725-1726`,
`:2037-2038`, `:2594-2595`, `:2804-2805`) — `zcashSDKEnvironment.network().networkType.
votingRustNetworkId` — not invented here.

First, the interface. In `VotingCryptoClientInterface.swift`, replace:

```swift
    // --- Database lifecycle ---
    var openDatabase: @Sendable (_ path: String) async throws -> Void
    var setWalletId: @Sendable (_ walletId: String) async throws -> Void
```

with:

```swift
    // --- Database lifecycle ---
    var openDatabase: @Sendable (_ path: String, _ networkId: UInt32) async throws -> Void
    var setWalletId: @Sendable (_ walletId: String) async throws -> Void
```

Second, the `LiveKey` closure. In `VotingCryptoClientLiveKey.swift`, replace:

```swift
            openDatabase: { path in
                try await dbActor.open(path: path)
            },
```

with:

```swift
            openDatabase: { path, networkId in
                try await dbActor.open(path: path, networkId: networkId)
            },
```

Third, `DatabaseActor` itself. In the same file, replace:

```swift
    func open(path: String) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        if let old = _backend {
            old.close()
            _backend = nil
        }
        let b = VotingRustBackend()
        try b.open(path: path)
        _backend = b
    }
```

with:

```swift
    func open(path: String, networkId: UInt32) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        if let old = _backend {
            old.close()
            _backend = nil
        }
        let b = VotingRustBackend()
        try b.open(path: path, networkId: networkId)
        _backend = b
    }
```

Fourth, the one call site. In `VotingCoordFlowCoordinator.swift`, replace:

```swift
            case .serviceConfigLoaded(let config):
                state.serviceConfig = config
                let walletId = state.walletId
                return .run { [votingAPI, votingCrypto] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Open the voting DB and scope it to this wallet.
                    let dbPath = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("voting.sqlite3").path
                    try await votingCrypto.openDatabase(dbPath)
                    try await votingCrypto.setWalletId(walletId)
```

with:

```swift
            case .serviceConfigLoaded(let config):
                state.serviceConfig = config
                let walletId = state.walletId
                let network = zcashSDKEnvironment.network()
                let networkId: UInt32 = network.networkType.votingRustNetworkId
                return .run { [votingAPI, votingCrypto, networkId] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Open the voting DB and scope it to this wallet.
                    let dbPath = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("voting.sqlite3").path
                    try await votingCrypto.openDatabase(dbPath, networkId)
                    try await votingCrypto.setWalletId(walletId)
```

`zcashSDKEnvironment.network()` / `.networkType.votingRustNetworkId` is the exact two-line idiom
already used at the five sites listed above — reused here, not invented — and it must be
computed in the reducer's synchronous body (before `.run`, as shown), then added to the
closure's explicit capture list, the same pattern every other `.run` site in this file already
follows for values it needs from outside the closure.

Finally, confirm this was the only call site (so no second one was missed):

```bash
grep -rn '\.openDatabase(' secant/Sources/ zodlTests/
```

Expected: exactly one hit, the now-two-argument call inside `.serviceConfigLoaded` above. Any
other hit — including in a test file — is a second call site this step must also fix before
proceeding to step 8.1.

- [ ] **Step 8.1: Delete `decomposeWeight` and `encryptShares` from the interface.** In
`VotingCryptoClientInterface.swift`, delete these two members (lines 125-129):

```swift
    var decomposeWeight: @Sendable (_ weight: UInt64) -> [UInt64] = { _ in [] }
    var encryptShares: @Sendable (
        _ roundId: String,
        _ shares: [UInt64]
    ) async throws -> [EncryptedShare]
```

Grep evidence both are zero-consumer in the coordinator: `## VERIFICATION EVIDENCE`, "Member
reference counts" table.

- [ ] **Step 8.2: Delete `buildVoteCommitment` and `signCastVote`, add `commitVote`.** In the
same file, replace:

```swift
    var buildVoteCommitment: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ anchorHeight: UInt32,
        _ singleShare: Bool
    ) -> AsyncThrowingStream<VoteCommitmentBuildEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    var buildSharePayloads: @Sendable (
        _ encShares: [EncryptedShare],
        _ commitment: VoteCommitmentBundle,
        _ voteDecision: VoteChoice,
        _ numOptions: UInt32,
        _ vcTreePosition: UInt64,
        _ singleShare: Bool
    ) async throws -> [SharePayload]
```

with:

```swift
    /// Build, sign, and persist the cast-vote commitment for one proposal in a single call.
    /// Replaces the former three-member sequence — build the commitment, sign the cast vote,
    /// build the share payloads — because `zcash_voting` now owns that orchestration
    /// internally and the intermediate artifacts are no longer separable steps.
    ///
    /// `voteCommitmentTreePosition` must be `0` for the provisional call in the sanctioned
    /// sequence (plan Task 9, spec `CHP_DESIGN.md` §3/A2 step 1) — the true position is not
    /// known until the cast-vote transaction confirms on chain. The call is idempotent:
    /// repeating it for the same (round, bundle, proposal) returns the persisted recovery
    /// bundle rather than re-proving.
    ///
    /// `hotkeyStoredSecret` is the voting hotkey's stored secret bytes (plan Task 10), not a
    /// derived seed. The returned pair feeds `VotingAPIClient.submitVoteCommitment(bundle:
    /// signature:)` verbatim — `bundle.sharesHash` is populated empty; `submitVoteCommitment`'s
    /// wire-body construction never reads it (verified: `VotingAPIClientLiveKey.swift:912-933`).
    // swiftlint:disable:next function_parameter_count
    var commitVote: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeyStoredSecret: [UInt8],
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ vanAnchorHeight: UInt32,
        _ singleShare: Bool
    ) async throws -> (bundle: VoteCommitmentBundle, signature: CastVoteSignature)
```

Also delete the now-orphaned `signCastVote` member (currently between `resetTreeClient` and
`extractNcRoot`):

```swift
    /// Decompress r_vpk and sign the canonical cast-vote sighash.
    /// Call after `buildVoteCommitment` completes, before `submitVoteCommitment`.
    var signCastVote: @Sendable (
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ bundle: VoteCommitmentBundle
    ) async throws -> CastVoteSignature
```

with nothing (delete the four lines and the one blank line that follows them, leaving exactly
one blank line before `/// Extract the Orchard nc_root from a protobuf-encoded TreeState.`).

- [ ] **Step 8.3: Delete `storeVoteCommitmentBundle`.** In the same file, delete (lines 224-232):

```swift
    /// Persist the vote commitment bundle + VC tree position before TX submission.
    /// Required for share delegation if the app crashes between TX confirm and share send.
    var storeVoteCommitmentBundle: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ bundle: VoteCommitmentBundle,
        _ vcTreePosition: UInt64
    ) async throws -> Void
```

- [ ] **Step 8.4: Unify `getDelegationSubmission` and delete `getDelegationSubmissionWithKeystoneSig`.**
In the same file, replace:

```swift
    /// Reconstruct the full chain-ready delegation TX payload from DB + seed.
    /// Call after `buildAndProveDelegation` completes.
    var getDelegationSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32
    ) async throws -> DelegationRegistration
    /// Reconstruct the delegation TX payload using a Keystone-provided signature.
    /// Uses the externally-provided signature and ZIP-244 sighash instead of
    /// deriving `ask` from seed.
    var getDelegationSubmissionWithKeystoneSig: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ keystoneSig: Data,
        _ keystoneSighash: Data
    ) async throws -> DelegationRegistration
```

with:

```swift
    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash. `zcash_voting` no longer derives account keys
    /// or signs on the caller's behalf, so an externally-produced signature is the only
    /// remaining path — this one member now serves both the Keystone-signed call site
    /// (`VotingCoordFlowCoordinator.swift:2900`, signature off the scanned QR) and the
    /// software-signed call sites (`:3557`, `:3591` — see this task's step 8.10 finding for
    /// their unresolved signature source).
    var getDelegationSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ signature: Data,
        _ sighash: Data
    ) async throws -> DelegationRegistration
```

- [ ] **Step 8.5: Add the `malformedWireShare` error case the new `commitVote` implementation
needs.** This is prepared here so step 8.6 compiles; `VotingCryptoError` lives in
`VotingCryptoClientLiveKey.swift`, edited next.

---

- [ ] **Step 8.6: Delete `decomposeWeight`/`encryptShares`/`buildVoteCommitment`/
`signCastVote`/`buildSharePayloads`, add `commitVote`, in the LiveKey.** In
`VotingCryptoClientLiveKey.swift`, replace (lines 337-484 — from the `decomposeWeight` closure
through the end of the `buildSharePayloads` closure):

```swift
            decomposeWeight: { weight in
                (try? VotingRustBackend.decomposeWeight(weight)) ?? []
            },
            encryptShares: { roundId, shares in
                let backend = try await dbActor.backend()
                let wireShares: [VotingWireEncryptedShare] = try backend.encryptShares(
                    roundId: roundId,
                    shares: shares
                )
                return wireShares.map { (share: VotingWireEncryptedShare) -> EncryptedShare in
                    EncryptedShare(
                        c1: Data(share.ciphertext1),
                        c2: Data(share.ciphertext2),
                        shareIndex: share.shareIndex
                    )
                }
            },
            // swiftlint:disable:next line_length
            buildVoteCommitment: { roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice, numOptions, vanAuthPath, vanPosition, anchorHeight, singleShare in
                AsyncThrowingStream<VoteCommitmentBuildEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let vanWitness = try VotingVanWitness.make(
                                authPath: vanAuthPath.map { [UInt8]($0) },
                                position: vanPosition,
                                anchorHeight: anchorHeight
                            )
                            let result = try await backend.buildVoteCommitment(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                hotkeySeed: hotkeySeed,
                                networkId: networkId,
                                proposalId: proposalId,
                                choice: choice.ffiValue,
                                numOptions: numOptions,
                                vanWitness: vanWitness,
                                singleShare: singleShare,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            publishState(backend: backend, roundId: roundId)
                            let vanNullifier: Data = Data(result.vanNullifier)
                            let voteAuthorityNoteNew: Data = Data(result.voteAuthorityNoteNew)
                            let voteCommitment: Data = Data(result.voteCommitment)
                            let proof: Data = Data(result.proof)
                            let sharesHash: Data = Data(result.sharesHash)
                            let rVpkBytes: Data = Data(result.rVpkBytes)
                            let alphaV: Data = Data(result.alphaV)
                            let encShares: [EncryptedShare] = result.encShares.map { share in
                                EncryptedShare(
                                    c1: Data(share.ciphertext1),
                                    c2: Data(share.ciphertext2),
                                    shareIndex: share.shareIndex
                                )
                            }
                            let shareBlindFactors: [Data] = result.shareBlinds.map { Data($0) }
                            let shareComms: [Data] = result.shareComms.map { Data($0) }
                            let bundle = VoteCommitmentBundle(
                                vanNullifier: vanNullifier,
                                voteAuthorityNoteNew: voteAuthorityNoteNew,
                                voteCommitment: voteCommitment,
                                proposalId: proposalId,
                                proof: proof,
                                encShares: encShares,
                                anchorHeight: result.anchorHeight,
                                voteRoundId: result.voteRoundId,
                                sharesHash: sharesHash,
                                shareBlindFactors: shareBlindFactors,
                                shareComms: shareComms,
                                rVpkBytes: rVpkBytes,
                                alphaV: alphaV
                            )
                            continuation.yield(.completed(bundle))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
            buildSharePayloads: { encShares, commitment, voteDecision, numOptions, vcTreePosition, singleShare in
                let backend = try await dbActor.backend()
                let sdkShares = encShares.map {
                    VotingWireEncryptedShare(
                        ciphertext1: [UInt8]($0.c1),
                        ciphertext2: [UInt8]($0.c2),
                        shareIndex: $0.shareIndex
                    )
                }
                let vanNullifier: [UInt8] = [UInt8](commitment.vanNullifier)
                let voteAuthorityNoteNew: [UInt8] = [UInt8](commitment.voteAuthorityNoteNew)
                let voteCommitment: [UInt8] = [UInt8](commitment.voteCommitment)
                let proof: [UInt8] = [UInt8](commitment.proof)
                let sharesHash: [UInt8] = [UInt8](commitment.sharesHash)
                let shareBlinds: [[UInt8]] = commitment.shareBlindFactors.map { [UInt8]($0) }
                let shareComms: [[UInt8]] = commitment.shareComms.map { [UInt8]($0) }
                let rVpkBytes: [UInt8] = [UInt8](commitment.rVpkBytes)
                let alphaV: [UInt8] = [UInt8](commitment.alphaV)
                let sdkCommitment = VotingVoteCommitmentBundle(
                    vanNullifier: vanNullifier,
                    voteAuthorityNoteNew: voteAuthorityNoteNew,
                    voteCommitment: voteCommitment,
                    proposalId: commitment.proposalId,
                    proof: proof,
                    encShares: sdkShares,
                    anchorHeight: commitment.anchorHeight,
                    voteRoundId: commitment.voteRoundId,
                    sharesHash: sharesHash,
                    shareBlinds: shareBlinds,
                    shareComms: shareComms,
                    rVpkBytes: rVpkBytes,
                    alphaV: alphaV
                )
                let payloads = try backend.buildSharePayloads(
                    commitment: sdkCommitment,
                    voteDecision: voteDecision.ffiValue,
                    numOptions: numOptions,
                    voteCommitmentTreePosition: vcTreePosition,
                    singleShare: singleShare
                )
                return payloads.map { payload in
                    let encShare = EncryptedShare(
                        c1: Data(payload.encShare.ciphertext1),
                        c2: Data(payload.encShare.ciphertext2),
                        shareIndex: payload.encShare.shareIndex
                    )
                    let allEncShares = payload.allEncShares.map { wire in
                        EncryptedShare(
                            c1: Data(wire.ciphertext1),
                            c2: Data(wire.ciphertext2),
                            shareIndex: wire.shareIndex
                        )
                    }
                    let shareComms = payload.shareComms.map { Data($0) }
                    return SharePayload(
                        sharesHash: Data(payload.sharesHash),
                        proposalId: payload.proposalId,
                        voteDecision: payload.voteDecision,
                        encShare: encShare,
                        treePosition: payload.treePosition,
                        allEncShares: allEncShares,
                        shareComms: shareComms,
                        primaryBlind: Data(payload.primaryBlind)
                    )
                }
            },
```

with:

```swift
            // swiftlint:disable:next function_parameter_count
            commitVote: { roundId, bundleIndex, hotkeyStoredSecret, proposalId, choice, numOptions, voteCommitmentTreePosition, vanAuthPath, vanPosition, vanAnchorHeight, singleShare in
                let backend = try await dbActor.backend()
                let vanWitness = try VotingVanWitness.make(
                    authPath: vanAuthPath.map { [UInt8]($0) },
                    position: vanPosition,
                    anchorHeight: vanAnchorHeight
                )
                let result = try await backend.commitVote(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    proposalId: proposalId,
                    choice: choice.ffiValue,
                    numOptions: numOptions,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    vanWitness: vanWitness,
                    singleShare: singleShare
                )
                publishState(backend: backend, roundId: roundId)
                let encShares: [EncryptedShare] = try result.encShares.map { share in
                    guard
                        let c1 = Data(base64Encoded: share.ciphertext1),
                        let c2 = Data(base64Encoded: share.ciphertext2)
                    else {
                        throw VotingCryptoError.malformedWireShare(share.shareIndex)
                    }
                    return EncryptedShare(c1: c1, c2: c2, shareIndex: share.shareIndex)
                }
                let bundle = VoteCommitmentBundle(
                    vanNullifier: Data(result.vanNullifier),
                    voteAuthorityNoteNew: Data(result.voteAuthorityNoteNew),
                    voteCommitment: Data(result.voteCommitment),
                    proposalId: result.proposalId,
                    proof: Data(result.proof),
                    encShares: encShares,
                    anchorHeight: result.anchorHeight,
                    voteRoundId: roundId,
                    sharesHash: Data(),
                    rVpkBytes: Data(result.voteKeyRandomizer)
                )
                let signature = CastVoteSignature(voteAuthSig: Data(result.voteAuthSig))
                return (bundle, signature)
            },
```

`VotingVoteCommit.encShares` (`VotingWireEncryptedShare`) is base64-`String` post SDK-lane
Task 2 (`## VERIFICATION EVIDENCE`'s SDK-signatures block); `voteRoundId` comes from the
already-in-scope `roundId` parameter because the commit result carries no round id of its own
(the crate's wire type never needed one — it is not itself submitted).

- [ ] **Step 8.7: Add the `malformedWireShare` error case.** In the same file, in the
`VotingCryptoError` enum, replace:

```swift
enum VotingCryptoError: LocalizedError {
    case proofFailed(String)
    case databaseNotOpen
    case hotkeySeedBindingMismatch
    case invalidSpendAuthSignatureLength(Int)
    case invalidKeystoneMetadata

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        }
    }
}
```

with:

```swift
enum VotingCryptoError: LocalizedError {
    case proofFailed(String)
    case databaseNotOpen
    case hotkeySeedBindingMismatch
    case invalidSpendAuthSignatureLength(Int)
    case invalidKeystoneMetadata
    case malformedWireShare(UInt32)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        }
    }
}
```

- [ ] **Step 8.8: Delete the `storeVoteCommitmentBundle` implementation.** In the same file,
delete (currently between `resetTreeClient` and `extractNcRoot` — verify against the file at
edit time since step 8.6 shifted line numbers upstream):

```swift
            signCastVote: { hotkeySeed, networkId, bundle in
                let sig = try VotingRustBackend.signCastVote(
                    hotkeySeed: hotkeySeed,
                    networkId: networkId,
                    commitment: bundle.toSDK()
                )
                return CastVoteSignature(
                    voteAuthSig: Data(sig.voteAuthSig)
                )
            },
```

(replace with nothing — `signCastVote` is fully absorbed into `commitVote`), and delete
(currently between `getVoteTxHash` and `getVoteCommitmentBundle`):

```swift
            storeVoteCommitmentBundle: { roundId, bundleIndex, proposalId, bundle, vcTreePosition in
                let backend = try await dbActor.backend()
                let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? "{}"
                try backend.storeCommitmentBundle(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    bundleJson: json,
                    voteCommitmentTreePosition: vcTreePosition
                )
            },
```

(replace with nothing — persistence is internal to `commitVote` now).

- [ ] **Step 8.9: Unify the `getDelegationSubmission` implementation.** In the same file,
replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, senderSeed, networkId, accountIndex in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    senderSeed: senderSeed,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighash: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
            getDelegationSubmissionWithKeystoneSig: { roundId, bundleIndex, keystoneSig, keystoneSighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    keystoneSig: [UInt8](keystoneSig),
                    sighash: [UInt8](keystoneSighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighash: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
```

with:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighashOut: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighashOut
                )
            },
```

- [ ] **Step 8.10: Verify `VotingCryptoClientTestKey.swift` needs no edit.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && cat secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientTestKey.swift
```

Expected: exactly the 8-line file quoted in `## CORRECTIONS` item 2 (`static let testValue =
Self()`, no explicit member overrides). If the file differs from that (a member override was
added since this plan was written), that is a deviation — surface it and adapt the override to
the new signatures; do not silently skip it.

- [ ] **Step 8.11: Rewire the main-path construction.** In
`VotingCoordFlowCoordinator.swift`, replace:

```swift
                        var builtBundle: VoteCommitmentBundle?
                        for try await event in votingCrypto.buildVoteCommitment(
                            roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice,
                            numOptions, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight, singleShare
                        ) {
                            if case .completed(let bundle) = event {
                                builtBundle = bundle
                            }
                        }
                        guard let builtBundle else {
                            throw VotingFlowError.missingVoteCommitmentBundle
                        }

                        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, 0)

                        let castVoteSig = try await votingCrypto.signCastVote(hotkeySeed, networkId, builtBundle)

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .confirming))
                        let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                        try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)
```

with:

```swift
                        let (builtBundle, castVoteSig) = try await votingCrypto.commitVote(
                            roundId, bundleIndex, hotkeySeed, proposalId, choice,
                            numOptions, 0, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight, singleShare
                        )

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .confirming))
                        let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                        try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)
```

`hotkeySeed` is still the pre-Task-10 mnemonic-derived value at this point in the ladder — it
occupies the same positional slot `commitVote`'s `hotkeyStoredSecret:` parameter expects, and
plan Task 10 is what changes *what value* is passed here, not this call's shape. The `0` is the
provisional `voteCommitmentTreePosition` (spec `CHP_DESIGN.md` §3/A2 step 1). Everything from
`await send(.voteSubmissionStepUpdated(...step: .confirming))` onward through the rest of the
enclosing loop (the confirmation poll, `leaf_index` parse, `buildSharePayloads` call, the
second `storeVoteCommitmentBundle` call, and `markVoteSubmitted`) is **left exactly as it stands
today** — those lines are Task 9's, which needs this task's diff as its own "before" state.

- [ ] **Step 8.12: Rewire the Keystone submission call site.** In the same file, replace:

```swift
                    let registration = try await votingCrypto.getDelegationSubmissionWithKeystoneSig(
                        roundId, bundleIdx, sig.sig, sig.sighash
                    )
```

with:

```swift
                    let registration = try await votingCrypto.getDelegationSubmission(
                        roundId, bundleIdx, sig.sig, sig.sighash
                    )
```

`sig` is a `KeystoneBundleSignature` whose `.sig`/`.sighash` are already `Data` (populated from
`extractSpendAuthSignatureFromSignedPczt`/`extractPcztSighash`, both `throws -> Data`) — the
positional call shape is unchanged, only the member name changes.

- [ ] **Step 8.13: Compile-progress evidence gate (partial — by design).** Run the build first,
judged on its own real exit code — do not pipe it into `grep -c` (that would make the exit code
of a match-counting command stand in for the compiler's, which silently reports failure at the
goal state of zero errors; Global Constraint #4 forbids judging by grep):

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t8-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero (red-by-design continues through T13) — `set -o pipefail`
propagates `xcodebuild`'s own exit code through `tee`/`tail` unchanged, the same idiom Step 7.8
already uses. Then, as a separate, second command, count the errors — this command's exit
status is never judged (`grep -c` exits 1 at a count of zero, which is not a failure here, so
`|| true` neutralizes it; only the printed number is read):

```bash
grep -c 'error:' /tmp/chp-t8-build.log || true
```

Expected: a number, **strictly less** than `wc -l /tmp/chp-t7-errors.txt`. Grep the log for
`buildVoteCommitment\|signCastVote\|encryptShares\|decomposeWeight\|
getDelegationSubmissionWithKeystoneSig` — these five must **not** appear anywhere in the new
log. `buildSharePayloads` and `storeVoteCommitmentBundle` **are** expected to still appear
(the `:1937`, `:2171`, `:3460`/`:3463` call sites this task deliberately left standing) — that
is Task 9's targeted work, not a regression here.

- [ ] **Step 8.14: Wire the software delegation path to the new signing wrapper.**
`VotingCoordFlowCoordinator.swift` calls `votingCrypto.getDelegationSubmission(roundId,
bundleIndex, senderSeed, networkId, accountIndex)` twice inside `static func
runDelegationPipeline` — once as a "is it already cached?" probe (near `:3557`) and once for
real after proving (near `:3591`). Both become a two-call chain: sign, then submit. Locate them
by the quoted context, not by line number.

First, add the client member. In `VotingCryptoClientInterface.swift`, replace:

```swift
    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash.
```

with:

```swift
    /// Produce this wallet's own SpendAuth signature for one delegation bundle.
    /// The software counterpart of the Keystone QR round-trip: `zcash_voting` 2.0 no longer
    /// derives account keys or signs for its callers, and prescribes exactly this instead —
    /// load the bundle's signing request, derive the account SpendAuth key from the seed,
    /// randomize it with the request's randomizer, sign the request's sighash. All of it
    /// happens inside the SDK; the seed goes in, only the detached signature comes back.
    /// Feed the result straight into `getDelegationSubmission`.
    var signDelegationRequest: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String
    ) async throws -> (signature: Data, sighash: Data)

    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash.
```

(The anchor is the first two lines of the doc comment step 8.4 wrote; the new member goes
immediately above it. `VotingCryptoClientTestKey.swift` still needs no edit — `@DependencyClient`
synthesizes the unimplemented default, per `## CORRECTIONS` item 2.)

Second, implement it. In `VotingCryptoClientLiveKey.swift`, replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
```

with:

```swift
            signDelegationRequest: { roundId, bundleIndex, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName in
                let backend = try await dbActor.backend()
                // Same derivation the software branch of `buildVotingPczt` uses: the sender's
                // Orchard FVK and ZIP-32 seed fingerprint come from the seed itself, so the
                // delegation keys here are byte-identical to the ones that built the PCZT.
                let inputs = try VotingRustBackend.generateDelegationInputs(
                    senderSeed: senderSeed,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let signed = try backend.signDelegationRequest(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    keys: VotingDelegationKeyInputs(
                        fvk: inputs.fvkBytes,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        seedFingerprint: inputs.seedFingerprint,
                        accountIndex: accountIndex,
                        roundName: roundName
                    ),
                    seed: senderSeed
                )
                return (signature: Data(signed.signature), sighash: Data(signed.sighash))
            },
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
```

Third, rewire the cached-submission probe. In `VotingCoordFlowCoordinator.swift`, replace:

```swift
            let registration: DelegationRegistration
            if let cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                roundId, bundleIndex, senderSeed, networkId, accountIndex
            ) {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
```

with:

```swift
            let registration: DelegationRegistration
            // The cache probe is now two calls: signing succeeds once the bundle's PCZT setup
            // is stored, and the submission only assembles once its proof is too. Either one
            // failing means this bundle is not finished yet, so fall through and build it.
            let cachedSignature = try? await votingCrypto.signDelegationRequest(
                roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
            )
            let cachedRegistration: DelegationRegistration?
            if let cachedSignature {
                cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, cachedSignature.signature, cachedSignature.sighash
                )
            } else {
                cachedRegistration = nil
            }

            if let cachedRegistration {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
```

Fourth, rewire the post-proving call. In the same function, replace:

```swift
                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, senderSeed, networkId, accountIndex
                )
```

with:

```swift
                let signed = try await votingCrypto.signDelegationRequest(
                    roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
                )
                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, signed.signature, signed.sighash
                )
```

`hotkeySeed` and `roundName` are both `runDelegationPipeline` parameters already in scope at
both sites, so nothing new is threaded through the coordinator. The `hotkeySeed` local keeps
its name and starts carrying the hotkey **stored secret** at Task 10 step 10.14, exactly as it
does for the neighbouring `buildVotingPczt` / `buildAndProveDelegation` calls in this same
function — which is why the new member's parameter is named `hotkeyStoredSecret` from the
start. Task 10 needs no amendment for this member.

`runDelegationPipeline` already carries
`// swiftlint:disable:next function_body_length function_parameter_count`, which covers the
handful of lines this step adds.

**Reporting:** record in the T8 report that the F1 STOP finding is closed by plan Task 4B (SDK
commit `[#1855] Add the software delegation-signing passthrough zcash_voting 2.0 prescribes`),
and that `:3557`/`:3591` are now expected to compile. If Task 4B's commit is not present in the
SDK worktree (`git log --oneline -8` there), **stop** — do not hand-roll signing code in the
app; that would put key derivation in the wrong layer and is forbidden by §0.2.

- [ ] **Step 8.15: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Collapse the six-member vote pipeline into commitVote and unify getDelegationSubmission" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 9

### Task 9: A2 — the six-step vote sequence

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` items 7, 11, 12 first, and this task's step 9.9 note on
`recordShareDelegation` (a fourth, related SDK-signature change discovered while wiring this
sequence — the crate now derives the share nullifier internally instead of taking it as an
argument, which is *good* news: it removes rather than adds a gap). This task assumes Task 8
landed — it starts from the "after" state of Task 8's step 8.11.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Modify: `secant/Sources/Dependencies/VotingModels/VotingModels.swift` (`SharePayload`, `DelegationRegistration`)
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` (`sharePostBody`, `submitDelegation`)
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:1892-1966` (main path), `:2151-2210` (share-status-poll resubmission), `:3419-3505` (`tryRecoverInflightVote`)
- Modify: `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift` (step 9.0a's `makeDelegationRegistration` fixture — a third `DelegationRegistration(...)` call site found beyond the two Task 8/14 already knew about)

**Interfaces:**
- Consumes (from SDK-lane `## INTERFACES-FOR-APP`, not yet in the tree — this task's build gate
  runs after plan Task 6): `VotingRustBackend.confirmVoteSubmission(roundId:bundleIndex:
  proposalId:txHash:eventsJson:) throws -> VotingVoteConfirmation` and
  `VotingRustBackend.recoverWireJson(commitmentBundleJson:proposalId:shareIndex:
  voteCommitmentTreePosition:submitAt:) throws -> String` (static). Consumes the real, current
  `VotingRustBackend.recordShareDelegation(roundId:bundleIndex:proposalId:shareIndex:
  sentToURLs:submitAt:) throws` (`## VERIFICATION EVIDENCE` — 6 args, no nullifier; unaffected
  by SDK-lane Tasks 1–4). Consumes the real, current `VotingDelegationSubmission`
  (`VotingTypes.swift:281-296` in the SDK worktree — all-`String`/base64, **no** `sighash`
  field; step 9.0a).
- Produces: `VotingCryptoClient.confirmVoteSubmission(...)`,
  `.getCommitmentBundleJson(...) -> (bundleJson: String, vcTreePosition: UInt64)?`,
  `.recoverWireJson(...) -> String`; re-typed `.markVoteSubmitted(...txHash:)` and
  `.recordShareDelegation(...)` (nullifier dropped); `SharePayload` re-typed to
  `{ wireJson: String, shareIndex: UInt32 }`; `DelegationRegistration` re-typed (step 9.0a):
  `signedNoteNullifier`/`cmxNew`/`vanCmx`/`proof` become `String`, `govNullifiers` becomes
  `[String]`, `rk`/`spendAuthSig`/`sighash`/`voteRoundId` stay `Data`.

---

- [ ] **Step 9.0a: Fix step 8.9's wire-type drift in `getDelegationSubmission`.** Step 8.9's
`LiveKey` closure was written against the pre-SDK-lane-Task-2 shape of `VotingDelegationSubmission`
(all `[UInt8]`, plus a `sighash` field) — the real, post-Task-2 type is all-`String`/base64 and
has **no** `sighash` field at all (`## VERIFICATION EVIDENCE`'s SDK-signatures block already
quoted its doc comment: *"the legacy `sighash` field is gone from the wire. The signer's
sighash still exists; it simply never belonged in the submission body, because the server
derives the signing digest itself."*). The live error is
`VotingCryptoClientLiveKey.swift:415: missing argument label 'hexString:' in call` — `Data(sub.
randomizedKey)` resolves against this file's own `Data(hexString:)` extension instead of a
byte-array initializer, because `sub.randomizedKey` is now a `String`. Verify first:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && sed -n '406,434p' secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift
grep -n "public struct VotingDelegationSubmission" -A16 ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift
```

Expected: the closure shown below (unchanged from what step 8.9 landed) and the SDK struct with
all-`String` fields and no `sighash`.

**Consumer verdict** (per §2.0's no-reshaping rule — keep the crate's base64 strings end-to-end
wherever the consumer permits, decode to `Data` only where a genuine byte-level need exists).
`DelegationRegistration`'s only two consumers are the wire-body builder
(`VotingAPIClientLiveKey.swift`'s `submitDelegation`, which currently calls
`.base64EncodedString()` on every field — i.e. it already wants base64 text, so handing it the
SDK's base64 strings directly instead of decode-then-reencode is strictly more correct, not
less) and the Keystone signature check
(`VotingCoordFlowCoordinator.swift:2893-2895`: `registration.rk != sig.rk`,
`.spendAuthSig != sig.sig`, `.sighash != sig.sighash`, each against a `Data` from
`KeystoneBundleSignature`). That second site is the *only* genuine byte-level requirement in
the app — so `rk`, `spendAuthSig`, and `sighash` stay `Data`; `signedNoteNullifier`, `cmxNew`,
`vanCmx`, `govNullifiers`, and `proof` (wire-only, never compared) become the SDK's base64
`String`s verbatim. `voteRoundId` is untouched either way: it was never base64 — `sub.
voteRoundId` is the round's *hex* id in both SDK generations, and line 414's `Data(hexString:
sub.voteRoundId)` already converts it correctly; that line does not appear in either diff below.
`sighash` itself never came from `sub` at all going forward — the crate stopped returning one,
and correctly so: the closure's own `sighash` parameter (supplied by the caller, already `Data`)
is the only sighash that ever existed for this call.

First, re-type the model. In `secant/Sources/Dependencies/VotingModels/VotingModels.swift`,
replace:

```swift
struct DelegationRegistration: Equatable, Sendable {
    let rk: Data // swiftlint:disable:this identifier_name
    let spendAuthSig: Data
    let signedNoteNullifier: Data
    let cmxNew: Data
    let vanCmx: Data
    let govNullifiers: [Data]
    let proof: Data
    let voteRoundId: Data
    let sighash: Data

    init(
        rk: Data, // swiftlint:disable:this identifier_name
        spendAuthSig: Data,
        signedNoteNullifier: Data,
        cmxNew: Data,
        vanCmx: Data,
        govNullifiers: [Data],
        proof: Data,
        voteRoundId: Data,
        sighash: Data
    ) {
        self.rk = rk
        self.spendAuthSig = spendAuthSig
        self.signedNoteNullifier = signedNoteNullifier
        self.cmxNew = cmxNew
        self.vanCmx = vanCmx
        self.govNullifiers = govNullifiers
        self.proof = proof
        self.voteRoundId = voteRoundId
        self.sighash = sighash
    }
}
```

with:

```swift
struct DelegationRegistration: Equatable, Sendable {
    let rk: Data // swiftlint:disable:this identifier_name
    let spendAuthSig: Data
    /// Base64, verbatim from `VotingDelegationSubmission` — never compared as bytes, only
    /// ever placed on the wire, so it is never decoded.
    let signedNoteNullifier: String
    let cmxNew: String
    let vanCmx: String
    let govNullifiers: [String]
    let proof: String
    let voteRoundId: Data
    let sighash: Data

    init(
        rk: Data, // swiftlint:disable:this identifier_name
        spendAuthSig: Data,
        signedNoteNullifier: String,
        cmxNew: String,
        vanCmx: String,
        govNullifiers: [String],
        proof: String,
        voteRoundId: Data,
        sighash: Data
    ) {
        self.rk = rk
        self.spendAuthSig = spendAuthSig
        self.signedNoteNullifier = signedNoteNullifier
        self.cmxNew = cmxNew
        self.vanCmx = vanCmx
        self.govNullifiers = govNullifiers
        self.proof = proof
        self.voteRoundId = voteRoundId
        self.sighash = sighash
    }
}
```

Second, add the decode-failure error case this closure needs (`rk`/`spendAuthSig` are the only
two fields still decoded from base64, and a malformed value from the crate must not silently
proceed). In `VotingCryptoClientLiveKey.swift`, in the `VotingCryptoError` enum step 8.7 last
edited, replace:

```swift
    case malformedWireShare(UInt32)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        }
    }
}
```

with:

```swift
    case malformedWireShare(UInt32)
    case malformedDelegationSubmission(String)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        case .malformedDelegationSubmission(let detail):
            return "getDelegationSubmission returned malformed wire data: \(detail)"
        }
    }
}
```

Third, fix the closure itself. In the same file, replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighashOut: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighashOut
                )
            },
```

with:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                guard
                    let rk = Data(base64Encoded: sub.randomizedKey),
                    let spendAuthSig = Data(base64Encoded: sub.spendAuthSig)
                else {
                    throw VotingCryptoError.malformedDelegationSubmission(
                        "rk/spend_auth_sig did not base64-decode"
                    )
                }
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: sub.nfSigned,
                    cmxNew: sub.cmxNew,
                    vanCmx: sub.govComm,
                    govNullifiers: sub.govNullifiers,
                    proof: sub.proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
```

`sighash` on the last line is the closure's own parameter (already `Data`) — never `sub.sighash`,
which no longer exists.

Fourth, stop re-encoding what is already base64 text. In
`secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift`, replace:

```swift
            submitDelegation: { registration in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let body: [String: Any] = [
                        "rk": registration.rk.base64EncodedString(),
                        "spend_auth_sig": registration.spendAuthSig.base64EncodedString(),
                        "sighash": registration.sighash.base64EncodedString(),
                        "signed_note_nullifier": registration.signedNoteNullifier.base64EncodedString(),
                        "cmx_new": registration.cmxNew.base64EncodedString(),
                        "van_cmx": registration.vanCmx.base64EncodedString(),
                        "gov_nullifiers": registration.govNullifiers.map { $0.base64EncodedString() },
                        "proof": registration.proof.base64EncodedString(),
                        "vote_round_id": registration.voteRoundId.base64EncodedString()
                    ]
```

with:

```swift
            submitDelegation: { registration in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let body: [String: Any] = [
                        "rk": registration.rk.base64EncodedString(),
                        "spend_auth_sig": registration.spendAuthSig.base64EncodedString(),
                        "sighash": registration.sighash.base64EncodedString(),
                        "signed_note_nullifier": registration.signedNoteNullifier,
                        "cmx_new": registration.cmxNew,
                        "van_cmx": registration.vanCmx,
                        "gov_nullifiers": registration.govNullifiers,
                        "proof": registration.proof,
                        "vote_round_id": registration.voteRoundId.base64EncodedString()
                    ]
```

Fifth, a third `DelegationRegistration(...)` call site this same field-type change breaks: the
test fixture. In `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift`, replace:

```swift
    private static func makeDelegationRegistration(
        rk: Data = Data(repeating: 0x01, count: 32),
        spendAuthSig: Data = Data(repeating: 0x02, count: 64),
        sighash: Data = Data(repeating: 0x08, count: 32)
    ) -> DelegationRegistration {
        DelegationRegistration(
            rk: rk,
            spendAuthSig: spendAuthSig,
            signedNoteNullifier: Data(repeating: 0x03, count: 32),
            cmxNew: Data(repeating: 0x04, count: 32),
            vanCmx: Data(repeating: 0x05, count: 32),
            govNullifiers: [Data(repeating: 0x06, count: 32)],
            proof: Data(repeating: 0x07, count: 32),
            voteRoundId: Data([0xAA, 0xBB]),
            sighash: sighash
        )
    }
```

with:

```swift
    private static func makeDelegationRegistration(
        rk: Data = Data(repeating: 0x01, count: 32),
        spendAuthSig: Data = Data(repeating: 0x02, count: 64),
        sighash: Data = Data(repeating: 0x08, count: 32)
    ) -> DelegationRegistration {
        DelegationRegistration(
            rk: rk,
            spendAuthSig: spendAuthSig,
            signedNoteNullifier: Data(repeating: 0x03, count: 32).base64EncodedString(),
            cmxNew: Data(repeating: 0x04, count: 32).base64EncodedString(),
            vanCmx: Data(repeating: 0x05, count: 32).base64EncodedString(),
            govNullifiers: [Data(repeating: 0x06, count: 32).base64EncodedString()],
            proof: Data(repeating: 0x07, count: 32).base64EncodedString(),
            voteRoundId: Data([0xAA, 0xBB]),
            sighash: sighash
        )
    }
```

This test file is edited twice across this plan at two non-overlapping locations — this fixture
here (`:928-944` at plan-writing time) by step 9.0a, and the Keystone stub rename (`:1025`) by
Task 14 — so Task 14 will encounter this file already modified by this step; that is expected,
not a conflict.

- [ ] **Step 9.0b: Delete the dead `toSDK()` extension.** `private extension
VoteCommitmentBundle { func toSDK() -> VotingVoteCommitmentBundle { ... } }` references
`VotingVoteCommitmentBundle`, a type that exists nowhere in the real SDK (it was invented for
the pre-SDK-lane-Task-2 `buildSharePayloads`/`signCastVote` pipeline). Its only caller was
`signCastVote`'s `LiveKey` implementation, which step 8.8 already deleted — no task owns
deleting the now-dead extension itself. Verify first:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "VotingVoteCommitmentBundle\|private extension VoteCommitmentBundle" secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift
```

Expected: exactly the one extension block, no other reference anywhere in the file (confirming
it is genuinely unreferenced, not just unreferenced by the deleted closure). In the same file,
replace:

```swift
private extension VoteCommitmentBundle {
    func toSDK() -> VotingVoteCommitmentBundle {
        VotingVoteCommitmentBundle(
            vanNullifier: [UInt8](vanNullifier),
            voteAuthorityNoteNew: [UInt8](voteAuthorityNoteNew),
            voteCommitment: [UInt8](voteCommitment),
            proposalId: proposalId,
            proof: [UInt8](proof),
            encShares: encShares.map {
                VotingWireEncryptedShare(
                    ciphertext1: [UInt8]($0.c1),
                    ciphertext2: [UInt8]($0.c2),
                    shareIndex: $0.shareIndex
                )
            },
            anchorHeight: anchorHeight,
            voteRoundId: voteRoundId,
            sharesHash: [UInt8](sharesHash),
            shareBlinds: shareBlindFactors.map { [UInt8]($0) },
            shareComms: shareComms.map { [UInt8]($0) },
            rVpkBytes: [UInt8](rVpkBytes),
            alphaV: [UInt8](alphaV)
        )
    }
}
```

with nothing (delete the block and the blank line immediately above it, so the file reads
straight from whatever precedes it into whatever follows — verify at edit time that no other
blank-line adjustment is needed; do not leave two consecutive blank lines behind).

- [ ] **Step 9.1: Thread `txHash` through `markVoteSubmitted`.** In
`VotingCryptoClientInterface.swift`, replace:

```swift
    var markVoteSubmitted: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32) async throws -> Void
```

with:

```swift
    var markVoteSubmitted: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ txHash: String) async throws -> Void
```

- [ ] **Step 9.2: Add `confirmVoteSubmission` and `getCommitmentBundleJson`, drop the
`nullifier:` parameter from `recordShareDelegation`.** In the same file, replace:

```swift
    /// Persist a Keystone bundle signature so it survives app restarts.
```

with (inserting two new members immediately before the existing recovery-state section header
comment; the `///` doc line quoted is the anchor, unchanged, appearing again at the end of this
block):

```swift
    /// Record a confirmed cast-vote transaction in one atomic step.
    ///
    /// `eventsJson` is the confirmation-events array the app's existing confirmation polling
    /// already fetches (`VotingAPIClient.fetchTxConfirmation(_:).events`), serialized as JSON —
    /// a list of `{"type": …, "attributes": [{"key": …, "value": …}]}` objects. Callers must
    /// not parse `leaf_index` themselves; that is exactly the duplicated state this entry point
    /// exists to delete (spec `CHP_DESIGN.md` §3/A2 step 4).
    var confirmVoteSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ txHash: String,
        _ eventsJson: String
    ) async throws -> VoteConfirmationInfo
    /// Read the persisted commitment-recovery bundle for a (round, bundle, proposal) as the
    /// raw JSON `commitVote` wrote — opaque to this layer; feed it straight into
    /// `recoverWireJson`. Distinct from `getVoteCommitmentBundle`/
    /// `getVoteCommitmentBundleWithPosition`, which decode it as the app's own
    /// `VoteCommitmentBundle` — a decode target that no longer matches what `commitVote`
    /// persists (see `## CORRECTIONS` item 13 in the T9 plan notes).
    var getCommitmentBundleJson: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> (bundleJson: String, vcTreePosition: UInt64)?
    /// Rebuild one helper-server share payload as `zcash_voting`'s own wire JSON, with the
    /// confirmed vote-commitment-tree position and the scheduled submit time late-bound into
    /// it. POST the returned string verbatim — do not decode, re-shape, or re-encode it.
    var recoverWireJson: @Sendable (
        _ commitmentBundleJson: String,
        _ proposalId: UInt32,
        _ shareIndex: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ submitAt: UInt64
    ) async throws -> String
    /// Persist a Keystone bundle signature so it survives app restarts.
```

Then, still in the same file, replace:

```swift
    /// Record a share delegation after sending to helper servers.
    var recordShareDelegation: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32, _ sentToURLs: [String], _ nullifier: [UInt8], _ submitAt: UInt64) async throws -> Void
```

with:

```swift
    /// Record a share delegation after sending to helper servers.
    ///
    /// The share's nullifier is no longer supplied by the caller: `zcash_voting` derives it
    /// from the committed vote's recovery state, so a caller cannot record a nullifier that
    /// disagrees with the share it belongs to. Read it back via `getShareDelegations`/
    /// `getUnconfirmedDelegations` when polling `VotingAPIClient.fetchShareStatus`.
    var recordShareDelegation: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32, _ sentToURLs: [String], _ submitAt: UInt64) async throws -> Void
```

Add the small result type this step's new member needs — append to the bottom of the file, just
above the closing `#endif`:

```swift

/// Positions a mined cast-vote transaction confirmed. Mirrors
/// `VotingRustBackend.VotingVoteConfirmation` (SDK-lane Task 3) field for field.
struct VoteConfirmationInfo: Equatable, Sendable {
    let txHash: String
    let vanLeafPosition: UInt32
    let voteCommitmentTreePosition: UInt64
}
```

- [ ] **Step 9.3: Implement `confirmVoteSubmission` in the LiveKey.** In
`VotingCryptoClientLiveKey.swift`, insert immediately before the `storeKeystoneBundleSignature:`
closure (which follows the block Step 9.2 targeted):

```swift
            confirmVoteSubmission: { roundId, bundleIndex, proposalId, txHash, eventsJson in
                let backend = try await dbActor.backend()
                let confirmation = try backend.confirmVoteSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    txHash: txHash,
                    eventsJson: eventsJson
                )
                publishState(backend: backend, roundId: roundId)
                return VoteConfirmationInfo(
                    txHash: confirmation.txHash,
                    vanLeafPosition: confirmation.vanLeafPosition,
                    voteCommitmentTreePosition: confirmation.voteCommitmentTreePosition
                )
            },
            getCommitmentBundleJson: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else {
                    return nil
                }
                return (bundleJson: result.bundleJson, vcTreePosition: result.voteCommitmentTreePosition)
            },
            recoverWireJson: { commitmentBundleJson, proposalId, shareIndex, voteCommitmentTreePosition, submitAt in
                try VotingRustBackend.recoverWireJson(
                    commitmentBundleJson: commitmentBundleJson,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    submitAt: submitAt
                )
            },
```

`VotingRustBackend.recoverWireJson` is `static` (SDK-lane Task 3) — no database handle needed;
called as a type method here, matching how `computeShareNullifier` is already called elsewhere
in this same file.

- [ ] **Step 9.4: Thread `txHash` through `markVoteSubmitted`'s implementation.** In the same
file, replace:

```swift
            markVoteSubmitted: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                try backend.markVoteSubmitted(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId)
                publishState(backend: backend, roundId: roundId)
            },
```

with:

```swift
            markVoteSubmitted: { roundId, bundleIndex, proposalId, txHash in
                let backend = try await dbActor.backend()
                try backend.markVoteSubmitted(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId, txHash: txHash)
                publishState(backend: backend, roundId: roundId)
            },
```

- [ ] **Step 9.5: Drop the nullifier argument from `recordShareDelegation`'s implementation.**
In the same file, replace:

```swift
            recordShareDelegation: { roundId, bundleIndex, proposalId, shareIndex, sentToURLs, nullifier, submitAt in
                let backend = try await dbActor.backend()
                try backend.recordShareDelegation(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    sentToURLs: sentToURLs,
                    nullifier: hexEncodedString(nullifier),
                    submitAt: submitAt
                )
            },
```

with:

```swift
            recordShareDelegation: { roundId, bundleIndex, proposalId, shareIndex, sentToURLs, submitAt in
                let backend = try await dbActor.backend()
                try backend.recordShareDelegation(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    sentToURLs: sentToURLs,
                    submitAt: submitAt
                )
            },
```

`hexEncodedString(_:)` (private helper, `:794-796`) becomes unused by this change alone — leave
it; `computeShareNullifier`'s LiveKey closure (`:655-661`, untouched by this task) still calls
`VotingRustBackend.computeShareNullifier` directly and does not go through this helper either
way, so check at Step 9.10's build gate whether SwiftLint's unused-function pass flags it before
removing it in a later cleanup — do not remove it speculatively here.

- [ ] **Step 9.6: Re-shape `SharePayload` to carry the crate's opaque wire JSON.** In
`VotingModels.swift`, replace (lines 517-548):

```swift
/// Payload sent to helper servers for share delegation (not directly to chain).
struct SharePayload: Equatable, Sendable {
    let sharesHash: Data
    let proposalId: UInt32
    let voteDecision: UInt32
    let encShare: EncryptedShare
    let treePosition: UInt64
    /// All encrypted shares for this vote (needed by helper servers for verification).
    let allEncShares: [EncryptedShare]
    /// Pre-computed per-share Poseidon commitments (N x 32 bytes).
    let shareComms: [Data]
    /// Blind factor for this specific share (32 bytes).
    let primaryBlind: Data
    /// Unix seconds at which the helper should submit the share; 0 = immediate (last-moment).
    var submitAt: UInt64

    init(
        sharesHash: Data, proposalId: UInt32, voteDecision: UInt32, encShare: EncryptedShare,
        treePosition: UInt64, allEncShares: [EncryptedShare] = [], shareComms: [Data] = [],
        primaryBlind: Data = Data(), submitAt: UInt64 = 0
    ) {
        self.sharesHash = sharesHash
        self.proposalId = proposalId
        self.voteDecision = voteDecision
        self.encShare = encShare
        self.treePosition = treePosition
        self.allEncShares = allEncShares
        self.shareComms = shareComms
        self.primaryBlind = primaryBlind
        self.submitAt = submitAt
    }
}
```

with:

```swift
/// Payload sent to helper servers for share delegation (not directly to chain).
///
/// Wraps `zcash_voting`'s own wire JSON for one share — obtained from
/// `VotingCryptoClient.recoverWireJson(...)` — verbatim. Every field the old hand-built dialect
/// carried (`sharesHash`, `allEncShares`, `shareComms`, `primaryBlind`, the encoded `submitAt`)
/// is already inside `wireJson`; the crate produced and encoded it, so nothing here re-shapes
/// it. `shareIndex` is kept alongside only for local bookkeeping (matching a POST's outcome back
/// to the share it was for) — it is never written onto the wire a second time.
struct SharePayload: Equatable, Sendable {
    let wireJson: String
    let shareIndex: UInt32

    init(wireJson: String, shareIndex: UInt32) {
        self.wireJson = wireJson
        self.shareIndex = shareIndex
    }
}
```

- [ ] **Step 9.7: Parse the wire JSON straight into the POST body.** In
`VotingAPIClientLiveKey.swift`, replace (lines 352-380):

```swift
func sharePostBody(
    for payload: SharePayload,
    roundIdHex: String,
    submitAt: UInt64? = nil
) -> [String: Any] {
    [
        "shares_hash": payload.sharesHash.base64EncodedString(),
        "proposal_id": payload.proposalId,
        "vote_decision": payload.voteDecision,
        "enc_share": [
            "c1": payload.encShare.c1.base64EncodedString(),
            "c2": payload.encShare.c2.base64EncodedString(),
            "share_index": payload.encShare.shareIndex
        ],
        "share_index": payload.encShare.shareIndex,
        "tree_position": payload.treePosition,
        "vote_round_id": roundIdHex,
        "all_enc_shares": payload.allEncShares.map { share -> [String: Any] in
            [
                "c1": share.c1.base64EncodedString(),
                "c2": share.c2.base64EncodedString(),
                "share_index": share.shareIndex
            ]
        },
        "share_comms": payload.shareComms.map { $0.base64EncodedString() },
        "primary_blind": payload.primaryBlind.base64EncodedString(),
        "submit_at": submitAt ?? payload.submitAt
    ]
}
```

with:

```swift
/// `roundIdHex` is unused: the crate's wire JSON already carries `vote_round_id` (it was
/// derived from the same commitment record `recoverWireJson` read); the parameter is kept so
/// call sites that still pass it (unchanged by this task) do not need editing.
func sharePostBody(
    for payload: SharePayload,
    roundIdHex: String
) -> [String: Any] {
    let data = Data(payload.wireJson.utf8)
    guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return [:]
    }
    return body
}
```

- [ ] **Step 9.8: Update `sharePostBody`'s two call sites for the dropped `submitAt:`
parameter.** In the same file, replace:

```swift
                            let body = sharePostBody(for: payload, roundIdHex: roundIdHex)
```

with:

```swift
                            let body = sharePostBody(for: payload, roundIdHex: roundIdHex)
```

(no change needed — `delegateSharePayloads`'s call already omits the optional `submitAt:`).
Then replace:

```swift
    let body = sharePostBody(for: payload, roundIdHex: roundIdHex, submitAt: 0)
```

with:

```swift
    let body = sharePostBody(for: payload, roundIdHex: roundIdHex)
```

`resubmitSharePayload`'s old `submitAt: 0` override no longer applies: a resubmission must call
`recoverWireJson(..., submitAt: 0)` **before** constructing the `SharePayload` (Step 9.14 does
this), so the wire JSON already encodes `submit_at: 0` by the time it reaches this function.

- [ ] **Step 9.9: Rewire the main path — delete `leaf_index` parsing and the dead
`storeVanPosition`/`storeVoteCommitmentBundle`/`buildSharePayloads` calls, insert
`confirmVoteSubmission` + the `recoverWireJson` loop, thread `txHash` into
`markVoteSubmitted`.** In `VotingCoordFlowCoordinator.swift`, replace:

```swift
                        let voteDeadline = Date().addingTimeInterval(90)
                        var voteConfirmation: TxConfirmation?
                        repeat {
                            voteConfirmation = try? await votingAPI.fetchTxConfirmation(txResult.txHash)
                            if voteConfirmation != nil { break }
                            try await Task.sleep(for: .seconds(2))
                        } while Date() < voteDeadline

                        guard let voteConfirmation, voteConfirmation.code == 0,
                              let leafPair = voteConfirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index")
                        else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: voteConfirmation?.code ?? 0,
                                log: voteConfirmation?.log ?? ""
                            )
                        }
                        let leafParts = leafPair.split(separator: ",")
                        guard leafParts.count == 2,
                              let vanIdx = UInt32(leafParts[0]),
                              let vcIdx = UInt64(leafParts[1])
                        else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: 0,
                                log: "malformed cast_vote leaf_index: \(leafPair)"
                            )
                        }

                        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
                        var payloads = try await votingCrypto.buildSharePayloads(
                            builtBundle.encShares, builtBundle, choice, numOptions, vcIdx, singleShare
                        )
                        let nowSec = Date().timeIntervalSince1970
                        for i in payloads.indices {
                            if let deadline = submitAtDeadline, deadline > nowSec {
                                payloads[i].submitAt = UInt64(nowSec + Double.random(in: 0..<(deadline - nowSec)))
                            } else {
                                payloads[i].submitAt = 0
                            }
                        }
                        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, vcIdx)
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
                        shareServerURLs = batchDelegationResult.remainingServerURLs
                        for info in batchDelegationResult.delegatedShares {
                            guard let payload = payloads.first(where: {
                                $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
                            }) else { continue }
                            let blindIndex = Int(info.shareIndex)
                            guard blindIndex < builtBundle.shareBlindFactors.count else { continue }
                            do {
                                let nullifierHex = try votingCrypto.computeShareNullifier(
                                    [UInt8](builtBundle.voteCommitment),
                                    info.shareIndex,
                                    [UInt8](builtBundle.shareBlindFactors[blindIndex])
                                )
                                try await votingCrypto.recordShareDelegation(
                                    roundId, bundleIndex, info.proposalId,
                                    info.shareIndex, info.acceptedByServers,
                                    [UInt8](votingDataFromHex(nullifierHex)), payload.submitAt
                                )
                            } catch {
                                LoggerProxy.warn("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                            }
                        }
                        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
```

with:

```swift
                        let voteDeadline = Date().addingTimeInterval(90)
                        var voteConfirmation: TxConfirmation?
                        repeat {
                            voteConfirmation = try? await votingAPI.fetchTxConfirmation(txResult.txHash)
                            if voteConfirmation != nil { break }
                            try await Task.sleep(for: .seconds(2))
                        } while Date() < voteDeadline

                        guard let voteConfirmation, voteConfirmation.code == 0 else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: voteConfirmation?.code ?? 0,
                                log: voteConfirmation?.log ?? ""
                            )
                        }

                        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId, txResult.txHash)

                        let eventsPayload: [[String: Any]] = voteConfirmation.events.map { event in
                            [
                                "type": event.type,
                                "attributes": event.attributes.map { attribute in
                                    ["key": attribute.key, "value": attribute.value]
                                }
                            ]
                        }
                        let eventsData = try JSONSerialization.data(withJSONObject: eventsPayload)
                        let eventsJson = String(decoding: eventsData, as: UTF8.self)

                        let confirmation = try await votingCrypto.confirmVoteSubmission(
                            roundId, bundleIndex, proposalId, txResult.txHash, eventsJson
                        )

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
                        guard let stored = try await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
                            throw VotingFlowError.missingVoteCommitmentBundle
                        }
                        let nowSec = Date().timeIntervalSince1970
                        var payloads: [SharePayload] = []
                        var submitAtByShareIndex: [UInt32: UInt64] = [:]
                        for share in builtBundle.encShares {
                            let submitAt: UInt64
                            if let deadline = submitAtDeadline, deadline > nowSec {
                                submitAt = UInt64(nowSec + Double.random(in: 0..<(deadline - nowSec)))
                            } else {
                                submitAt = 0
                            }
                            submitAtByShareIndex[share.shareIndex] = submitAt
                            let wireJson = try await votingCrypto.recoverWireJson(
                                stored.bundleJson, proposalId, share.shareIndex,
                                confirmation.voteCommitmentTreePosition, submitAt
                            )
                            payloads.append(SharePayload(wireJson: wireJson, shareIndex: share.shareIndex))
                        }
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
                        shareServerURLs = batchDelegationResult.remainingServerURLs
                        for info in batchDelegationResult.delegatedShares {
                            do {
                                try await votingCrypto.recordShareDelegation(
                                    roundId, bundleIndex, info.proposalId, info.shareIndex,
                                    info.acceptedByServers, submitAtByShareIndex[info.shareIndex] ?? 0
                                )
                            } catch {
                                LoggerProxy.warn("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                            }
                        }
```

Trap T3 (spec `CHP_DESIGN.md` §3/A2, CHP.md §11.9): between `markVoteSubmitted` and
`confirmVoteSubmission` returning, every position consumer inside `zcash_voting` hard-errors
("refusing to assume position 0") on any commit-adjacent read that assumes the provisional `0`.
This code path adds **no catch-and-ignore** around `confirmVoteSubmission` or `recoverWireJson`
— both `try await` directly into the enclosing `do`/`catch` at the top of this loop iteration
(unchanged, not shown above), which already surfaces the error to `.batchVoteFailed`. Verify
this at review time by confirming neither call is wrapped in its own local `try?` or
`do { } catch { }` inside this block — none is, in the replacement above.

- [ ] **Step 9.10: Progress gate.** Same two-command idiom as Step 8.13 — build, judged on its
own exit code; count, judged separately and never on its own exit code. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t9-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t9-build.log || true
```

Expected: a number, strictly less than Step 8.13's count (this command's own exit is not
judged — see Step 8.13 for why). `buildSharePayloads`, `storeVanPosition`, `leaf_index` must
**not** appear anywhere in the new log at the main-path location (`:1892`-region — the two
remaining `buildSharePayloads`/`storeVoteCommitmentBundle` call sites at the poll-resubmission
and crash-recovery regions, steps 9.11–9.13 below, are expected to still error).

- [ ] **Step 9.11: Rewire the share-status-poll resubmission region.** In
`VotingCoordFlowCoordinator.swift`, replace (inside `reducePollShareStatus`, the
`grouped`/`for (_, shares) in grouped` block):

```swift
            let grouped = Dictionary(grouping: pollResult.resubmissionShares) {
                "\($0.bundleIndex):\($0.proposalId)"
            }
            for (_, shares) in grouped {
                guard let first = shares.first else { continue }
                let bundleIndex = first.bundleIndex
                let proposalId = first.proposalId
                guard
                    let result = try? await votingCrypto.getVoteCommitmentBundleWithPosition(
                        roundId,
                        bundleIndex,
                        proposalId
                    ),
                    let choice = votes[proposalId]
                else {
                    continue
                }

                let numOptions = UInt32(proposals.first { $0.id == proposalId }?.options.count ?? 3)
                do {
                    var payloads = try await votingCrypto.buildSharePayloads(
                        result.bundle.encShares,
                        result.bundle,
                        choice,
                        numOptions,
                        result.vcTreePosition,
                        singleShare
                    )
                    for index in payloads.indices {
                        payloads[index].submitAt = 0
                    }

                    for share in shares {
                        guard let payload = payloads.first(where: {
                            $0.encShare.shareIndex == share.shareIndex
                        }) else {
                            continue
                        }
                        let acceptedServers = try await votingAPI.resubmitShare(
                            payload,
                            roundId,
                            share.sentToURLs
                        )
                        let newServers = acceptedServers.filter {
                            !share.sentToURLs.contains($0)
                        }
                        if !newServers.isEmpty {
                            try await votingCrypto.addSentServers(
                                roundId,
                                bundleIndex,
                                proposalId,
                                share.shareIndex,
                                newServers
                            )
                        }
                    }
                } catch {
                    LoggerProxy.warn("Share resubmission failed: \(error)")
                }
            }
```

with:

```swift
            let grouped = Dictionary(grouping: pollResult.resubmissionShares) {
                "\($0.bundleIndex):\($0.proposalId)"
            }
            for (_, shares) in grouped {
                guard let first = shares.first else { continue }
                let bundleIndex = first.bundleIndex
                let proposalId = first.proposalId
                guard let stored = try? await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
                    continue
                }

                do {
                    for share in shares {
                        let wireJson = try await votingCrypto.recoverWireJson(
                            stored.bundleJson, proposalId, share.shareIndex, stored.vcTreePosition, 0
                        )
                        let payload = SharePayload(wireJson: wireJson, shareIndex: share.shareIndex)
                        let acceptedServers = try await votingAPI.resubmitShare(
                            payload,
                            roundId,
                            share.sentToURLs
                        )
                        let newServers = acceptedServers.filter {
                            !share.sentToURLs.contains($0)
                        }
                        if !newServers.isEmpty {
                            try await votingCrypto.addSentServers(
                                roundId,
                                bundleIndex,
                                proposalId,
                                share.shareIndex,
                                newServers
                            )
                        }
                    }
                } catch {
                    LoggerProxy.warn("Share resubmission failed: \(error)")
                }
            }
```

This region resubmits shares `getUnconfirmedDelegations` already knows about — `share.shareIndex`
for each already came from a prior, successful `recordShareDelegation`, so no fresh share-index
enumeration is needed here (contrast step 9.13's finding). `votes`/`numOptions`/`singleShare`
become unused by this block specifically; leave them if `reducePollShareStatus`'s other code
still references them (verify at the build gate — do not remove speculatively).

- [ ] **Step 9.12: Progress gate.** Same two-command idiom as Step 8.13. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t9b-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t9b-build.log || true
```

Expected: a number, strictly less than Step 9.10's count (exit status not judged). Only
`tryRecoverInflightVote` (`:3419-3505`) should still reference
`buildSharePayloads`/`storeVanPosition`/`storeVoteCommitmentBundle`/`computeShareNullifier`
after this step.

- [ ] **Step 9.13: STOP-and-report — `tryRecoverInflightVote`'s share-index enumeration
(finding, not a code step).** This function recovers from a crash between broadcast and share
delegation, using only a **cached** tx hash (`getVoteTxHash`) and the **stored** recovery bundle
— unlike step 9.9's main path, it has no fresh `commitVote` result to read `encShares` from,
and unlike step 9.11's poll-resubmission region, it has no prior `recordShareDelegation` calls
to read share indices back from (the crash may have happened before any share was ever
recorded). `stored.bundleJson` (this task's own `getCommitmentBundleJson`) is explicitly
opaque-do-not-decode, so it cannot be inspected for a share count either. There is no verified
source for "how many shares, at which indices, does this bundle have" in this one scenario.

Decision procedure:
1. Confirm at a build gate that this function is in fact still referenced from a live call site
   (`grep -n tryRecoverInflightVote VotingCoordFlowCoordinator.swift` — at plan-writing time
   its only caller is the main batch-submission loop, guarding against exactly this crash
   window) — if it has become unreachable dead code by execution time, delete the whole
   function and skip the rest of this procedure.
2. Otherwise, check whether SDK-lane Task 3's `confirmVoteSubmission`/`recoverWireJson`
   landed with anything beyond `## INTERFACES-FOR-APP`'s documented shape — specifically
   whether `VotingVoteConfirmation` or any other confirmation-adjacent type gained a
   share-count/share-index-list field. If yes, use it; write the concrete call as a follow-up
   step before continuing.
3. If not (the expected outcome): do not guess a share count (not `numOptions`, not a
   protocol constant, not decoded from `stored.bundleJson`). Leave this function's body
   red at its `buildSharePayloads` call. Surface as a named, non-blocking finding — non-blocking
   because it only affects a same-launch-crash-recovery edge case, not the primary vote flow
   steps 9.9/9.11 already close, and not the T14/gate-5 acceptance criteria (zero *compile*
   errors, not zero *runtime* TODOs). Recommend it be resolved before the testnet E2E crash-
   recovery scenario (`CHP_PLAN.md` Task 16, step 16.3's matrix item) is run, not before T14.

- [ ] **Step 9.14: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Dependencies/VotingModels/VotingModels.swift secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Wire the confirm/recover-share vote sequence and drop the leaf_index hand-parse" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 9B

### Task 9B: recovery-path closure — F3 resolution + SharePayload residue

*Code blocks by: Sonnet (app delegate).*

**Execution order note:** this section sits between Tasks 9 and 10 in this file (its subject —
the crash-recovery function Task 9's step 9.13 deliberately left red — is Task 9's own unclosed
scope) but **executes after Task 10**, per the coordinator's live-build sequencing. A Task 10
executor may be running concurrently on the same tree; Task 10's scope is hotkey/PCZT regions
only (`VotingCryptoClientInterface.swift`'s `generateHotkey`/`buildVotingPczt`/
`buildAndProveDelegation` members, `StoredVotingHotkey.swift`, `WalletStorage*.swift`,
`VotingModels.swift`'s `VotingHotkey`, and four `mnemonic.toSeed` coordinator sites far above
line 3300) — disjoint from everything this section touches. Every anchor below is stated as
**unique code content**, not a trusted line number, for exactly that reason: the tree this
section was written against is post-T9 `f8cdac12`, and by the time it executes (after Task 10)
line numbers upstream of `tryRecoverInflightVote` will have shifted from Task 10's own edits.

**Files:**
- Modify: `secant/Sources/Features/Voting/VotingHelpers.swift` (`Voting.delegateSharesWithFallback`)
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientInterface.swift` (`delegateShares`)
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` (`delegateShares` closure, `delegateSharePayloads`)
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift` (the step-9.9 main-path `delegateSharesWithFallback` call site, and the full body of `static func tryRecoverInflightVote`)

**Interfaces:**
- Consumes: `zcash_voting` rc.5's own recovery surface, read directly from the vendored crate
  source (`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/zcash_voting-2.0.0-rc.5/src/
  share.rs` — the standard cargo registry cache path for the crates.io registry, stable across
  machines that use the default registry) — `recover_payloads(bundle: &VoteRecoveryBundle) ->
  Result<Vec<SharePayload>, VotingError>` (`:148-188`) slices `bundle.encrypted_shares` by
  exactly `bundle.single_share` (`&all_enc_shares[..1]` if true, the full vector otherwise);
  `recover_payload`/`recover_wire_json` (`:135-145`, `:192-210`) are both single-`share_index`
  accessors built on top of it — the crate never exposes the plural form outward. Also
  consumes the already-landed `VotingCryptoClient.confirmVoteSubmission`/`.getCommitmentBundleJson`/
  `.recoverWireJson`/`.recordShareDelegation`/`.markVoteSubmitted` (Task 9) unchanged.
- Produces: `Voting.delegateSharesWithFallback(...)` and `VotingAPIClient.delegateShares(...)`
  both gain a `proposalId: UInt32` parameter; `tryRecoverInflightVote`'s body is fully rewired,
  its signature unchanged.

---

**F3 evidence and decision (read before step 9B.1).** The share-index-enumeration question
Task 9's step 9.13 left open now has a sourced answer, not a guess:

1. **The crate's own plural recovery function exists but is not the sanctioned host surface.**
   `zcash_voting-2.0.0-rc.5/src/share.rs:148` — `pub fn recover_payloads(bundle:
   &VoteRecoveryBundle) -> Result<Vec<SharePayload>, VotingError>` — reconstructs every share
   payload for a bundle in one call, slicing `bundle.encrypted_shares` by `bundle.single_share`
   (`:156-160`: `if bundle.single_share { &all_enc_shares[..1] } else { &all_enc_shares }`).
   This confirms the *crate-internal* fact this section needs: share count is a pure function
   of two values the app already threads through `tryRecoverInflightVote` today —
   `singleShare: Bool` and (when not single-share) `bundle.encrypted_shares.len()`, which
   `vote.rs:592-599`'s `db.build_vote_commitment(..., draft.num_options, ..., draft.
   single_share, ...)` sizes from `num_options` at commit time — i.e. `numOptions` when not
   single-share, `1` when single-share.
2. **Valar's own reference wallet does not expose the plural function either.** Fetched
   `chainapsis/vizor-wallet`'s `rust/src/api/voting.rs` (`gh api repos/chainapsis/vizor-wallet/
   contents/rust/src/api/voting.rs`, decoded, 3452 lines). Its FRB bridge function
   `recovered_vote_share_wire_json(commitment_bundle_json, proposal_id, share_index,
   vc_tree_position, submit_at) -> Result<String, String>` (`:362-379`) is a direct, thin
   passthrough to `zcash_voting::share::recover_wire_json(...)` — the exact same per-index
   function our SDK's `recoverWireJson` already wraps. Vizor's Rust layer has full, direct
   access to the crate (no FFI marshalling boundary the way our Swift app has) and *still*
   exposes only the per-index accessor to its own Dart layer above it. That is the sanctioning
   precedent: even the reference wallet resolves "how many shares, which indices" from
   app-layer round/bundle context, not from a crate list call.
3. **Decision: no new FFI symbol.** Both sources agree the per-index `recoverWireJson` already
   on this SDK (SDK-lane Task 3, already built into the current FFI slices) is the intended
   surface. Bounded enumeration over `0..<(singleShare ? 1 : numOptions)` — values already
   present in this function's own parameter list — is not a guess or a workaround; it is the
   same computation the crate performs internally and the same resolution Valar's own
   reference wallet's app layer performs externally. The ~1-hour FFI rebuild + gates 2–3
   re-run this would have cost is avoided correctly, not just conveniently.

**`DelegatedShareInfo` re-sourcing verdict (read before step 9B.1).** Traced
`DelegatedShareInfo`'s full consumer chain: it is constructed once
(`VotingAPIClientLiveKey.swift`'s `delegateSharePayloads`, currently reading the now-nonexistent
`payload.encShare.shareIndex`/`payload.proposalId`) and consumed twice — Task 9's step 9.9 main
path and this section's rewritten `tryRecoverInflightVote` — both of which call
`recordShareDelegation(..., info.proposalId, info.shareIndex, ...)`. `shareIndex` survives on the
Task-9-reshaped `SharePayload` unchanged (`payload.shareIndex` — a one-word fix). `proposalId`
does not survive on `SharePayload` at all, but every call site that builds a `[SharePayload]`
batch for `delegateSharePayloads` builds it for exactly one proposal at a time (Task 9's step 9.9
loop and this section's F3 rewrite both construct `payloads` once per `commitVote`/recovery pass,
one proposal each) — so `proposalId` is a per-*call* invariant, not a per-*payload* one. It
belongs as an explicit parameter threaded once through the transport chain, not reconstructed
per element from data that no longer carries it (§2.0: the app must not re-derive what it can be
handed directly).

- [ ] **Step 9B.1: Thread `proposalId` through the share-delegation transport chain.** In
`secant/Sources/Features/Voting/VotingHelpers.swift`, locate the unique block:

```swift
    static func delegateSharesWithFallback(
        _ payloads: [SharePayload],
        roundId: String,
        votingAPI: VotingAPIClient,
        serverURLs: [String],
        retryDelay: Duration = .seconds(2)
    ) async throws -> ShareDelegationResult {
        guard !serverURLs.isEmpty else {
            throw ShareDelegationError.noReachableVoteServers
        }
```

and replace it with:

```swift
    static func delegateSharesWithFallback(
        _ payloads: [SharePayload],
        roundId: String,
        proposalId: UInt32,
        votingAPI: VotingAPIClient,
        serverURLs: [String],
        retryDelay: Duration = .seconds(2)
    ) async throws -> ShareDelegationResult {
        guard !serverURLs.isEmpty else {
            throw ShareDelegationError.noReachableVoteServers
        }
```

Then, in the same function, locate the unique line:

```swift
                return try await votingAPI.delegateShares(payloads, roundId, serverURLs)
```

and replace it with:

```swift
                return try await votingAPI.delegateShares(payloads, roundId, proposalId, serverURLs)
```

Second, in `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientInterface.swift`, locate
the unique block:

```swift
    var delegateShares: @Sendable (
        _ payloads: [SharePayload],
        _ roundIdHex: String,
        _ serverURLs: [String]
    ) async throws -> ShareDelegationResult
```

and replace it with:

```swift
    var delegateShares: @Sendable (
        _ payloads: [SharePayload],
        _ roundIdHex: String,
        _ proposalId: UInt32,
        _ serverURLs: [String]
    ) async throws -> ShareDelegationResult
```

Third, in `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift`, locate the
unique block:

```swift
            delegateShares: { payloads, roundIdHex, serverURLs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    // Active foreground delivery uses the submission-local server set.
                    // POST failures prune that local set immediately; cached helper
                    // health and /status probes are intentionally not consulted here.
                    // Successful/failed foreground POSTs still update the tracker for
                    // later background recovery decisions.
                    let tracker = ServerHealthTracker.shared
                    return try await delegateSharePayloads(
                        payloads,
                        roundIdHex: roundIdHex,
                        initialServerURLs: serverURLs,
                        postShare: { server, body in
                            do {
                                _ = try await postServerJSON(server, "/shielded-vote/v1/shares", body: body)
                                await tracker.recordSuccess(for: server)
                            } catch {
                                await tracker.recordFailure(for: server)
                                throw error
                            }
                        }
                    )
                }
            },
```

and replace it with:

```swift
            delegateShares: { payloads, roundIdHex, proposalId, serverURLs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    // Active foreground delivery uses the submission-local server set.
                    // POST failures prune that local set immediately; cached helper
                    // health and /status probes are intentionally not consulted here.
                    // Successful/failed foreground POSTs still update the tracker for
                    // later background recovery decisions.
                    let tracker = ServerHealthTracker.shared
                    return try await delegateSharePayloads(
                        payloads,
                        roundIdHex: roundIdHex,
                        proposalId: proposalId,
                        initialServerURLs: serverURLs,
                        postShare: { server, body in
                            do {
                                _ = try await postServerJSON(server, "/shielded-vote/v1/shares", body: body)
                                await tracker.recordSuccess(for: server)
                            } catch {
                                await tracker.recordFailure(for: server)
                                throw error
                            }
                        }
                    )
                }
            },
```

Fourth, in the same file, locate the unique block:

```swift
func delegateSharePayloads(
    _ payloads: [SharePayload],
    roundIdHex: String,
    initialServerURLs: [String],
    postShare: @escaping SharePost,
    selectTargets: @escaping ShareTargetSelector = { Array($0.shuffled().prefix($1)) }
) async throws -> ShareDelegationResult {
```

and replace it with:

```swift
func delegateSharePayloads(
    _ payloads: [SharePayload],
    roundIdHex: String,
    proposalId: UInt32,
    initialServerURLs: [String],
    postShare: @escaping SharePost,
    selectTargets: @escaping ShareTargetSelector = { Array($0.shuffled().prefix($1)) }
) async throws -> ShareDelegationResult {
```

Then, still in `delegateSharePayloads`, locate the unique block:

```swift
        results.append(DelegatedShareInfo(
            shareIndex: payload.encShare.shareIndex,
            proposalId: payload.proposalId,
            acceptedByServers: acceptedServers
        ))
```

and replace it with:

```swift
        results.append(DelegatedShareInfo(
            shareIndex: payload.shareIndex,
            proposalId: proposalId,
            acceptedByServers: acceptedServers
        ))
```

- [ ] **Step 9B.2: Fix the one existing caller — Task 9's main-path `delegateSharesWithFallback`
call.** In `VotingCoordFlowCoordinator.swift`, locate the unique block (landed by Task 9's step
9.9):

```swift
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
```

and replace it with:

```swift
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            proposalId: proposalId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
```

`proposalId` is already in scope at this call site — it is the same `draftLoop`/`drafts.
enumerated()` loop variable step 9.9's surrounding code already reads throughout.

- [ ] **Step 9B.3: Rewrite `tryRecoverInflightVote` — F3.** In `VotingCoordFlowCoordinator.swift`,
verify the anchor first (content-based, not line-based — see this section's intro):

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "static func tryRecoverInflightVote" secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift
```

Expected: one hit. Locate the full function by that signature and the matching closing `}` two
levels up (the function is `swiftlint:disable:next function_body_length cyclomatic_complexity
function_parameter_count`-annotated in the line immediately above its signature — that
attribute comment is untouched by this step and is not part of either block below). Replace the
entire function body — everything from the opening `{` of the signature through its closing
`}` — currently:

```swift
    ) async throws -> Bool {
        guard case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) else {
            return false
        }
        guard let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash),
              confirmation.code == 0,
              let leafPair = confirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index") else {
            return false
        }
        let leafParts = leafPair.split(separator: ",")
        guard leafParts.count == 2,
              let vanIdx = UInt32(leafParts[0]),
              let vcIdx = UInt64(leafParts[1]) else {
            return false
        }

        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

        guard let savedBundle = try? await votingCrypto.getVoteCommitmentBundle(roundId, bundleIndex, proposalId) else {
            LoggerProxy.error(
                """
                Recovered on-chain vote \(proposalId) for bundle \(bundleIndex), \
                but the saved commitment bundle is missing; cannot delegate tally shares.
                """
            )
            throw VotingFlowError.missingVoteCommitmentBundle
        }

        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, savedBundle, vcIdx)
        await send(.voteSubmissionStepUpdated(roundId: roundIdAction(), step: .sendingShares))

        var payloads = try await votingCrypto.buildSharePayloads(
            savedBundle.encShares, savedBundle, choice, numOptions, vcIdx, singleShare
        )
        let now = Date().timeIntervalSince1970
        for i in payloads.indices {
            if let deadline = submitAtDeadline, deadline > now {
                payloads[i].submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
            } else {
                payloads[i].submitAt = 0
            }
        }

        let recoveryResult = try await Voting.delegateSharesWithFallback(
            payloads,
            roundId: roundId,
            votingAPI: votingAPI,
            serverURLs: shareServerURLs
        )
        shareServerURLs = recoveryResult.remainingServerURLs
        for info in recoveryResult.delegatedShares {
            guard let payload = payloads.first(where: {
                $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
            }) else { continue }
            let blindIdx = Int(info.shareIndex)
            guard blindIdx < savedBundle.shareBlindFactors.count else { continue }
            do {
                let nfHex = try votingCrypto.computeShareNullifier(
                    [UInt8](savedBundle.voteCommitment),
                    info.shareIndex,
                    [UInt8](savedBundle.shareBlindFactors[blindIdx])
                )
                try await votingCrypto.recordShareDelegation(
                    roundId, bundleIndex, info.proposalId,
                    info.shareIndex, info.acceptedByServers,
                    [UInt8](votingDataFromHex(nfHex)), payload.submitAt
                )
            } catch {
                LoggerProxy.warn("Batch recovery: failed to record share delegation for share \(info.shareIndex): \(error)")
            }
        }
        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
        return true
    }
```

with:

```swift
    ) async throws -> Bool {
        guard case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) else {
            return false
        }
        guard let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash),
              confirmation.code == 0 else {
            return false
        }

        let eventsPayload: [[String: Any]] = confirmation.events.map { event in
            [
                "type": event.type,
                "attributes": event.attributes.map { attribute in
                    ["key": attribute.key, "value": attribute.value]
                }
            ]
        }
        guard let eventsData = try? JSONSerialization.data(withJSONObject: eventsPayload) else {
            return false
        }
        let eventsJson = String(decoding: eventsData, as: UTF8.self)

        guard let voteConfirmation = try? await votingCrypto.confirmVoteSubmission(
            roundId, bundleIndex, proposalId, cachedTxHash, eventsJson
        ) else {
            return false
        }

        guard let stored = try? await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
            LoggerProxy.error(
                """
                Recovered on-chain vote \(proposalId) for bundle \(bundleIndex), \
                but the saved commitment bundle is missing; cannot delegate tally shares.
                """
            )
            throw VotingFlowError.missingVoteCommitmentBundle
        }

        await send(.voteSubmissionStepUpdated(roundId: roundIdAction(), step: .sendingShares))

        // Share count is `singleShare ? 1 : numOptions` — the same two values
        // `zcash_voting::share::recover_payloads` (rc.5 `share.rs:148-188`) slices its own
        // encrypted-share list by, and the same two values Valar's reference wallet (Vizor)
        // resolves client-side rather than asking the crate for a share list: its FRB bridge
        // exposes only the per-index `recovered_vote_share_wire_json` →
        // `zcash_voting::share::recover_wire_json`, never the plural `recover_payloads`. No new
        // FFI symbol; this is the sanctioned pattern on the surface already built.
        let shareCount = singleShare ? 1 : numOptions
        let now = Date().timeIntervalSince1970
        var payloads: [SharePayload] = []
        var submitAtByShareIndex: [UInt32: UInt64] = [:]
        for shareIndex: UInt32 in 0..<shareCount {
            let submitAt: UInt64
            if let deadline = submitAtDeadline, deadline > now {
                submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
            } else {
                submitAt = 0
            }
            submitAtByShareIndex[shareIndex] = submitAt
            let wireJson = try await votingCrypto.recoverWireJson(
                stored.bundleJson, proposalId, shareIndex,
                voteConfirmation.voteCommitmentTreePosition, submitAt
            )
            payloads.append(SharePayload(wireJson: wireJson, shareIndex: shareIndex))
        }

        let recoveryResult = try await Voting.delegateSharesWithFallback(
            payloads,
            roundId: roundId,
            proposalId: proposalId,
            votingAPI: votingAPI,
            serverURLs: shareServerURLs
        )
        shareServerURLs = recoveryResult.remainingServerURLs
        for info in recoveryResult.delegatedShares {
            do {
                try await votingCrypto.recordShareDelegation(
                    roundId, bundleIndex, info.proposalId, info.shareIndex,
                    info.acceptedByServers, submitAtByShareIndex[info.shareIndex] ?? 0
                )
            } catch {
                LoggerProxy.warn("Batch recovery: failed to record share delegation for share \(info.shareIndex): \(error)")
            }
        }
        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId, cachedTxHash)
        return true
    }
```

`leaf_index` parsing, `storeVanPosition`, `getVoteCommitmentBundle`/`storeVoteCommitmentBundle`,
and `computeShareNullifier` are gone for the same reasons step 9.9 already removed them from the
main path: `confirmVoteSubmission` persists both positions atomically, and the crate derives the
share nullifier internally now (`## CORRECTIONS` item 13). `choice: VoteChoice` becomes an unused
parameter — left in the signature deliberately (the one call site already supplies it, and Swift
does not error on an unused function parameter); do not remove it or touch the call site as part
of this step. Every `try?`-guarded probe at the top keeps the function's own established idiom
("this recovery shortcut doesn't apply, fall through to a fresh build" is not the same as
swallowing a real error — the un-swallowed slow path re-attempts the identical calls with full
error propagation, satisfying Trap T3 at the system level even though this one fast-path
attempt tolerates a miss).

- [ ] **Step 9B.4: The honest-gate idiom, complete-error-list variant.** The T9 executor found
that a plain `xcodebuild build` stops emitting diagnostics after an early failure threshold,
under-reporting the true remaining count — this is why the coordinator's "16" is the *true* full
count and earlier gates in this plan may have under-counted. For this gate only (not any earlier
task's gates — do not retroactively change them), capture the complete list by temporarily
raising Xcode's own continue-past-errors limit, then revert it explicitly:

```bash
PRIOR_VALUE=$(defaults read com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors 2>/dev/null || echo "__unset__")
defaults write com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors -bool YES
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t9b-full-build.log | tail -10; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` is `0` (this is the first gate in the plan expected to be green — Task
10 is assumed already landed per this section's execution-order note). Then, regardless of the
build's outcome, revert immediately — do not leave this set for the rest of the session:

```bash
if [ "$PRIOR_VALUE" = "__unset__" ]; then
    defaults delete com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors
else
    defaults write com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors -bool "$PRIOR_VALUE"
fi
```

Then count on the complete log:

```bash
grep -c 'error:' /tmp/chp-t9b-full-build.log || true
```

Expected: **`0`**. Arithmetic: starting truth `16` (8 in Task 10's territory + 6 F3 + 2
`DelegatedShareInfo` residue, per the coordinator's live count) → post-Task-10 expected `8`
(the 6+2 this section owns; Task 10's own gate closes its 8) → post-9B expected `0` (this
section's two workstreams close the remaining 8: workstream 1 closes the 2 residue errors at
`VotingAPIClientLiveKey.swift:430-431`; workstream 2 closes F3's 6 —
`:3428` `storeVoteCommitmentBundle`, `:3431` `buildSharePayloads`, `:3451` the `SharePayload`
shape cascade, `:3465`×2 `recordShareDelegation`'s old signature, `:3471`
`markVoteSubmitted`'s missing `txHash` — all inside the one function this step replaces
wholesale). If the count is not `0`, do not treat any nonzero result as "close enough" — report
the full log tail per this plan's Global Constraint #4 (honest gates, never judged by grep
alone for pass/fail, only for the count once `BUILD_EXIT` itself is already the true signal).

- [ ] **Step 9B.5: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Features/Voting/VotingHelpers.swift secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientInterface.swift secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Resolve F3: rewire tryRecoverInflightVote on the existing per-index recovery surface" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 10

### Task 10: A3 — hotkey container (`seedPhrase: String` → `storedSecret: Data`)

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` items 5 and 6 first. This task is bigger than "swap one field": it also
repairs `generateHotkey`, `buildVotingPczt`, and `buildAndProveDelegation`, because all three
were broken against the real SDK for hotkey-shaped reasons (item 5), and it catches one more
real bug along the way (step 10.2's note) that the spec never mentioned.

**Files:**
- Modify: `secant/Sources/Dependencies/WalletStorage/StoredVotingHotkey.swift`
- Modify: `secant/Sources/Dependencies/WalletStorage/WalletStorage.swift`
- Modify: `secant/Sources/Dependencies/WalletStorage/WalletStorageInterface.swift`
- Modify: `secant/Sources/Dependencies/WalletStorage/WalletStorageLiveKey.swift`
- Verify (no edit expected): `secant/Sources/Dependencies/WalletStorage/WalletStorageTestKey.swift`
- Modify: `secant/Sources/Dependencies/VotingModels/VotingModels.swift` (`VotingHotkey`)
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:974-989,1770-1771,2042-2044,2626-2630,2793-2836,3513-3611`

**Interfaces:**
- Consumes: `VotingRustBackend.generateHotkey(networkId: UInt32) throws -> VotingHotkey` (SDK
  model: `storedSecret: [UInt8]`, `rawOrchardAddress: [UInt8]`, `addressIndex: UInt32`);
  `VotingRustBackend.generateDelegationInputs(senderSeed:hotkeyStoredSecret:networkId:
  accountIndex:)` / `(senderFvk:hotkeyStoredSecret:networkId:seedFingerprint:)` (both already
  take `hotkeyStoredSecret`, unaffected by this task's own edits);
  `VotingBuildPcztParams(roundId:bundleIndex:notes:keys: VotingDelegationKeyInputs:
  consensusBranchId:)`; `VotingDelegationProofParams(roundId:bundleIndex:notes:keys:)`.
- Produces: `StoredVotingHotkey(storedSecret: VotingHotkeySecret, version: Int)`;
  `WalletStorage.importVotingHotkey(_ storedSecret: Data, accountId:)`; app-level
  `VotingCryptoClient.generateHotkey(_ networkId: UInt32) async throws -> VotingHotkey`;
  `buildAndProveDelegation` gains a `roundName: String` parameter (see step 10.13).

---

- [ ] **Step 10.1: Give the voting hotkey its own keychain version, independent of the
wallet's.** `Constants.zcashKeychainVersion` (`WalletStorage.swift:39`) is shared with the
regular wallet's `StoredWallet` (`:101`, `:138`) — bumping it would invalidate every user's
*wallet* keychain entry, not just the (currently nonexistent) voting hotkey one. In
`WalletStorage.swift`, replace:

```swift
        static let zcashKeychainVersion = 1
```

with:

```swift
        static let zcashKeychainVersion = 1
        /// Independent from `zcashKeychainVersion`: voting hotkeys have their own storage
        /// generation so a hotkey-format change (like this one) never touches the wallet's own
        /// keychain entry. Bumped 1 → 2 for the `seedPhrase` → `storedSecret` container swap.
        static let zcashVotingHotkeyVersion = 2
```

- [ ] **Step 10.2: Re-shape `StoredVotingHotkey`.** In `StoredVotingHotkey.swift`, replace the
entire file content with:

```swift
//
//  StoredVotingHotkey.swift
//  Zashi
//

import Foundation

struct StoredVotingHotkey: Codable, Equatable {
    let storedSecret: VotingHotkeySecret
    let version: Int

    init(storedSecret: VotingHotkeySecret, version: Int) {
        self.storedSecret = storedSecret
        self.version = version
    }
}

/// Read-only redacted holder for a voting hotkey's stored secret.
///
/// Key material — same handling as `SeedPhrase` (`CHP_DESIGN.md` §0.5): never logged, never
/// printed via reflection. Mirrors `SeedPhrase`'s exact pattern (`Sources/Utils/
/// SensitiveData.swift`) rather than storing bare `Data` on `StoredVotingHotkey`.
struct VotingHotkeySecret: Codable, Equatable, Redactable {
    private let secret: Data

    init(_ secret: Data) {
        self.secret = secret
    }

    /// Returns the raw secret bytes with no `Redactable` protection. Use it only to hand the
    /// bytes to `VotingCryptoClient`/`VotingRustBackend`; never log or print the result.
    func value() -> Data {
        secret
    }
}
```

- [ ] **Step 10.3: Rewrite `importVotingHotkey`/`exportVotingHotkey`.** In
`WalletStorage.swift`, replace:

```swift
    func importVotingHotkey(_ phrase: String, accountId: AccountUUID) throws {
        let hotkey = StoredVotingHotkey(seedPhrase: SeedPhrase(phrase), version: Constants.zcashKeychainVersion)
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        do {
            guard let data = try encode(object: hotkey) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    func exportVotingHotkey(accountId: AccountUUID) throws -> StoredVotingHotkey {
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        let reqData: Data?
        do {
            reqData = try data(forKey: key)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        }
        guard let reqData else { throw WalletStorageError.uninitializedWallet }
        guard let hotkey = try decode(json: reqData, as: StoredVotingHotkey.self) else {
            throw WalletStorageError.uninitializedWallet
        }
        guard hotkey.version == Constants.zcashKeychainVersion else {
            throw WalletStorageError.unsupportedVersion(hotkey.version)
        }
        return hotkey
    }
```

with:

```swift
    func importVotingHotkey(_ storedSecret: Data, accountId: AccountUUID) throws {
        let hotkey = StoredVotingHotkey(
            storedSecret: VotingHotkeySecret(storedSecret),
            version: Constants.zcashVotingHotkeyVersion
        )
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        do {
            guard let data = try encode(object: hotkey) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    func exportVotingHotkey(accountId: AccountUUID) throws -> StoredVotingHotkey {
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        let reqData: Data?
        do {
            reqData = try data(forKey: key)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        }
        guard let reqData else { throw WalletStorageError.uninitializedWallet }
        guard let hotkey = try decode(json: reqData, as: StoredVotingHotkey.self) else {
            throw WalletStorageError.uninitializedWallet
        }
        guard hotkey.version == Constants.zcashVotingHotkeyVersion else {
            throw WalletStorageError.unsupportedVersion(hotkey.version)
        }
        return hotkey
    }
```

No migration: a keychain entry written by the old `seedPhrase`-shaped struct fails
`decode(json:as:StoredVotingHotkey.self)` outright (the JSON has no `storedSecret` key), so
`exportVotingHotkey` throws `.uninitializedWallet` — exactly "no hotkey" — with no separate
handling needed (spec `CHP_DESIGN.md` §3/A3: "none exist in the wild").

- [ ] **Step 10.4: Re-type the interface member.** In `WalletStorageInterface.swift`, replace:

```swift
    var importVotingHotkey: @Sendable (_ phrase: String, _ accountId: AccountUUID) throws -> Void
```

with:

```swift
    var importVotingHotkey: @Sendable (_ storedSecret: Data, _ accountId: AccountUUID) throws -> Void
```

- [ ] **Step 10.5: Re-type the LiveKey closure.** In `WalletStorageLiveKey.swift`, replace:

```swift
            importVotingHotkey: { phrase, accountId in
                try walletStorage.importVotingHotkey(phrase, accountId: accountId)
            },
```

with:

```swift
            importVotingHotkey: { storedSecret, accountId in
                try walletStorage.importVotingHotkey(storedSecret, accountId: accountId)
            },
```

- [ ] **Step 10.6: Verify `WalletStorageTestKey.swift` needs no edit.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n 'importVotingHotkey' secant/Sources/Dependencies/WalletStorage/WalletStorageTestKey.swift
```

Expected: `importVotingHotkey: { _, _ in },` — both parameters already ignored positionally, so
the `String` → `Data` change requires no edit here (`## CORRECTIONS` item 2's same reasoning).

- [ ] **Step 10.7: Re-shape the app-level `VotingHotkey` model.** In `VotingModels.swift`,
replace (lines 257-267):

```swift
struct VotingHotkey: Equatable, Sendable {
    let secretKey: Data
    let publicKey: Data
    let address: String

    init(secretKey: Data, publicKey: Data, address: String) {
        self.secretKey = secretKey
        self.publicKey = publicKey
        self.address = address
    }
}
```

with:

```swift
struct VotingHotkey: Equatable, Sendable {
    /// The material to persist via `WalletStorage.importVotingHotkey(_:accountId:)`. Treat it
    /// as key material, not as an identifier.
    let storedSecret: Data
    /// Raw Orchard address bytes for the hotkey, derived from `storedSecret`.
    let rawOrchardAddress: Data
    /// Address index the hotkey's Orchard address was derived at.
    let addressIndex: UInt32

    init(storedSecret: Data, rawOrchardAddress: Data, addressIndex: UInt32) {
        self.storedSecret = storedSecret
        self.rawOrchardAddress = rawOrchardAddress
        self.addressIndex = addressIndex
    }
}
```

This mirrors the SDK's `VotingHotkey` (`VotingTypes.swift:50-57`) field-for-field except for the
missing displayable address — see step 10.15's finding. `RoundStateInfo.hotkeyAddress: String?`
and `VotingCoordFlow.Action.hotkeyLoaded(roundId:address: String)` are untouched by this step;
step 10.13 is where their input has to come from something, which is exactly the finding.

- [ ] **Step 10.8: Re-type `generateHotkey`.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var generateHotkey: @Sendable (_ roundId: String, _ seed: [UInt8]) async throws -> VotingHotkey
```

with:

```swift
    /// Generate a new voting hotkey for `networkId`. The application must persist the returned
    /// `storedSecret` — it cannot be recovered from the wallet seed (spec `CHP_DESIGN.md` §7.5
    /// leak point 1 / CHP.md §11.5 N... hotkey is app-owned random material, not a wallet-seed
    /// derivation). Calling this again produces an unrelated hotkey, not a recovery of the
    /// previous one.
    var generateHotkey: @Sendable (_ networkId: UInt32) async throws -> VotingHotkey
```

- [ ] **Step 10.9: Re-implement `generateHotkey`.** In `VotingCryptoClientLiveKey.swift`,
replace:

```swift
            generateHotkey: { roundId, seed in
                let backend = try await dbActor.backend()
                let hotkey = try backend.generateHotkey(seed: seed)
                return VotingHotkey(
                    secretKey: Data(hotkey.secretKey),
                    publicKey: Data(hotkey.publicKey),
                    address: hotkey.address
                )
            },
```

with:

```swift
            generateHotkey: { networkId in
                let hotkey = try VotingRustBackend.generateHotkey(networkId: networkId)
                return VotingHotkey(
                    storedSecret: Data(hotkey.storedSecret),
                    rawOrchardAddress: Data(hotkey.rawOrchardAddress),
                    addressIndex: hotkey.addressIndex
                )
            },
```

`VotingRustBackend.generateHotkey(networkId:)` is `static` and takes no database handle
(`VotingRustBackend.swift:1280`) — no `dbActor.backend()` call needed, matching how
`warmProvingCaches`/`computeShareNullifier` (other static members) are already implemented in
this file.

- [ ] **Step 10.10: Rebuild `buildVotingPczt`'s parameter construction.** In the same file,
replace (the whole closure, currently spanning what was originally `:189-267` before Task 8's
edits shifted line numbers upstream — locate by the `buildVotingPczt:` label):

```swift
            // swiftlint:disable:next line_length
            buildVotingPczt: { roundId, bundleIndex, notes, senderSeed, hotkeySeed, networkId, accountIndex, roundName, orchardFvkOverride, keystoneSeedFingerprintOverride in
                let backend = try await dbActor.backend()
                _ = try backend.generateHotkey(seed: hotkeySeed)
                let inputs: VotingDelegationInputs
                let actualFvkBytes: [UInt8]
                if let orchardFvkOverride {
                    guard let keystoneSeedFingerprintOverride else {
                        throw VotingCryptoError.invalidKeystoneMetadata
                    }
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderFvk: [UInt8](orchardFvkOverride),
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        seedFingerprint: [UInt8](keystoneSeedFingerprintOverride)
                    )
                    actualFvkBytes = [UInt8](orchardFvkOverride)
                } else {
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex
                    )
                    actualFvkBytes = inputs.fvkBytes
                }
                let sdkNotes = notes.map { $0.toSDK() }
                // NU6 consensus branch ID; BIP44 coin type 133 = Zcash mainnet, 1 = testnet
                // (`network_id` 1 / 0 per `parse_network` in libzcashlc).
                let consensusBranchId: UInt32 = 0xC8E7_1055
                let coinType: UInt32 = networkId == 1 ? 133 : 1
                let result = try backend.buildPczt(VotingBuildPcztParams(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    fvk: actualFvkBytes,
                    hotkeyRawAddress: inputs.hotkeyRawAddress,
                    consensusBranchId: consensusBranchId,
                    coinType: coinType,
                    seedFingerprint: inputs.seedFingerprint,
                    accountIndex: accountIndex,
                    roundName: roundName,
                    addressIndex: 0
                ))
                publishState(backend: backend, roundId: roundId)
```

with:

```swift
            // swiftlint:disable:next line_length
            buildVotingPczt: { roundId, bundleIndex, notes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, orchardFvkOverride, keystoneSeedFingerprintOverride in
                let backend = try await dbActor.backend()
                let inputs: VotingDelegationInputs
                let actualFvkBytes: [UInt8]
                if let orchardFvkOverride {
                    guard let keystoneSeedFingerprintOverride else {
                        throw VotingCryptoError.invalidKeystoneMetadata
                    }
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderFvk: [UInt8](orchardFvkOverride),
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        seedFingerprint: [UInt8](keystoneSeedFingerprintOverride)
                    )
                    actualFvkBytes = [UInt8](orchardFvkOverride)
                } else {
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderSeed: senderSeed,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        accountIndex: accountIndex
                    )
                    actualFvkBytes = inputs.fvkBytes
                }
                let sdkNotes = notes.map { $0.toSDK() }
                // NU6 consensus branch ID; BIP44 coin type 133 = Zcash mainnet, 1 = testnet
                // (`network_id` 1 / 0 per `parse_network` in libzcashlc).
                // Plan Task 11 replaces this literal with the SDK's public constant.
                let consensusBranchId: UInt32 = 0xC8E7_1055
                let keys = VotingDelegationKeyInputs(
                    fvk: actualFvkBytes,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    seedFingerprint: inputs.seedFingerprint,
                    accountIndex: accountIndex,
                    roundName: roundName
                )
                let result = try backend.buildPczt(VotingBuildPcztParams(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    keys: keys,
                    consensusBranchId: consensusBranchId
                ))
                publishState(backend: backend, roundId: roundId)
```

`VotingDelegationKeyInputs` has no `hotkeyRawAddress` field — `zcash_voting` now derives the
hotkey's Orchard address from `hotkeyStoredSecret` internally (its own doc comment,
`VotingTypes.swift:450-454`), so `inputs.hotkeyRawAddress` is simply not needed here; `coinType`
and `addressIndex` are dropped for the same reason (`VotingBuildPcztParams` never had them —
they were invented fields on a struct literal that never matched the real type). The rest of
the closure (from `let pcztBytes: Data = Data(result.pcztBytes)` through the final `return
VotingPcztResult(...)`) is unchanged — leave it exactly as it stands.

- [ ] **Step 10.11: Rebuild `buildAndProveDelegation`'s parameter construction — and add the
`roundName` it now requires.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

with:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

`VotingDelegationKeyInputs` (bundled into the real `buildAndProveDelegation`'s
`VotingDelegationProofParams`) requires `roundName`, which this member never took — it is added
here as a new, required 8th parameter (both call sites, step 10.14, already have a round name in
scope).

- [ ] **Step 10.12: Re-implement `buildAndProveDelegation`.** In
`VotingCryptoClientLiveKey.swift`, replace:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeySeed, networkId, accountIndex, pirEndpoints, expectedSnapshotHeight in
                AsyncThrowingStream<ProofEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let inputs = try VotingRustBackend.generateDelegationInputs(
                                senderSeed: senderSeed,
                                hotkeySeed: hotkeySeed,
                                networkId: networkId,
                                accountIndex: accountIndex
                            )
                            let sdkNotes = bundleNotes.map { $0.toSDK() }
                            let result = try await backend.buildAndProveDelegation(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                notes: sdkNotes,
                                hotkeyRawAddress: inputs.hotkeyRawAddress,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                networkId: networkId,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            // Don't call publishState here — the Rust FFI may still hold
                            // a brief RefCell borrow on the DB connection, and publishState
                            // borrows it again. Let the store call refreshState after
                            // receiving .completed to avoid the concurrent borrow panic.
                            continuation.yield(.completed(Data(result.proof)))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
```

with:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight in
                AsyncThrowingStream<ProofEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let inputs = try VotingRustBackend.generateDelegationInputs(
                                senderSeed: senderSeed,
                                hotkeyStoredSecret: hotkeyStoredSecret,
                                networkId: networkId,
                                accountIndex: accountIndex
                            )
                            let sdkNotes = bundleNotes.map { $0.toSDK() }
                            let keys = VotingDelegationKeyInputs(
                                fvk: inputs.fvkBytes,
                                hotkeyStoredSecret: hotkeyStoredSecret,
                                seedFingerprint: inputs.seedFingerprint,
                                accountIndex: accountIndex,
                                roundName: roundName
                            )
                            let params = VotingDelegationProofParams(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                notes: sdkNotes,
                                keys: keys
                            )
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            // Don't call publishState here — the Rust FFI may still hold
                            // a brief RefCell borrow on the DB connection, and publishState
                            // borrows it again. Let the store call refreshState after
                            // receiving .completed to avoid the concurrent borrow panic.
                            continuation.yield(.completed(Data(result.proof)))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
```

(This is where SDK-lane Task 1's `pirLayout:` parameter will also land — plan Task 12 adds it
on top of this same closure; do not add it here.)

- [ ] **Step 10.13: Rewire the hotkey load-or-generate site.** In
`VotingCoordFlowCoordinator.swift` (`:974-989` at plan-writing time — Tasks 8 and 9 already
edited this same file above this point in the ladder, so treat that line range as a hint and
the unique code block below as the authoritative locator), replace:

```swift
                    let phrase: String
                    if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                        phrase = stored.seedPhrase.value()
                    } else {
                        phrase = try mnemonic.randomMnemonic()
                        try walletStorage.importVotingHotkey(phrase, accountId)
                    }
                    let seed = try mnemonic.toSeed(phrase)
                    let hotkey = try await votingCrypto.generateHotkey(roundId, seed)
                    await send(.hotkeyLoaded(roundId: roundId, address: hotkey.address))
```

with:

```swift
                    let storedSecret: Data
                    if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                        storedSecret = stored.storedSecret.value()
                    } else {
                        let hotkey = try await votingCrypto.generateHotkey(networkId)
                        storedSecret = hotkey.storedSecret
                        try walletStorage.importVotingHotkey(storedSecret, accountId)
                    }
                    await send(.hotkeyLoaded(roundId: roundId, address: ""))
```

`mnemonic.randomMnemonic()`/`mnemonic.toSeed(_:)` are no longer needed here: the SDK generates
the secret's randomness internally now (`VotingRustBackend.generateHotkey(networkId:)`'s own doc
comment — no seed in), so the app no longer produces or derives one for this purpose. The
`address: ""` is step 10.15's finding surfacing directly in the diff rather than being silently
dropped — see that step before treating this line as final.

- [ ] **Step 10.14: Delete the four remaining `mnemonic.toSeed` hotkey-derivation sites.** In
the same file, replace each of the following four two-line derivations with the one-line
`storedSecret` read shown, leaving every other line in each surrounding block untouched. Same
caveat as step 10.13: the four line numbers below (`:1770-1771`/`:2043-2044`/`:2629-2630`/
`:2835-2836`) are plan-writing-time hints, not guarantees — Tasks 8 and 9 already edited this
file above these points, so locate each site by its unique two-line snippet, not by number.

At `:1770-1771` (inside the batch vote-submission `.run` closure):

```swift
            let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
            let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
            let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

At `:2043-2044` (inside `reduceMaybeStartDelegationPrecompute`'s `.run` closure):

```swift
            let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
            let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
            let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

At `:2629-2630` (inside the Keystone PCZT-prep `.run` closure):

```swift
                let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

At `:2835-2836` (inside `reduceKeystoneAllBundlesSigned`'s `.run` closure — note the sender-seed
derivation on the two lines immediately above this one, `:2833-2834`, is a **different** value,
the wallet's own seed, and is explicitly not touched by this task):

```swift
                let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

Then, in `reduceKeystoneAllBundlesSigned` (the same function as the fourth site above), add the
`roundName` local variable step 10.11's new parameter needs — replace:

```swift
        let bundleCount = session.bundleCount
        let storedSignatures = session.keystoneBundleSignatures.sorted { $0.bundleIndex < $1.bundleIndex }
```

with:

```swift
        let bundleCount = session.bundleCount
        let roundName = activeSession.title
        let storedSignatures = session.keystoneBundleSignatures.sorted { $0.bundleIndex < $1.bundleIndex }
```

(`activeSession` is already in scope in this function, bound a few lines above at
`guard let activeSession = state.allRounds.first(where: { $0.id == roundId })?.session else`.)
Then, in the same function's `buildAndProveDelegation` call, replace:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
```

with:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
```

Finally, in `runDelegationPipeline` (`static func`, `:3513-3611`), which already receives
`roundName: String` as its own parameter, replace its `buildAndProveDelegation` call:

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex,
                    pirEndpoints, expectedSnapshotHeight
                ) {
```

with:

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                    pirEndpoints, expectedSnapshotHeight
                ) {
```

(`runDelegationPipeline`'s own `hotkeySeed` parameter is untouched by this task's four
derivation-site edits above — it is a function parameter supplied by its one caller, the batch
vote-submission closure at `:1770-1771`, and now carries the stored secret transparently once
that call site's own local is fixed.)

- [ ] **Step 10.15: STOP-and-report — the hotkey display-address encoding gap (finding, not a
code step).** Read `## CORRECTIONS` item 6. `RoundStateInfo.hotkeyAddress: String?`
(`VotingModels.swift:157`) and `VotingCoordFlow.Action.hotkeyLoaded(roundId:address: String)`
(`VotingCoordFlowStore.swift:264`, consumed at `VotingCoordFlowCoordinator.swift:1096`) both
require a human-displayable address string. The SDK's `VotingHotkey.rawOrchardAddress` is raw
bytes, and no encoder from raw Orchard address bytes to a UA/address string exists anywhere in
`secant/Sources/` or `zcash-swift-wallet-sdk/Sources/` at plan-writing time (`## CORRECTIONS`
item 6's grep).

Decision procedure:
1. Grep one more time, scoped to what actually landed: `grep -rn 'OrchardAddress\|unified.*[Aa]ddress.*encod\|encode.*[Aa]ddress' Sources/ZcashLightClientKit/` in the SDK worktree, and
   `grep -rn 'UnifiedAddress\|orchardReceiver' secant/Sources/Dependencies/SDKSynchronizer/` in the app. If
   a general Orchard/UA encoder now exists that takes raw receiver bytes, use it at step
   10.13's `await send(.hotkeyLoaded(roundId: roundId, address: ...))` call and remove the
   `address: ""` placeholder there.
2. If not: leave `address: ""` exactly as step 10.13 wrote it (a real empty string, not a
   crash — `hotkeyAddress` is already `String?`-shaped for a reason and every read site treats
   absence as "unknown", not as an error) and surface as a named, non-blocking finding: *"the
   voting hotkey's displayable address has no encoder under the 2.0 API; UI that shows it will
   render blank until one is added — this is the app rendering an engine value verbatim (per
   the no-corrections rule), not the app inventing one."* Confirm at review time that no screen
   this plan is required to leave frozen depends on this string being non-empty for correctness
   (only for display) before accepting the empty string as adequate for gate 5.

- [ ] **Step 10.16: Progress gate.** Same two-command idiom as Step 8.13. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t10-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t10-build.log || true
```

Expected: a number, strictly less than Step 9.12's count (exit status not judged).
`seedPhrase\|mnemonic.toSeed.*hotkey` must not appear in the log at any of the four sites step
10.14 touched.

- [ ] **Step 10.17: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/WalletStorage/StoredVotingHotkey.swift secant/Sources/Dependencies/WalletStorage/WalletStorage.swift secant/Sources/Dependencies/WalletStorage/WalletStorageInterface.swift secant/Sources/Dependencies/WalletStorage/WalletStorageLiveKey.swift secant/Sources/Dependencies/VotingModels/VotingModels.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Swap the voting hotkey container from a seed phrase to a stored secret" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 11

### Task 11: A4 — Ironwood branch-ID fix

*Code blocks by: Sonnet (app delegate).*

**Files:**
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`

**Interfaces:**
- Consumes: `public extension ZcashSDK { static let nu63ConsensusBranchID: ConsensusBranchID }`
  (SDK-lane Task 4; `ConsensusBranchID = Int32`, per `## INTERFACES-FOR-APP`: *"the app's
  `VotingBuildPcztParams.consensusBranchId` is `UInt32`, so the app converts with
  `UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)`"* — confirmed against the real
  `VotingBuildPcztParams.consensusBranchId: UInt32` (`VotingTypes.swift:488`).
- Produces: no public surface change — internal literal only.

---

- [ ] **Step 11.1: Replace the hardcoded branch ID.** In
`VotingCryptoClientLiveKey.swift`, inside the `buildVotingPczt` closure Task 10's step 10.10
rebuilt, replace:

```swift
                // NU6 consensus branch ID; BIP44 coin type 133 = Zcash mainnet, 1 = testnet
                // (`network_id` 1 / 0 per `parse_network` in libzcashlc).
                // Plan Task 11 replaces this literal with the SDK's public constant.
                let consensusBranchId: UInt32 = 0xC8E7_1055
```

with:

```swift
                // Ironwood (NU6.3) consensus branch ID, published by the SDK so a future
                // network upgrade cannot go stale here the way the old hardcoded NU6 literal
                // did (CHP.md §11.5 N1).
                let consensusBranchId = UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)
```

- [ ] **Step 11.2: Single-source assert.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -rn '0xC8E7_1055\|0xC8E71055' secant/
```

Expected: no output. Any hit means the literal survives somewhere this task didn't reach
(check `zodlTests/` too — a hit there is a deviation to surface, not silently port).

- [ ] **Step 11.3: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift && git commit -m "[MOB-1678] Fix the hardcoded NU6 consensus branch ID to Ironwood (NU6.3)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 12

### Task 12: A5 — decode `pir_layout` + plumb to PIR entry points

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` item 9 first — `PirSnapshotResolver`'s `pir_depth` field is unrelated
decode, not "half" of this one. This task also fixes a pre-existing bug in
`precomputeDelegationPir`'s `LiveKey` closure it happens to touch (a `networkId:` argument the
real SDK function has never taken) — noted inline at step 12.5, not silently ported.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingModels/VotingServiceConfig.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift` (both `precomputeDelegationPir` and `buildAndProveDelegation` call sites)

**Interfaces:**
- Consumes: `VotingRustBackend.precomputeDelegationPir(...pirLayout: VotingPirLayout = .unknown...)` and `.buildAndProveDelegation(_:...pirLayout: VotingPirLayout = .unknown...)` (SDK-lane Task 1; default is fail-closed — `## INTERFACES-FOR-APP`: *"Leaving it at `.unknown` makes every PIR call throw"*).
- Produces: `VotingServiceConfig.pirLayout: VotingServiceConfig.PirLayout` (required, top-level, `pir_depth`/`tier0_layers`/`tier1_layers`); both app-level `VotingCryptoClient` PIR members gain three trailing `UInt32` parameters.

---

- [ ] **Step 12.1: Decode `pir_layout`.** In `VotingServiceConfig.swift`, replace:

```swift
struct VotingServiceConfig: Codable, Equatable, Sendable {
    let configVersion: Int
    let voteServers: [ServiceEndpoint]
    let pirEndpoints: [ServiceEndpoint]
    let supportedVersions: SupportedVersions
    let rounds: [String: RoundEntry]

    struct ServiceEndpoint: Codable, Equatable, Sendable {
```

with:

```swift
struct VotingServiceConfig: Codable, Equatable, Sendable {
    let configVersion: Int
    let voteServers: [ServiceEndpoint]
    let pirEndpoints: [ServiceEndpoint]
    let supportedVersions: SupportedVersions
    let rounds: [String: RoundEntry]
    /// PIR tree geometry the round's dynamic config advertises. Required, not optional:
    /// `zcash_voting` (rc.4+) runs a config/server layout handshake and fails closed before
    /// any private query if a caller's layout disagrees with what the PIR server serves, so a
    /// wallet that cannot decode this has nothing safe to fall back to.
    let pirLayout: PirLayout

    /// Mirrors `zcash_voting::config::PirLayout` field for field.
    struct PirLayout: Codable, Equatable, Sendable {
        let pirDepth: UInt32
        let tier0Layers: UInt32
        let tier1Layers: UInt32

        enum CodingKeys: String, CodingKey {
            case pirDepth = "pir_depth"
            case tier0Layers = "tier0_layers"
            case tier1Layers = "tier1_layers"
        }

        init(pirDepth: UInt32, tier0Layers: UInt32, tier1Layers: UInt32) {
            self.pirDepth = pirDepth
            self.tier0Layers = tier0Layers
            self.tier1Layers = tier1Layers
        }
    }

    struct ServiceEndpoint: Codable, Equatable, Sendable {
```

Then, in the same file, replace the memberwise `init` and `CodingKeys` (lines 68-90):

```swift
    init(
        configVersion: Int,
        voteServers: [ServiceEndpoint],
        pirEndpoints: [ServiceEndpoint],
        supportedVersions: SupportedVersions,
        rounds: [String: RoundEntry]
    ) {
        self.configVersion = configVersion
        self.voteServers = voteServers
        self.pirEndpoints = pirEndpoints
        self.supportedVersions = supportedVersions
        self.rounds = rounds
    }

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case voteServers = "vote_servers"
        case pirEndpoints = "pir_endpoints"
        case supportedVersions = "supported_versions"
        case rounds
    }

}
```

with:

```swift
    init(
        configVersion: Int,
        voteServers: [ServiceEndpoint],
        pirEndpoints: [ServiceEndpoint],
        supportedVersions: SupportedVersions,
        rounds: [String: RoundEntry],
        pirLayout: PirLayout
    ) {
        self.configVersion = configVersion
        self.voteServers = voteServers
        self.pirEndpoints = pirEndpoints
        self.supportedVersions = supportedVersions
        self.rounds = rounds
        self.pirLayout = pirLayout
    }

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case voteServers = "vote_servers"
        case pirEndpoints = "pir_endpoints"
        case supportedVersions = "supported_versions"
        case rounds
        case pirLayout = "pir_layout"
    }

}
```

A config JSON missing `pir_layout` now fails `Decodable` synthesis outright ("keyNotFound") —
this is the "REQUIRES" from spec `CHP_DESIGN.md` §2.4/A5, enforced by the type system rather
than a separate runtime check, matching how `configVersion`/`voteServers`/etc. are already
enforced in this same struct.

- [ ] **Step 12.2: Thread `pirLayout` into `precomputeDelegationPir`'s interface + fix its
pre-existing `networkId:` bug.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var precomputeDelegationPir: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ networkId: UInt32
    ) async throws -> DelegationPirPrecomputeResult
```

with:

```swift
    var precomputeDelegationPir: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ networkId: UInt32,
        _ pirDepth: UInt32,
        _ tier0Layers: UInt32,
        _ tier1Layers: UInt32
    ) async throws -> DelegationPirPrecomputeResult
```

- [ ] **Step 12.3: Re-implement `precomputeDelegationPir`.** In
`VotingCryptoClientLiveKey.swift`, replace:

```swift
            precomputeDelegationPir: { roundId, bundleIndex, bundleNotes, pirEndpoints, expectedSnapshotHeight, networkId in
                let backend = try await dbActor.backend()
                let sdkNotes = bundleNotes.map { $0.toSDK() }
                let result = try await backend.precomputeDelegationPir(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    networkId: networkId
                )
                return DelegationPirPrecomputeResult(
                    cachedCount: result.cachedCount,
                    fetchedCount: result.fetchedCount
                )
            },
```

with:

```swift
            precomputeDelegationPir: { roundId, bundleIndex, bundleNotes, pirEndpoints, expectedSnapshotHeight, networkId, pirDepth, tier0Layers, tier1Layers in
                let backend = try await dbActor.backend()
                let sdkNotes = bundleNotes.map { $0.toSDK() }
                let result = try await backend.precomputeDelegationPir(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    pirLayout: VotingPirLayout(pirDepth: pirDepth, tier0Layers: tier0Layers, tier1Layers: tier1Layers)
                )
                return DelegationPirPrecomputeResult(
                    cachedCount: result.cachedCount,
                    fetchedCount: result.fetchedCount
                )
            },
```

`networkId` stays a parameter of the app-level member (its one call site already passes it, and
removing it would be an unrelated interface shrink this task does not need to make) — it is
simply no longer forwarded to `backend.precomputeDelegationPir`, because the real function has
never taken it (verified: `VotingRustBackend.swift:138-145`; the old code's `networkId:`
argument was never valid against this SDK generation).

- [ ] **Step 12.4: Thread `pirLayout` into `buildAndProveDelegation` — on top of Task 10's
`roundName` addition.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

with:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ pirDepth: UInt32,
        _ tier0Layers: UInt32,
        _ tier1Layers: UInt32
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

- [ ] **Step 12.5: Re-implement `buildAndProveDelegation`.** In
`VotingCryptoClientLiveKey.swift`, replace:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight in
```

with:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight, pirDepth, tier0Layers, tier1Layers in
```

Then, in the same closure, replace:

```swift
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
```

with:

```swift
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                pirLayout: VotingPirLayout(pirDepth: pirDepth, tier0Layers: tier0Layers, tier1Layers: tier1Layers),
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
```

- [ ] **Step 12.6: Thread the resolved layout through the three coordinator call sites.** In
`VotingCoordFlowCoordinator.swift`, in `reduceMaybeStartDelegationPrecompute`, replace:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url).nonEmpty,
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount),
            let accountId = state.selectedWalletAccount?.id
        else {
            return .none
        }
```

with:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url).nonEmpty,
            let pirLayout = state.serviceConfig?.pirLayout,
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount),
            let accountId = state.selectedWalletAccount?.id
        else {
            return .none
        }
```

then, in the same function's `.run` closure, replace:

```swift
                let result = try await votingCrypto.precomputeDelegationPir(
                    roundId,
                    bundleIndex,
                    bundleNotes,
                    pirEndpoints,
                    expectedSnapshotHeight,
                    networkId
                )
```

with:

```swift
                let result = try await votingCrypto.precomputeDelegationPir(
                    roundId,
                    bundleIndex,
                    bundleNotes,
                    pirEndpoints,
                    expectedSnapshotHeight,
                    networkId,
                    pirLayout.pirDepth,
                    pirLayout.tier0Layers,
                    pirLayout.tier1Layers
                )
```

(`pirLayout` must be added to this `.run`'s capture list alongside `[votingCrypto, mnemonic,
walletStorage]` for the closure to see it.)

In `reduceKeystoneAllBundlesSigned`, replace:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
            !pirEndpoints.isEmpty,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
```

with:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
            !pirEndpoints.isEmpty,
            let pirLayout = state.serviceConfig?.pirLayout,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
```

then, in the same function's `buildAndProveDelegation` call (as rewritten by Task 10's step
10.14), replace:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
```

with:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight,
                        pirLayout.pirDepth,
                        pirLayout.tier0Layers,
                        pirLayout.tier1Layers
                    ) {
```

(`pirLayout` must be added to this function's `.run` capture list, `[backgroundTask,
votingCrypto, votingAPI, mnemonic, walletStorage]`.)

Finally, `runDelegationPipeline` (`static func`) needs the layout as three new parameters —
replace its signature:

```swift
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .seconds(2)
    ) async throws {
```

with:

```swift
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirDepth: UInt32,
        tier0Layers: UInt32,
        tier1Layers: UInt32,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .seconds(2)
    ) async throws {
```

its `buildAndProveDelegation` call (as rewritten by Task 10's step 10.14):

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                    pirEndpoints, expectedSnapshotHeight
                ) {
```

with:

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                    pirEndpoints, expectedSnapshotHeight, pirDepth, tier0Layers, tier1Layers
                ) {
```

and its one call site (inside the batch vote-submission `.run` closure, `:1778-1793`):

```swift
                    try await Self.runDelegationPipeline(
                        roundId: roundId,
                        cachedNotes: cachedNotes,
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        roundName: roundName,
                        pirEndpoints: pirEndpoints,
                        expectedSnapshotHeight: expectedSnapshotHeight,
                        delegationPrepared: delegationPrepared,
                        seedFingerprint: seedFingerprint,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI,
                        send: send
                    )
```

with:

```swift
                    try await Self.runDelegationPipeline(
                        roundId: roundId,
                        cachedNotes: cachedNotes,
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        roundName: roundName,
                        pirEndpoints: pirEndpoints,
                        expectedSnapshotHeight: expectedSnapshotHeight,
                        pirDepth: pirLayout.pirDepth,
                        tier0Layers: pirLayout.tier0Layers,
                        tier1Layers: pirLayout.tier1Layers,
                        delegationPrepared: delegationPrepared,
                        seedFingerprint: seedFingerprint,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI,
                        send: send
                    )
```

which requires `pirLayout` to be resolved earlier in that same enclosing reducer function
(alongside wherever `pirEndpoints`/`roundName` are already resolved for this call site) — locate
the `guard`/`let` that currently produces `pirEndpoints` for this call site and add
`let pirLayout = state.serviceConfig?.pirLayout` to it the same way step 12.6 did for the other
two sites; if no such single `guard` exists here (this call site may resolve `pirEndpoints` from
a different local than the other two), add the binding at the nearest point before this call
where `state`/`serviceConfig` is still reachable, failing the action with the same "serviceConfig
unexpectedly nil" pattern used at the other two sites if it is not.

- [ ] **Step 12.7: Prove no production call site was left on the fail-closed default.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n 'votingCrypto.precomputeDelegationPir(\|votingCrypto.buildAndProveDelegation(\|runDelegationPipeline(' secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift
```

For every `precomputeDelegationPir(`/`buildAndProveDelegation(` hit, manually confirm (by
reading the surrounding 15 lines) that the call passes `pirLayout.pirDepth`/
`.tier0Layers`/`.tier1Layers` (or, for `runDelegationPipeline`, `pirDepth:`/`tier0Layers:`/
`tier1Layers:`) and not a bare literal or an omitted argument. Any call site missing them is a
real bug this step must fix before proceeding — the app-level members have no default, so a
missed site is a compile error, not a silent fail-closed at runtime; if a *compile* error, it
surfaces at step 12.8 anyway.

- [ ] **Step 12.8: Progress gate.** Same two-command idiom as Step 8.13. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t12-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t12-build.log || true
```

Expected: a number, strictly less than Step 10.16's count (exit status not judged).

- [ ] **Step 12.9: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingModels/VotingServiceConfig.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Decode pir_layout and thread it through the PIR entry points" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 13

### Task 13: A6 — static-config re-pin

*Code blocks by: Sonnet (app delegate).*

The URL below is verified two independent ways (`## VERIFICATION EVIDENCE`) — Android's actual
shipped diff (`gh pr diff 2406 --repo zodl-inc/zodl-android`) and an independent live
`curl` + `shasum -a 256` — and they agree byte-for-byte. No placeholder.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift:11-13`

**Interfaces:**
- Consumes: nothing (a literal only).
- Produces: `StaticVotingConfig.bundledPinnedSource: String`, unchanged type/usage — only the
  value changes.

---

- [ ] **Step 13.1: Replace the pinned fallback URL.** In `StaticVotingConfig.swift`, replace:

```swift
    static let bundledPinnedSource =
        "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/2785311d45758e85567d70a1f13709fa01b62c6b/prod/static-voting-config.json" +
        "?checksum=sha256:bed0116f961226b256a574b52461ce81d9f5294a57e190987dc155f07eb1e431"
```

with:

```swift
    static let bundledPinnedSource =
        "https://voting.valargroup.org/prod/static-voting-config.json" +
        "?checksum=sha256:c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d"
```

This moves the pin from a commit-pinned `raw.githubusercontent.com` snapshot to the live
checksummed URL, mirroring Android's `bugfix/MOB-1678` app PR (#2406) exactly — same host, same
path, same checksum. `PinnedConfigSource.parse(_:)` (`StaticVotingConfig.swift:143-185`, this
task does not touch it) already strips the `?checksum=sha256:...` query item and verifies the
remaining bytes against it (`StaticVotingConfig.decodeAndVerify(data:expectedSHA256:)`,
`:82-101`) — this string is consumed exactly the same way as the URL it replaces, so no other
code in this file changes.

- [ ] **Step 13.2: Re-verify the live content matches the pinned checksum, right before
committing.** Run:

```bash
curl -s -o /tmp/chp-t13-verify.json -w "HTTP_STATUS=%{http_code}\n" "https://voting.valargroup.org/prod/static-voting-config.json" && shasum -a 256 /tmp/chp-t13-verify.json
```

Expected: `HTTP_STATUS=200` and
`c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d /tmp/chp-t13-verify.json`. If
the hash has changed since this plan was written (Valar rotated the live config between
plan-writing and execution), **STOP**: do not commit a stale checksum — recompute both the hash
and the constructed URL, re-verify HTTP 200 on the newly-constructed URL, and use the fresh
value instead of the one in step 13.1's code block.

- [ ] **Step 13.3: Confirm the string builds and decodes.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n 'bundledPinnedSource' -A2 secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift
```

Expected: the two-line concatenation from step 13.1, verbatim. (A dedicated
`swift build`/`xcodebuild` gate is unnecessary for this task alone — it is a single string
literal with no signature change; it rides Task 14's full build instead.)

- [ ] **Step 13.4: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift && git commit -m "[MOB-1678] Re-pin the static voting config to the live checksummed URL" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## TASK 14

### Task 14: Zero errors + the app voting tests return (gate 5)

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` item 8 in full before starting — the "5 files return unmodified" premise
is false in **two** independent ways, and this task's step 14.2 is a headline correction, not a
routine verification.

**Files:**
- Modify: `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift:1025`
- Modify: `zodlTests/VotingTests/VotingServiceConfigTests.swift:931-948`

**Interfaces:**
- Consumes: the unified `VotingCryptoClient.getDelegationSubmission(roundId:bundleIndex:
  signature:sighash:)` (Task 8) and the re-shaped `SharePayload { wireJson: String, shareIndex:
  UInt32 }` (Task 9).
- Produces: nothing new — this task only restores the two test files to compiling against
  Tasks 8–13's real shapes.

---

- [ ] **Step 14.1: Fresh full build — assert the error list is now empty.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t14-build.log | tail -20; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, tail ends with `** BUILD SUCCEEDED **`. If any error remains, it is
either (a) one of the two explicit findings this plan carried forward and never resolved (the
software delegation-signing gap, `## CORRECTIONS` item 4 / Task 8 step 8.14; the hotkey-address
encoding gap, `## CORRECTIONS` item 6 / Task 10 step 10.15; the `tryRecoverInflightVote`
share-index gap, Task 9 step 9.13) — in which case this is the point those findings block gate 5
and must be resolved (not re-guessed) before continuing — or (b) a genuinely new error this plan
did not anticipate, which is its own finding: report the full log tail, do not patch around it
silently.

- [ ] **Step 14.2: Fix `VotingCoordFlowCoordinatorTests.swift` — the Keystone stub rename.**
In `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift`, replace:

```swift
        dependencies.votingCrypto.getDelegationSubmissionWithKeystoneSig = { _, bundleIndex, sig, sighash in
            recorder.record("registration:\(bundleIndex)")
            return Self.makeDelegationRegistration(
                rk: Data(repeating: UInt8(bundleIndex + 3), count: 32),
                spendAuthSig: sig,
                sighash: sighash
            )
        }
```

with:

```swift
        dependencies.votingCrypto.getDelegationSubmission = { _, bundleIndex, sig, sighash in
            recorder.record("registration:\(bundleIndex)")
            return Self.makeDelegationRegistration(
                rk: Data(repeating: UInt8(bundleIndex + 3), count: 32),
                spendAuthSig: sig,
                sighash: sighash
            )
        }
```

Positionally mechanical: the closure body is untouched, only the member name changes, matching
Task 8 step 8.4/8.9's unification exactly (both the old member and the new one take
`(_, bundleIndex, sig, sighash)` in the same order).

- [ ] **Step 14.3: Fix `VotingServiceConfigTests.swift` — the `SharePayload` construction
helper.** In `zodlTests/VotingTests/VotingServiceConfigTests.swift`, replace:

```swift
private func makeRecoverySharePayload(index: UInt32 = 0) -> SharePayload {
    let share = EncryptedShare(
        c1: Data(repeating: UInt8(index + 1), count: 32),
        c2: Data(repeating: UInt8(index + 2), count: 32),
        shareIndex: index
    )
    return SharePayload(
        sharesHash: Data(repeating: 0x01, count: 32),
        proposalId: 1,
        voteDecision: 0,
        encShare: share,
        treePosition: 10,
        allEncShares: [share],
        shareComms: [Data(repeating: 0x03, count: 32)],
        primaryBlind: Data(repeating: 0x04, count: 32),
        submitAt: 99
    )
}
#endif
```

with:

```swift
private func makeRecoverySharePayload(index: UInt32 = 0) -> SharePayload {
    SharePayload(
        wireJson: "{\"share_index\":\(index),\"submit_at\":99}",
        shareIndex: index
    )
}
#endif
```

The `wireJson` content is test fixture data, not something any assertion in this file inspects
(verified: `## CORRECTIONS` item 8 — every one of the 7 call sites checks only
`recorder.servers()`/`acceptedServers`/`result.delegatedShares`/`.remainingServerURLs`, never
the POST body); it only needs to be well-formed enough that `sharePostBody`'s
`JSONSerialization.jsonObject(with:)` (Task 9 step 9.7) does not throw when a test path happens
to exercise it. No other line in this file changes — `EncryptedShare` stays defined and used
elsewhere in the file for unrelated fixtures; do not remove it.

- [ ] **Step 14.4: Re-run the broader grep to confirm no third file needs a change.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "buildVoteCommitment\|signCastVote\|buildSharePayloads\|encryptShares\|decomposeWeight\|storeCommitmentBundle\|storeVoteCommitmentBundle\|getDelegationSubmissionWithKeystoneSig\|VotingSharePayload\|SharePayload(\|resubmitSharePayload\|delegateSharePayloads\|recordShareDelegation(.*nullifier\|\.markVoteSubmitted([^,]*,[^,]*,[^,)]*)\|seedPhrase\|StoredVotingHotkey(" zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift zodlTests/VotingTests/VotingSessionTests.swift zodlTests/VotingTests/VotingHelpersTests.swift zodlTests/VotingTests/VotingAPIResponseParserTests.swift zodlTests/VotingTests/VotingServiceConfigTests.swift
```

Expected, exactly: the two fixed-in-place occurrences from steps 14.2/14.3 (now using the new
names/shapes, so this pattern still matches their *presence* — read each hit and confirm it is
the corrected form, not a third stale usage). Any hit that is still the *old* member name or the
*old* 9-field `SharePayload` shape is a third file/site this task must also fix before
proceeding — do not defer it.

- [ ] **Step 14.5: Full internal-scheme test run.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:zodlTests/VotingTests 2>&1 | tee /tmp/chp-t14-votingtests.log | tail -20; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `** TEST SUCCEEDED **`. If `-only-testing:zodlTests/VotingTests` is
rejected (the scheme's test plan may not expose that path — verify the exact target/class path
with `xcodebuild test -scheme zodl-internal -showBuildTimingSummary -list` or by reading
`zodlTests.xctestplan` first), fall back to the full suite:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t14-fulltests.log | tail -30; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `** TEST SUCCEEDED **`. Either way, confirm the log shows the five
`VotingTests` classes actually ran (not skipped) —
`grep -c "Test Suite 'Voting" /tmp/chp-t14-*.log` should be ≥ 5.

- [ ] **Step 14.6: Commit the test fixes.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift zodlTests/VotingTests/VotingServiceConfigTests.swift && git commit -m "[MOB-1678] Port the two voting test files off the deleted Keystone member and the old SharePayload shape" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 14.7: First push.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git push origin chp-re-enable
```

Expected: the push succeeds (no force needed — this is the branch's first push in this
campaign, per `CHP_PLAN.md`'s workspace table: zodl pushes to `origin` at T14/T16). Report the
resulting commit range (`git log --oneline origin/chp-re-enable@{upstream}..HEAD` before the
push, or the pushed range from the `git push` output) so the orchestrator can cross-reference it
against `CHP_PLAN.md` Task 16's wrap-up log.

---

## TASK 14B

### Task 14B: the silent-false-green fix — flag into zodlTests + 3 real test issues

*Code blocks by: Sonnet (app delegate).*

Task 14's own gate ran green for the wrong reason: `zodlTests` never received `VOTING_ENABLED`
(Task 7's table enumerated only the three *app* targets — `zodlTests` is a fourth,
`TestTargetID`-linked target this plan never looked at), so every `#if VOTING_ENABLED`-gated
test file — all five under `zodlTests/VotingTests/`, both files Task 14 itself edited — compiled
to nothing, and "TEST SUCCEEDED" at Task 14's step 14.5 meant "zero voting tests ran," not "all
voting tests passed." This section closes that gap and the 6 real problems it was hiding.

**Files:**
- Modify: `secant.xcodeproj/project.pbxproj` (`zodlTests` target, Debug configuration only)
- Modify: `zodlTests/VotingTests/VotingServiceConfigTests.swift` (3 JSON fixture literals)
- Modify: `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift` (1 test's mock surface)

**Interfaces:**
- Consumes: nothing new — every symbol these three fixes touch already exists from Tasks
  8/8.14/9/9B/12.
- Produces: nothing new — this section makes existing, already-shipped code and tests agree.

---

- [ ] **Step 14B.1: Enumerate `zodlTests`'s build configurations and flip the one that runs.**
`zodlTests` (`PBXNativeTarget` `0D4E7A1526B364180058B01E`) has exactly three configurations,
via its own `XCConfigurationList` (`0D4E7A2D26B364180058B01E`):

| Config | UUID | Current `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | Used by any scheme's `TestAction`? |
|---|---|---|---|
| Debug | `0D4E7A2E26B364180058B01E` | `"DEBUG UNREDACTED"` | **Yes** — `zodl-internal.xcscheme`'s `<TestAction buildConfiguration = "Debug">` |
| Release-Testflight | `0D4E7A2F26B364180058B01E` | (none set) | No |
| Release-AppStore | `9E4AB2BD2BA1C05100F5D6DB` | (none set) | No |

Verify this against the tree before editing:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -A3 "<TestAction" secant.xcodeproj/xcshareddata/xcschemes/zodl-internal.xcscheme | head -4
sed -n '826,850p' secant.xcodeproj/project.pbxproj
```

Expected: `buildConfiguration = "Debug"` and the block shown in step 14B.1's edit below,
verbatim. **Only the Debug configuration needs the flag** — every Xcode scheme's `TestAction`
runs whichever single configuration its `buildConfiguration` attribute names (Debug, here,
for all three of this project's schemes — `zodl-internal`, `zodl-testnet`, and
`zodl-AppStore` alike default their `TestAction` to Debug), so `zodlTests`'s
Release-Testflight/Release-AppStore configurations are never invoked by a test run regardless
of this flag; leaving them untouched is correct, not an oversight.

**The testnet scheme's test action is explicitly out of scope, structurally, not just by
policy.** `zodl-testnet.xcscheme` also declares a `<TestAction buildConfiguration = "Debug">`,
but it does not reference `zodlTests` as a testable at all (`grep -c 'zodlTests'
zodl-testnet.xcscheme` → `0`) — and `zodlTests`'s own Debug configuration hardcodes
`TEST_HOST = "$(BUILT_PRODUCTS_DIR)/zodl-internal.app/zodl-internal"` (visible in the block
below), so this exact test bundle cannot be hosted by `zodl-testnet.app` even if a future
scheme edit tried to wire it in. `CHP_PLAN.md`'s own gate ladder only ever runs
`xcodebuild test` against `zodl-internal` (step 15.1) — `zodl-testnet`'s standing gate (step
15.2) is a plain `build`, never `test` — so there is no gate anywhere in this plan that this
finding needs to extend to.

In `secant.xcodeproj/project.pbxproj`, replace:

```
		0D4E7A2E26B364180058B01E /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = RLPRR8CPQG;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				INFOPLIST_FILE = zodlTests/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = co.electriccoin.zodlTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED";
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/zodl-internal.app/zodl-internal";
			};
			name = Debug;
		};
```

with:

```
		0D4E7A2E26B364180058B01E /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = RLPRR8CPQG;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				INFOPLIST_FILE = zodlTests/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = co.electriccoin.zodlTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/zodl-internal.app/zodl-internal";
			};
			name = Debug;
		};
```

Then verify uniqueness and the new total:

```bash
grep -c 'VOTING_ENABLED' secant.xcodeproj/project.pbxproj
```

Expected: `7` (Task 7's six app-target configs, plus this one). `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED";` (the exact pre-edit string, with no other flags) appeared exactly once in the file before this edit — confirmed uniquely locatable, not just line-number-adjacent.

- [ ] **Step 14B.2: Add the missing `pir_layout` to three JSON fixture literals.** Task 12
added a required `pir_layout` field to `VotingServiceConfig`; these three tests predate that
task and decode a JSON literal that no longer satisfies it
(`DecodingError.keyNotFound(pir_layout)`). All three assertions are about decode/validate
*mechanics*, not about `pirLayout`'s values, so any well-formed layout is correct test data —
matching the value `validateRejectsNonHexRoundId` (a fourth test in this same file, already
correct — it builds a `VotingServiceConfig` directly rather than via JSON, so it was never
broken) already uses: `.init(pirDepth: 1, tier0Layers: 1, tier1Layers: 1)`.

In `zodlTests/VotingTests/VotingServiceConfigTests.swift`, replace:

```swift
        let json = """
        {
          "config_version": 1,
          "vote_servers": [
            {"url": "https://vote1.example.com", "label": "validator-1"}
          ],
          "pir_endpoints": [
            {"url": "https://pir1.example.com", "label": "pir-1"}
          ],
          "supported_versions": {
            "pir": ["v0", "v1"],
            "vote_protocol": "v0",
            "tally": "v0",
            "vote_server": "v1"
          },
          "rounds": {}
        }
        """
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))

        #expect(config.configVersion == 1)
        #expect(config.voteServers.count == 1)
        #expect(config.pirEndpoints.first?.label == "pir-1")
        #expect(config.supportedVersions.voteServer == "v1")
        #expect(config.supportedVersions.pir == ["v0", "v1"])
    }
```

with:

```swift
        let json = """
        {
          "config_version": 1,
          "vote_servers": [
            {"url": "https://vote1.example.com", "label": "validator-1"}
          ],
          "pir_endpoints": [
            {"url": "https://pir1.example.com", "label": "pir-1"}
          ],
          "supported_versions": {
            "pir": ["v0", "v1"],
            "vote_protocol": "v0",
            "tally": "v0",
            "vote_server": "v1"
          },
          "rounds": {},
          "pir_layout": {"pir_depth": 1, "tier0_layers": 1, "tier1_layers": 1}
        }
        """
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))

        #expect(config.configVersion == 1)
        #expect(config.voteServers.count == 1)
        #expect(config.pirEndpoints.first?.label == "pir-1")
        #expect(config.supportedVersions.voteServer == "v1")
        #expect(config.supportedVersions.pir == ["v0", "v1"])
    }
```

Then, in the same file, replace:

```swift
        let json = """
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {}
        }
        """

        #expect(throws: Never.self) {
            try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))
        }
    }
```

with:

```swift
        let json = """
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {},
          "pir_layout": {"pir_depth": 1, "tier0_layers": 1, "tier1_layers": 1}
        }
        """

        #expect(throws: Never.self) {
            try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))
        }
    }
```

Then, still in the same file, replace:

```swift
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data("""
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {}
        }
        """.utf8))

        #expect(config.rounds.isEmpty)
        #expect(throws: Never.self) {
            try config.validate()
        }
    }
```

with:

```swift
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data("""
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {},
          "pir_layout": {"pir_depth": 1, "tier0_layers": 1, "tier1_layers": 1}
        }
        """.utf8))

        #expect(config.rounds.isEmpty)
        #expect(throws: Never.self) {
            try config.validate()
        }
    }
```

No assertion in any of the three tests changes — each still checks exactly what it checked
before; only the fixture JSON gained the field the type now requires to exist at all.

- [ ] **Step 14B.3: Port `delegationPipelineDoesNotSkipCachedTxWithoutConfirmedVanPosition` —
add the missing half of the mocked probe.**

**Faithfulness argument (read before applying the edit).** `git show
8ba799f1:zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift` (the tree immediately
before Task 8 landed) shows this test's original mock:
`votingCrypto.getDelegationSubmission = { _, _, _, _, _ in await recorder.record("registration");
return Self.makeDelegationRegistration() }` — five wildcarded parameters, matching the
*old* `getDelegationSubmission(roundId:bundleIndex:senderSeed:networkId:accountIndex:)`. Every
argument was already thrown away (`_`); the mock's only job was to unconditionally mark
`"registration"` and hand back a canned `DelegationRegistration` the instant the cached-submission
probe reached it. Task 8.14 split that one call into two
(`signDelegationRequest` → `getDelegationSubmission`), and the current file already re-typed the
`getDelegationSubmission` mock for the new 4-argument signature (still fully wildcarded, still
recording `"registration"` unconditionally) — but never added a mock for the new first half, so
the probe now throws `XCTFail`'s `@DependencyClient` "unimplemented" at
`signDelegationRequest` before it ever reaches the `getDelegationSubmission` mock this test's
assertion actually depends on. The test's own assertion (`#expect(events == ["fetch:cached-tx",
"registration", "submit", "store-tx:new-tx", "fetch:new-tx", "van:0:9"])`) has never once
depended on *how* the cached registration gets reconstructed — only on *whether* the pipeline,
having reconstructed one, still resubmits when `fetchTxConfirmation` reports the cached tx
unconfirmed. A `signDelegationRequest` mock that — like its neighbor — ignores its inputs and
unconditionally succeeds with canned bytes completes the probe's mock surface without adding or
removing any gate the test was never exercising; it changes zero recorded events and zero
assertions. This is a faithful port, not a semantic change: **port, not STOP.**

In `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift`, replace:

```swift
        votingCrypto.getDelegationSubmission = { _, _, _, _ in
            await recorder.record("registration")
            return Self.makeDelegationRegistration()
        }
```

with:

```swift
        votingCrypto.signDelegationRequest = { _, _, _, _, _, _, _ in
            (signature: Data(repeating: 0x09, count: 64), sighash: Data(repeating: 0x0A, count: 32))
        }
        votingCrypto.getDelegationSubmission = { _, _, _, _ in
            await recorder.record("registration")
            return Self.makeDelegationRegistration()
        }
```

No other line in this test changes — same setup, same `runDelegationPipeline` call, same
expected `events` array.

- [ ] **Step 14B.4: The real gate — full internal test run, flag actually compiled in.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t14b-test.log | tail -30; echo "TEST_EXIT=$?"
```

Expected: `TEST_EXIT=0`, `** TEST SUCCEEDED **`. Confirm the voting suites actually ran this
time (the exact failure mode this section exists to close):

```bash
grep -c "Test Suite '.*Voting.*'" /tmp/chp-t14b-test.log
grep -c "Test Suite '.*' started" /tmp/chp-t14b-test.log
```

Expected: the first command reports the voting suites present (11, per the coordinator's live
count — five files, but `@Suite struct` splits some files into more than one named suite);
the second reports a total near `1249` (the coordinator's live count with the flag on).
Confirm zero failures:

```bash
grep -c ' failed ' /tmp/chp-t14b-test.log
```

Expected: `0`, **with one named, tolerated exception**: if the log shows a failure inside
`CurrencyConversionSetupTests`, that is a pre-existing, unrelated issue this campaign does not
own (not a voting file, not touched by any task in this plan) — confirm it is exactly that
suite and no other before treating the count as acceptable; any voting-suite failure is this
section's own regression and must be fixed here, not waved through.

- [ ] **Step 14B.5: Commit and push.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant.xcodeproj/project.pbxproj zodlTests/VotingTests/VotingServiceConfigTests.swift zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift && git commit -m "[MOB-1678] Enable VOTING_ENABLED for zodlTests so the voting suites actually run, and fix the 3 real issues that surfaces" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git push origin chp-re-enable
```

This is still within gate 5's sanction (`CHP_PLAN.md` Task 14's own scope: "zero errors + tests
+ first push") — the first push already happened at step 14.7; this is an amending push on the
same branch, not a second "first" push.

---

---
