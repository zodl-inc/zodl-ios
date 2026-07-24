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
//  `MigrationSendingStore`'s `executeNextPendingMigrationTransfer` (the schedule/dust lanes' own
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
//  execute immediately, transfers per offsets": `prepareNoteSplit` (propose-side caching, kept —
//  `sign_and_store`'s echo-validation reads the plan cache it writes) ->
//  `signAndStoreMigrationSchedule` (the atomic commit: signs EVERYTHING including the preps, no
//  proving, no broadcast) -> `recordCommittedSchedule` -> `reconcile`. The first prep's actual
//  broadcast (prove-at-broadcast, Tor, privacy buffer) happens AFTER navigation, via
//  `MigrationCoordFlowCoordinator`'s post-confirm first-delivery kick over the existing next-due
//  lane — see `runFirstDeliveryKick`'s doc there. NEVER add a `submitNoteSplit` call after
//  `signAndStoreMigrationSchedule`: the successful commit clears the plan cache, so
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

/// Shared commit-lane pipelines for the migration flow's software- and Keystone-signing paths (see
/// this file's header for the extraction rationale).
enum MigrationCommitPipeline {
    /// Signs and persists `schedule` in the migration engine, software-signing path — the SIGN-ONLY
    /// commit (MOB-1513 B4; see this file's header for what used to run here and why it left):
    /// derive the account's USK, then — iff the engine still needs a note split —
    /// `prepareNoteSplit` (propose-side caching only; its returned proposal is deliberately
    /// discarded, since `sign_and_store_migration_schedule` echo-validates the split against the
    /// plan cache that call just wrote), then `signAndStoreMigrationSchedule` (the atomic commit:
    /// signs every transaction of the run, preps included, with NO proving and NO broadcast) ->
    /// `recordCommittedSchedule` -> `reconcile`.
    ///
    /// A thrown commit persists NOTHING (the engine's commit is persist-once-atomic, and neither
    /// `recordCommittedSchedule` nor `reconcile` has run) — callers map the throw to their existing
    /// commit-failure surface and a Retry re-runs this whole chain (whose `prepareNoteSplit` is
    /// itself a fresh propose-side cache write).
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
        let needsNoteSplit = try await sdkSynchronizer.isNoteSplitNeeded(account.id)
        let usk = try MigrationSpendingKeyDerivation.deriveUSK(
            zip32AccountIndex: zip32AccountIndex,
            walletStorage: walletStorage,
            mnemonic: mnemonic,
            derivationTool: derivationTool,
            networkType: networkType
        )
        if needsNoteSplit {
            _ = try await sdkSynchronizer.prepareNoteSplit(account.id)
        }
        try await sdkSynchronizer.signAndStoreMigrationSchedule(account.id, schedule, usk)

        // [MOB-1496] W2: persist the just-committed schedule (the SDK keeps no proposal list
        // post-commit) and reconcile so `stateEvents` picks up the fresh state promptly (a store
        // completing a migration op is one of `reconcile()`'s two triggers).
        await migrationManager.recordCommittedSchedule(account.id, schedule)
        await migrationManager.reconcile()
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
        let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal.proposal, usk)
        guard case let .success(txIds) = result, let displayTxId = txIds.first else {
            throw MigrationCommitError.immediateSubmitNotSuccessful
        }
        await recordImmediateMigrationBestEffort(accountUUID: accountUUID, displayTxId: displayTxId, sdkSynchronizer: sdkSynchronizer)
        return displayTxId
    }

    /// The immediate lane's Keystone post-signing submit — called once the QR round-trip returns a
    /// signature for the single PCZT `MigrationReviewTransferStore`'s Keystone fork proposed via
    /// `createPCZTFromProposal(accountUUID:proposal:)` (an ORDINARY, unproven PCZT — unlike the
    /// engine's own migration PCZTs, which arrive proven-but-unsigned already; this one still needs
    /// `addProofsToPCZT` before it can be combined with the externally-obtained signature). Unlike
    /// the software lane, this can't defer to the Sending screen's `onAppear`: a Keystone PCZT can
    /// only be finalized once, right here, immediately after the signature comes back — there is no
    /// engine-held "signed and stored, broadcast whenever" state for a proposal the engine never
    /// held in the first place. `createAndSubmitTransactionFromPCZT` is already transaction-guarded
    /// in `SDKSynchronizerLive`. Same throw/record semantics as `commitImmediateSoftware`.
    static func commitImmediateKeystone(
        unsignedPczt: Data,
        signedPczt: Data,
        accountUUID: AccountUUID,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> String {
        let provenPczt = try await sdkSynchronizer.addProofsToPCZT(unsignedPczt)
        let result = try await sdkSynchronizer.createAndSubmitTransactionFromPCZT(provenPczt, signedPczt)
        guard case let .success(txIds) = result, let displayTxId = txIds.first else {
            throw MigrationCommitError.immediateSubmitNotSuccessful
        }
        await recordImmediateMigrationBestEffort(accountUUID: accountUUID, displayTxId: displayTxId, sdkSynchronizer: sdkSynchronizer)
        return displayTxId
    }

    /// Shared by both immediate submit paths above: the broadcast already landed by the time this
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
        Data(Data(hexString: hex).reversed())
    }

    /// Proposes the Keystone-signing PCZT batch for `schedule`, external-signer path: unconditionally
    /// proposes the engine's preparation (note-split) PCZTs first — the final engine builds N
    /// preparation transactions, not one split transaction, and returns the (possibly empty) prep
    /// subset from that same call — then prepends any of them, each wrapped under the coordinator's
    /// `keystoneNoteSplitSentinelPrefix` + its own engine id (`MigrationCoordFlowCoordinator`'s
    /// `.scan(.foundKeystoneBatchSignatures)` handler splits them back out and strips the
    /// prefix before storing — see `MigrationCoordFlow.keystoneNoteSplitSentinelPrefix`'s doc), ahead
    /// of the schedule's own PCZTs.
    ///
    /// MOB-1513: `MigrationTransferPlanStore`'s Keystone fork (the staggered-schedule lane,
    /// `KeystoneSigningContext.planCommit`) is the ONLY caller now — `MigrationReviewTransferStore`'s
    /// immediate-mode Keystone fork proposes its single `ImmediateMigrationProposal`'s PCZT directly
    /// via `createPCZTFromProposal(accountUUID:proposal:)` instead (an ordinary, engine-external
    /// proposal has no engine-held schedule for this function's `proposeNoteSplitPCZTs`/
    /// `proposeMigrationPCZTs` machinery to build a batch from) — see
    /// `MigrationCoordFlowCoordinator.submitImmediateKeystoneTransaction`'s doc for that lane's own
    /// post-signing step.
    ///
    /// Finding #4: every SDK member here throws through (no `try?` swallowing), and an empty
    /// resulting batch is ALSO treated as a failure — this never hands the coordinator a silently
    /// empty or partial batch that would stage a dead-end Keystone signing session.
    ///
    /// - Throws: `MigrationCommitError.emptyPcztBatch` when the proposed batch has nothing in it;
    ///   otherwise propagates whatever the underlying SDK calls throw (including a failed prep
    ///   propose — a new throw site under the unconditional fold). Callers map ANY throw here to
    ///   their existing commit-failure surface (Retry re-runs this same propose).
    static func proposeKeystoneBatch(
        schedule: MigrationSchedule,
        account: WalletAccount,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> [MigrationUnsignedTransferPczt] {
        var pczts: [MigrationUnsignedTransferPczt] = []

        let preps = try await sdkSynchronizer.proposeNoteSplitPCZTs(account.id)
        pczts.append(
            contentsOf: preps.map {
                MigrationUnsignedTransferPczt(id: MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + $0.id, pczt: $0.pczt)
            }
        )

        let schedulePczts = try await sdkSynchronizer.proposeMigrationPCZTs(account.id, schedule)
        pczts.append(contentsOf: schedulePczts)

        guard !pczts.isEmpty else {
            throw MigrationCommitError.emptyPcztBatch
        }

        return pczts
    }
}
