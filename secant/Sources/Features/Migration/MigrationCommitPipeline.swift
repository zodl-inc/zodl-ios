//
//  MigrationCommitPipeline.swift
//  zodl
//
//  Shared commit-lane helpers for the migration flow's "confirm" step (MOB-1496 remediation R8-T1,
//  finding #19): `MigrationTransferPlanStore` (scheduled/manual/recreated plans) and
//  `MigrationReviewTransferStore` (the immediate single-sweep transfer) each drove an independent,
//  byte-identical ~35-line software commit sequence and ~12-line Keystone PCZT-proposal fork —
//  extracted here.
//
//  Both entry points below THROW rather than swallow (finding #4): callers map ANY thrown error to
//  their existing commit-failure surface (`.noteSplitFailed` / `isFailurePresented`).
//
//  MOB-1513 (Lane A2 — send-max immediate migration): the OLD `.immediate` lane above signed+stored
//  an engine-held, single-transfer `MigrationSchedule` here and broadcast it LATER via
//  `MigrationSendingStore`'s `performMigrationBroadcast` (the schedule/dust lanes' own
//  delivery mechanism) — `commitSoftware`'s old `MigrationCommitMode.immediate` branch and
//  `MigrationCommitMode` itself are DELETED along with it (the immediate lane is the ONLY caller
//  that ever passed `.immediate`, and `commitSoftware` is `.scheduled`-only now, so the parameter
//  was pure dead weight). The immediate lane's `ImmediateMigrationProposal` (`Synchronizer
//  .proposeImmediateMigration(accountUUID:)`) is an ORDINARY, engine-external proposal instead — no
//  plan-cache staleness, no engine-held schedule to sign+store ahead of time. Two new entry points
//  cover it end to end, mirroring `commitSoftware`/`proposeKeystoneBatch`'s software/Keystone split:
//  - `commitImmediateSoftware`: the actual create+sign+submit (`createAndSubmitProposedTransactions`,
//    already transaction-guarded in `SDKSynchronizerLive`) — called from `MigrationSendingStore
//    .executeNextTransfer`'s immediate-lane branch (the Sending screen's `onAppear` is genuinely
//    where the FIRST and ONLY broadcast attempt happens now, same as every other lane; Review's own
//    confirm has nothing left to pre-commit for the software path).
//  - `commitImmediateKeystone`: the post-signing add-proofs + submit
//    (`createAndSubmitTransactionFromPCZT`) — called from `MigrationCoordFlowCoordinator`'s
//    dedicated immediate-Keystone post-scan step, since a Keystone PCZT can only be finalized once,
//    right after the QR round-trip returns a signature — there is no engine-side "store now,
//    broadcast whenever the Sending screen next appears" indirection available for a proposal that
//    was never stored in the engine to begin with.
//  Both throw on a non-`.success` submit outcome (`MigrationCommitError.immediateSubmitNotSuccessful`)
//  WITHOUT calling `recordImmediateMigration` — never record a sweep that never broadcast. Both treat
//  a `recordImmediateMigration` failure AFTER a successful submit as non-fatal (mirrors the
//  landed-but-unrecorded philosophy above): the broadcast already landed, so a bookkeeping-only
//  failure must never be reported as a submit failure.
//
//  MOB-1513 (B4 — confirm redesign): `commitSoftware` no longer broadcasts ANYTHING. The old chain
//  ran the monolithic `submitNoteSplit` inline (signing + first-prep proving — a one-time,
//  multi-second Orchard proving-key build — + an inline Tor bootstrap + the broadcast, all
//  serialized on the process-wide DB actor, which is exactly the multi-second confirm freeze QA
//  hit), plus `stopSyncBeforeMigrationBroadcast` and the whole broadcast failure-routing block
//  (`MigrationCommitError.splitFailedRouted`, R14-R17 surfaces on the plan screen — all deleted
//  with it). The chain is now sign-only, matching the design's "everything signed at once, splits
//  execute immediately, transfers per offsets": `signAndStoreMigrationSchedule` (the atomic
//  commit: signs EVERYTHING of the run — every transfer AND any note-split preparation layers it
//  needs — straight from the plan cache `schedule`'s own propose call already wrote, with NO
//  proving and NO broadcast) -> `recordCommittedSchedule` -> `reconcile`. The first prep's actual
//  broadcast (prove-at-broadcast, Tor, privacy buffer) happens via the DRIVER lane
//  (`MigrationManagerClient.advance`), never inline in this pipeline. Field 2026-08-06: for the
//  software SCHEDULED-PLAN commit — this function, called from `MigrationTransferPlanStore` — that
//  drive now runs UNDER the Confirm loader: `MigrationTransferPlan`'s `.scheduleCommitted` awaits
//  `advance(.afterSync)` at tip (mid-sync it defers to the coming sync edge instead), BEFORE
//  navigation. Root's G1 `.confirmed` case still fires afterward too, now only as an idempotent
//  backstop for that lane — and remains the ONLY drive for the `reviewTransfer` lane
//  (`MigrationReviewTransferStore`'s immediate-sweep commit, which never calls this function and
//  gained no loader-side drive of its own). NEVER add a `submitNoteSplit` OR a
//  `prepareNoteSplit` call ahead of `signAndStoreMigrationSchedule` here (MOB-1513 F1-A1): the SDK
//  holds ONE proposal-handle slot per account (`MigrationSchedule.proposalHandle`'s doc), and ANY
//  propose/prepare call for that account — `prepareNoteSplit` included — supersedes whatever
//  handle is cached there, including `schedule`'s own. A `prepareNoteSplit` call sandwiched
//  between the propose that minted `schedule` and this commit would invalidate `schedule` before
//  it is ever signed, so every commit needing a split would throw `migrationPlanStale`
//  unconditionally — a bug this file used to have. NEVER add a `submitNoteSplit` call after
//  `signAndStoreMigrationSchedule` either: the successful commit clears the plan cache, so
//  `sign_note_split`'s echo-validation would throw plan-stale.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Failures `MigrationCommitPipeline`'s own logic raises, distinct from whatever the underlying SDK
/// calls throw — callers that don't care about the payload can still map ANY of these to the same
/// commit-failure surface, exactly as before.
enum MigrationCommitError: Error, Equatable {
    /// The proposed Keystone PCZT batch came back empty — nothing to hand to the signing device.
    case emptyPcztBatch
    /// MOB-1513: an immediate-lane submit (`createAndSubmitProposedTransactions`/
    /// `createAndSubmitTransactionFromPCZT`) came back as anything other than `.success` — no txid to
    /// record, no partial state to clean up (nothing was stored anywhere by this pipeline).
    case immediateSubmitNotSuccessful
}

/// PHASE 7: one Keystone signing ceremony's full, ordered PCZT batch plus the count that tells its
/// two halves apart.
///
/// The engine numbers every preparation (note-split) transaction before the transfers, and
/// `proposeKeystoneBatch` builds the array in exactly that order, so `pczts[..<preparationCount]`
/// are the preps and `pczts[preparationCount...]` are the schedule's transfers. Because
/// `applyKeystoneBatchSignatures` echoes the batch back positionally, the SAME split applies to the
/// signed result — see `MigrationCoordFlow.splitKeystoneBatch`.
struct MigrationKeystoneBatch: Equatable {
    /// Preparation PCZTs first, then the schedule's own transfers — the order both the QR build and
    /// the two store calls expect.
    let pczts: [MigrationUnsignedTransferPczt]
    /// How many leading entries of `pczts` are preparation (note-split) transactions. `0` when the
    /// run needs no preparation layer.
    let preparationCount: Int
    /// `pczts` split into device-sized signing sessions by ACTION budget, computed by the SDK's
    /// exact packer (`batchMigrationPcztsForSigning`) at propose time. Order-preserving, so
    /// concatenating the rounds reproduces `pczts` exactly and `preparationCount` still indexes it.
    ///
    /// Batching by actions rather than by transaction count is the correctness fix: a preparation
    /// weighs 16 Orchard actions and a transfer 3, against a Keystone budget of 96. The old
    /// count-based cap of 32 items was derived offline as "96 ÷ ~3" and is right ONLY for a
    /// pure-transfer batch — a batch containing preparations could reach 32 × 16 = 512 actions in
    /// one round, five rounds' worth of work the device would refuse.
    let rounds: [[MigrationUnsignedTransferPczt]]
}

/// Shared commit-lane pipelines for the migration flow's software- and Keystone-signing paths (see
/// this file's header for the extraction rationale).
enum MigrationCommitPipeline {
    /// Signs and persists `schedule` in the migration engine, software-signing path — the SIGN-ONLY
    /// commit (MOB-1513 B4; see this file's header for what used to run here and why it left):
    /// derive the account's USK, then `signAndStoreMigrationSchedule` directly (the atomic commit:
    /// signs every transaction of the run — `schedule`'s transfers AND any note-split preparation
    /// layers the engine still needs — straight from the plan cache `schedule`'s own propose call
    /// wrote, with NO proving and NO broadcast) -> `recordCommittedSchedule` -> `reconcile`.
    /// Deliberately no separate `isNoteSplitNeeded`/`prepareNoteSplit` step here (MOB-1513 F1-A1
    /// fix): the SDK's one proposal-handle slot per account means a `prepareNoteSplit` call at
    /// this point would supersede `schedule`'s own handle before it is signed, turning every
    /// commit that needs a split into a guaranteed `migrationPlanStale` throw — see this file's
    /// header.
    ///
    /// A thrown commit persists NOTHING (the engine's commit is persist-once-atomic, and neither
    /// `recordCommittedSchedule` nor `reconcile` has run) — callers map the throw to their existing
    /// commit-failure surface and a Retry re-runs this whole chain.
    ///
    /// This is the STAGGERED-SCHEDULE lane only (`MigrationTransferPlanStore`'s
    /// `scheduled`/`manual`/`recreated` variants — all three sign a multi-transfer schedule the same
    /// way). The immediate single-sweep lane no longer calls this at all — see
    /// `commitImmediateSoftware`/`commitImmediateKeystone` below.
    static func commitSoftware(
        schedule: MigrationSchedule,
        account: WalletAccount,
        zip32AccountIndex: Zip32AccountIndex,
        sdkSynchronizer: SDKSynchronizerClient,
        migrationManager: MigrationManagerClient,
        walletStorage: WalletStorageClient,
        mnemonic: MnemonicClient,
        derivationTool: DerivationToolClient,
        networkType: NetworkType
    ) async throws {
        // E2E harness F#3b (2026-08-04): the commit is THE money moment of the whole flow, and it
        // used to run silent end to end — a refusal anywhere in this chain was indistinguishable
        // from a tap that never landed. Stage-tagged so a throw names where it died.
        MigrationTrace.event("COMMIT begin — software sign+store, \(schedule.transfers.count) transfers")
        var stage = "deriveUSK"
        do {
            let usk = try await MigrationSpendingKeyDerivation.deriveUSK(
                zip32AccountIndex: zip32AccountIndex,
                walletStorage: walletStorage,
                mnemonic: mnemonic,
                derivationTool: derivationTool,
                networkType: networkType
            )
            stage = "signAndStoreMigrationSchedule"
            try await sdkSynchronizer.signAndStoreMigrationSchedule(account.id, schedule, usk)
            MigrationTrace.event("COMMIT signed + stored — recording schedule, then reconcile")

            // [MOB-1496] W2: persist the just-committed schedule (the SDK keeps no proposal list
            // post-commit) and reconcile so `stateEvents` picks up the fresh state promptly (a store
            // completing a migration op is one of `reconcile()`'s two triggers).
            await migrationManager.recordCommittedSchedule(account.id, schedule)
            await migrationManager.reconcile()
            MigrationTrace.event("COMMIT done — recorded + reconciled")
        } catch {
            MigrationTrace.event("COMMIT THREW at \(stage): \(error)")
            throw error
        }
    }

    // MARK: - MOB-1513: immediate lane (send-max `ImmediateMigrationProposal`)

    /// The immediate lane's software (USK-signing) submit: derives no new state ahead of time — the
    /// proposal is already in hand, so this IS the whole commit. `createAndSubmitProposedTransactions`
    /// signs and broadcasts in one call (already transaction-guarded in `SDKSynchronizerLive`, so this
    /// never wraps its own guard). On a genuine `.success`, collects the (single, by construction —
    /// a send-max proposal always produces exactly one transaction) txid and calls
    /// `recordImmediateMigration` before returning it — a `recordImmediateMigration` failure AFTER a
    /// successful submit is bookkeeping-only and never turns a landed broadcast into a reported
    /// failure (mirrors the landed-but-unrecorded philosophy in this file's header). On any other
    /// submit outcome, throws `MigrationCommitError.immediateSubmitNotSuccessful` WITHOUT recording
    /// anything — callers map this like any other thrown error to their existing failure surface.
    ///
    /// - Returns: the broadcast transaction's id, in the SDK's display-hex form (`TxId`/
    ///   `toHexStringTxId()` convention) — the same shape `MigrationTransferResult.success(txId:)`
    ///   and `MigrationSending.State.txId` already use everywhere else in this flow.
    static func commitImmediateSoftware(
        proposal: ImmediateMigrationProposal,
        usk: UnifiedSpendingKey,
        accountUUID: AccountUUID,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> String {
        // E2E harness (2026-08-04): the field sweep of the wedged wallet ran this whole lane with
        // ZERO [MIG] lines — same silent-money-moment class the schedule lane's commit had. Traced
        // to the same standard: begin, outcome, throw.
        MigrationTrace.event("COMMIT begin — immediate software sweep")
        do {
            let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal.proposal, usk)
            guard case let .success(txIds) = result, let displayTxId = txIds.first else {
                MigrationTrace.event("COMMIT immediate submit NOT successful — \(String(describing: result))")
                throw MigrationCommitError.immediateSubmitNotSuccessful
            }
            MigrationTrace.event("COMMIT immediate broadcast landed — txid \(displayTxId)")
            await recordImmediateMigrationBestEffort(accountUUID: accountUUID, displayTxId: displayTxId, sdkSynchronizer: sdkSynchronizer)
            return displayTxId
        } catch {
            MigrationTrace.event("COMMIT immediate THREW: \(error)")
            throw error
        }
    }

    /// The immediate lane's Keystone post-signing submit — called once the QR round-trip returns a
    /// signature for the single PCZT `MigrationReviewTransferStore`'s Keystone fork proposed via
    /// `createPCZTFromProposal(accountUUID:proposal:)`. That is an ORDINARY, unproven PCZT — unlike
    /// the engine's own migration PCZTs, which arrive proven-but-unsigned already — so it still needs
    /// `addProofsToPCZT` before it can be combined with the externally-obtained signature.
    ///
    /// Unlike the software lane, this cannot defer to the Sending screen's `onAppear`: a Keystone
    /// PCZT can only be finalized ONCE, right here, immediately after the signature comes back —
    /// there is no engine-held "signed and stored, broadcast whenever" state for a proposal the
    /// engine never held in the first place. `createAndSubmitTransactionFromPCZT` is already
    /// transaction-guarded in `SDKSynchronizerLive`. Same throw/record semantics as
    /// `commitImmediateSoftware`.
    static func commitImmediateKeystone(
        unsignedPczt: Data,
        signedPczt: Data,
        accountUUID: AccountUUID,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> String {
        // E2E harness (2026-08-04): same trace standard as `commitImmediateSoftware` — see there.
        MigrationTrace.event("COMMIT begin — immediate Keystone finalize+submit")
        do {
            let provenPczt = try await sdkSynchronizer.addProofsToPCZT(unsignedPczt)
            let result = try await sdkSynchronizer.createAndSubmitTransactionFromPCZT(provenPczt, signedPczt)
            guard case let .success(txIds) = result, let displayTxId = txIds.first else {
                MigrationTrace.event("COMMIT immediate submit NOT successful — \(String(describing: result))")
                throw MigrationCommitError.immediateSubmitNotSuccessful
            }
            MigrationTrace.event("COMMIT immediate broadcast landed — txid \(displayTxId)")
            await recordImmediateMigrationBestEffort(accountUUID: accountUUID, displayTxId: displayTxId, sdkSynchronizer: sdkSynchronizer)
            return displayTxId
        } catch {
            MigrationTrace.event("COMMIT immediate THREW: \(error)")
            throw error
        }
    }

    /// Proposes the Keystone-signing PCZT batch for `schedule`, external-signer path: proposes the
    /// engine's preparation (note-split) PCZTs first — the engine builds N preparation transactions,
    /// not one split transaction, and returns the (possibly empty) prep subset from that same call —
    /// then appends the schedule's own transfer PCZTs behind them.
    ///
    /// ⚠️ `proposeNoteSplitPCZTs` is the RUN-CREATING call — see its doc on `SDKSynchronizerClient`.
    /// Every abandon path downstream of this function must cancel the run it just created.
    ///
    /// **Prep/transfer discrimination is POSITIONAL, and that is a deliberate simplification over
    /// #1930.** There, `MigrationUnsignedTransferPczt.id` was a `String` and preps rode the batch
    /// under a `"note-split#"` sentinel prefix so they could be told apart after the round trip —
    /// which then had to be stripped before `applyKeystoneBatchSignatures` (whose FFI numeric-parsed
    /// every id) and re-attached afterwards, three helpers in all. In this SDK `id` is a `UInt32`
    /// engine id, `applyKeystoneBatchSignatures` echoes ids back POSITIONALLY, and the engine numbers
    /// every preparation transaction before the transfers. So the prep COUNT alone is a complete and
    /// exact discriminator, it travels with the batch in `MigrationKeystoneBatch`, and no id is ever
    /// rewritten. Do not reintroduce a sentinel: it would break the store calls, which look
    /// transactions up by the id the engine issued.
    ///
    /// Every SDK member here throws through (no `try?` swallowing), and an empty resulting batch is
    /// ALSO a failure — this never hands the coordinator a silently empty or partial batch that would
    /// stage a dead-end signing session.
    ///
    /// - Throws: `MigrationCommitError.emptyPcztBatch` when the proposed batch has nothing in it;
    ///   otherwise whatever the underlying SDK calls throw. Callers map ANY throw to their existing
    ///   commit-failure surface (Retry re-runs this same propose).
    static func proposeKeystoneBatch(
        schedule: MigrationSchedule,
        account: WalletAccount,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> MigrationKeystoneBatch {
        let preps = try await sdkSynchronizer.proposeNoteSplitPCZTs(account.id, schedule)
        let transfers = try await sdkSynchronizer.proposeMigrationPCZTs(account.id, schedule)

        let pczts = preps + transfers
        guard !pczts.isEmpty else {
            throw MigrationCommitError.emptyPcztBatch
        }

        // Batch BEFORE signing, never after: rows returned by `applyKeystoneBatchSignatures` carry
        // `actions == 0` (reconstructed from retained bytes, no engine context) and the packer
        // throws on them rather than mis-packing a session.
        let rounds = try await sdkSynchronizer.batchMigrationPcztsForSigning(pczts, MigrationSigningBudget.keystone)

        return MigrationKeystoneBatch(pczts: pczts, preparationCount: preps.count, rounds: rounds)
    }

    /// Used by the immediate submit path above (and by the Keystone one): the broadcast already landed by the time this
    /// runs (a `displayTxId` in hand), so a `recordImmediateMigration` failure here is bookkeeping
    /// only — logged, never thrown, never turning an already-successful broadcast into a reported
    /// failure (same "landed but unrecorded is still success" precedent this file's header
    /// describes).
    private static func recordImmediateMigrationBestEffort(
        accountUUID: AccountUUID,
        displayTxId: String,
        sdkSynchronizer: SDKSynchronizerClient
    ) async {
        do {
            try await sdkSynchronizer.recordImmediateMigration(accountUUID, rawTxId(fromDisplayHex: displayTxId))
        } catch {
            LoggerProxy.error("[MOB-1513] recordImmediateMigration failed after a successful broadcast (txid \(displayTxId)): \(error)")
        }
    }

    /// Inverts `Data.toHexStringTxId()` (SDK, `Extensions/Data+Zcash.swift`): that display
    /// convention reverses the txid's bytes and THEN hex-encodes them, so recovering the raw/
    /// internal-order `Data` `recordImmediateMigration(accountUUID:txid:)` requires (matching
    /// `TxId.id`) means hex-decoding first and reversing the decoded bytes back — hex-decoding alone
    /// would silently hand the SDK a byte-reversed txid. See `Synchronizer.recordImmediateMigration`'s
    /// own doc for the identical warning from the SDK side. `Data(hexString:)` is the app-wide hex
    /// decoder already used by `VotingCryptoClientLiveKey.swift`.
    private static func rawTxId(fromDisplayHex hex: String) -> Data {
        Data(decodeHex(hex).reversed())
    }

    /// #1930 called the app-wide `Data(hexString:)` here. That extension lives in
    /// `VotingCryptoClientLiveKey.swift`, which is compiled ONLY under `#if VOTING_ENABLED` — so on
    /// an ordinary wallet build it does not exist. Same implementation, byte for byte, kept as a
    /// private static func rather than another `extension Data` so it cannot collide with the voting
    /// one when that flavor IS built.
    private static func decodeHex(_ hexString: String) -> Data {
        var data = Data()
        var hex = hexString
        while hex.count >= 2 {
            let byteString = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
        }
        return data
    }
}
