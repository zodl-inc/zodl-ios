//
//  MigrationCommitPipeline.swift
//  zodl
//
//  Shared commit-lane helpers for the migration flow's "confirm" step (MOB-1496 remediation R8-T1,
//  finding #19): `MigrationTransferPlanStore` (scheduled/manual/recreated plans) and
//  `MigrationReviewTransferStore` (the immediate single-sweep transfer) each drove an independent,
//  byte-identical ~35-line software commit sequence and ~12-line Keystone PCZT-proposal fork —
//  extracted here, parameterized by an EXPLICIT `MigrationCommitMode` so the two lanes' real
//  divergence (finding S1: the immediate lane is split-free by engine design; see
//  `zcash_pool_migration::MigrationContext::propose_immediate_migration_transfers`'s doc, "sweeping
//  the whole balance in a single transaction right away, skipping the split entirely") is expressed
//  structurally — a `switch`/`if` over `mode`, not a boolean the two call sites could drift back
//  apart on the way the pre-extraction duplication already had (a prior fix sweep missed one twin
//  once).
//
//  Both entry points below THROW rather than swallow (finding #4): callers map ANY thrown error to
//  their existing commit-failure surface (`.noteSplitFailed` / `isFailurePresented`), with one
//  narrow, deliberate exception inside `commitSoftware`'s `.scheduled` branch — see its doc
//  (finding #1).
//
//  MOB-1496 (final engine, plural preps): S1's ENGINE claim ("immediate runs never split") is
//  obsolete — the final engine's immediate flag only rewrites transfer heights, so an immediate run
//  CAN carry preparation transactions for a large enough balance. What survives of S1 is purely
//  structural, and only for the SOFTWARE sequence: `commitSoftware`'s `.immediate` branch still has
//  no split-specific call to make, because `signAndStoreMigrationSchedule` signs EVERY transaction
//  of the committed run — preps included — and any preps then broadcast through the ordinary
//  delivery lane (`executeNextPendingMigrationTransfer` serves preps and transfers alike). The
//  Keystone PCZT-proposal fork lost even that: `proposeKeystoneBatch` dropped its `mode` parameter
//  entirely and now unconditionally folds the engine's preparation (note-split) PCZTs into every
//  batch it proposes, immediate mode included — see that function's own doc.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Which commit lane is running: the staggered schedule (`MigrationTransferPlanStore`, always
/// `.scheduled` regardless of its own `scheduled`/`manual`/`recreated` variant — all three sign a
/// multi-transfer schedule the same way) or the single immediate sweep
/// (`MigrationReviewTransferStore`'s `.immediate` mode; its `.manualStep` mode never reaches these
/// helpers — that transfer was already signed at plan commit). MOB-1496 (final engine): only
/// `commitSoftware` (the software-signing lane) still branches on this — `proposeKeystoneBatch` (the
/// Keystone PCZT-proposal lane) dropped its `mode` parameter, since its old immediate-mode special
/// case is obsolete; see that function's doc.
enum MigrationCommitMode: Equatable {
    /// The staggered schedule: may need a silent note split first (see `commitSoftware`).
    case scheduled
    /// The immediate sweep, SOFTWARE-signing lane only: `commitSoftware` makes no split-specific
    /// calls for this mode — NOT because an immediate run cannot contain preparation transactions
    /// (under the final engine it can, for a large enough balance), but because
    /// `signAndStoreMigrationSchedule` signs every transaction of the committed run — preps
    /// included — and any preps ride the ordinary delivery lane from there. Does NOT describe the
    /// Keystone lane — `proposeKeystoneBatch` folds preps unconditionally, mode-independent.
    case immediate
}

/// Failures `MigrationCommitPipeline`'s own logic raises, distinct from whatever the underlying SDK
/// calls throw — callers don't need to distinguish these from any other thrown error; both map to
/// the same commit-failure surface.
enum MigrationCommitError: Error, Equatable {
    /// `.scheduled` mode's silent split genuinely did not succeed (a non-`.success` broadcast
    /// result that is also not the landed-but-unrecorded case `commitSoftware` treats as success —
    /// see its doc).
    case splitNotSuccessful
    /// The proposed Keystone PCZT batch came back empty — nothing to hand to the signing device.
    case emptyPcztBatch
}

/// Shared commit-lane pipelines for the migration flow's software- and Keystone-signing paths (see
/// this file's header for the extraction rationale).
enum MigrationCommitPipeline {
    /// Signs and persists `schedule` in the migration engine, software-signing path: derive the
    /// account's USK, then — `.scheduled` mode only — silently split first when the engine still
    /// needs one (mirrors the pre-extraction inline sequence exactly), then
    /// `signAndStoreMigrationSchedule` -> `recordCommittedSchedule` -> `reconcile`.
    ///
    /// `.immediate` mode never consults `isNoteSplitNeeded` / calls `prepareNoteSplit` /
    /// `submitNoteSplit`, and never stops sync for a broadcast that no longer happens here (S1):
    /// the engine's immediate path sweeps the current spendable balance in one transaction by
    /// design (`propose_immediate_migration_transfers`, "skipping the split entirely"). Silently
    /// splitting first would spend the same pre-split notes the immediate sweep's own PCZT is about
    /// to reference (the wallet DB never re-scans the split mid-flow, sync being stopped), signing a
    /// self-conflicting pair — `signAndStore` would typically still succeed locally, silently
    /// storing a double-spending sweep that a later broadcast rejects.
    ///
    /// `.scheduled` mode (finding #1): a `ZcashError.migrationRecordFailedAfterBroadcast` thrown by
    /// `submitNoteSplit` means the split's broadcast DID land on the network and only the engine's
    /// own bookkeeping of that fact failed to persist — treated as landed (mirrors
    /// `MigrationNoteSplitStore` / `MigrationSendingStore` / `RootInitialization`'s identical
    /// rationale for the same error) and the pipeline falls through to `signAndStoreMigrationSchedule`
    /// exactly as a `.success` result would, rather than surfacing a failure whose Retry would
    /// freshly sign a conflicting split over the just-spent notes. NEVER re-runs `prepareNoteSplit` /
    /// `submitNoteSplit` for this error — `sign_and_store_migration_schedule` reuses the run by id
    /// regardless of its phase (`preparing_denominations` or `waiting_denom_confirmations` — the
    /// only two phases this leaves the run in — both map to the same public
    /// `MigrationState.splitPendingConfirmation`, and `migration_state()`'s reconciliation
    /// explicitly self-heals a `preparing_denominations` run once its prep transaction mines,
    /// "so a broadcast whose result wasn't recorded still advances").
    ///
    /// - Throws: `MigrationCommitError.splitNotSuccessful` when `.scheduled` mode's split broadcast
    ///   genuinely failed (any other non-success result); otherwise propagates whatever the USK
    ///   derivation or underlying SDK calls throw. Callers map ANY throw here to their existing
    ///   commit-failure surface.
    static func commitSoftware(
        mode: MigrationCommitMode,
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
        switch mode {
        case .scheduled:
            let needsNoteSplit = try await sdkSynchronizer.isNoteSplitNeeded(account.id)
            let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                zip32AccountIndex: zip32AccountIndex,
                walletStorage: walletStorage,
                mnemonic: mnemonic,
                derivationTool: derivationTool,
                networkType: networkType
            )
            if needsNoteSplit {
                let proposal = try await sdkSynchronizer.prepareNoteSplit(account.id)
                let options = await migrationManager.migrationNetworkOptions(account.id)
                // [MOB-1496] W3 review fix A: stop an in-flight sync before this silent note-split
                // broadcast — the SDK's during-sync throw is advisory, so callers stop proactively.
                await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                do {
                    let splitResult = try await sdkSynchronizer.submitNoteSplit(account.id, proposal, usk, options)
                    guard case MigrationTransferResult.success = splitResult else {
                        throw MigrationCommitError.splitNotSuccessful
                    }
                } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                    // [MOB-1496] #1: the broadcast DID land; only recording failed — fall through to
                    // sign+store below exactly as a `.success` result would. See doc above.
                } catch {
                    // [MOB-1496] (R8-T4, #3): the stop above did NOT lead to a successful broadcast
                    // (either the SDK call itself threw some other error, or the guard above just
                    // threw because the result was non-success) — the SDK only transitions its
                    // migration-sync privacy gate on a SUCCESSFUL broadcast, so nudge Root's
                    // app-side gate feed with a fresh read here; otherwise a stop that never got
                    // cleared could strand sync stopped for the rest of the session (see
                    // `MigrationManagerClient.refreshMigrationSyncGate`'s doc).
                    await migrationManager.refreshMigrationSyncGate()
                    throw error
                }
            }
            try await sdkSynchronizer.signAndStoreMigrationSchedule(account.id, schedule, usk)

        case .immediate:
            let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                zip32AccountIndex: zip32AccountIndex,
                walletStorage: walletStorage,
                mnemonic: mnemonic,
                derivationTool: derivationTool,
                networkType: networkType
            )
            try await sdkSynchronizer.signAndStoreMigrationSchedule(account.id, schedule, usk)
        }

        // [MOB-1496] W2: persist the just-committed schedule (the SDK keeps no proposal list
        // post-commit) and reconcile so `stateEvents` picks up the fresh state promptly (a store
        // completing a migration op is one of `reconcile()`'s two triggers).
        await migrationManager.recordCommittedSchedule(account.id, schedule)
        await migrationManager.reconcile()
    }

    /// Proposes the Keystone-signing PCZT batch for `schedule`, external-signer path: unconditionally
    /// proposes the engine's preparation (note-split) PCZTs first — the final engine builds N
    /// preparation transactions, not one split transaction, and returns the (possibly empty) prep
    /// subset from that same call — then prepends any of them, each wrapped under the coordinator's
    /// `keystoneNoteSplitSentinelPrefix` + its own engine id (`MigrationCoordFlowCoordinator`'s
    /// `.scan(.foundPCZTBatch)` / `.simulateSignature` handlers split them back out and strip the
    /// prefix before storing — see `MigrationCoordFlow.keystoneNoteSplitSentinelPrefix`'s doc), ahead
    /// of the schedule's own PCZTs.
    ///
    /// MOB-1496 (final engine): the OLD `mode == .scheduled` gate — "only consult a split in scheduled
    /// mode; immediate is split-free by engine design (S1)" — is deleted. Two engine facts made that
    /// premise obsolete: the immediate flag only rewrites transfer heights, so an immediate-mode batch
    /// CAN carry preps too, and the run is created the moment this call builds ANY PCZTs (preps or
    /// schedule), regardless of mode — so skipping the prep propose in immediate mode wouldn't even
    /// have skipped run creation, just silently dropped preps the engine still needed signed. The fold
    /// is now unconditional and mode-independent; `mode` itself is unused here as a result (still used
    /// by `commitSoftware`, whose `.immediate` branch simply has no split-specific call to make —
    /// `signAndStoreMigrationSchedule` signs the whole committed run, preps included, so there is
    /// nothing to fold on that path — see `MigrationCommitMode.immediate`'s doc).
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
