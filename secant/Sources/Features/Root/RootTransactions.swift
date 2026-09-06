//
//  RootTransactions.swift
//  Zashi
//
//  Created by Lukáš Korba on 29.01.2025.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func transactionsReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .observeTransactions:
                return .merge(
                    .publisher {
                        // The transaction events must be filtered out of the stream BEFORE throttling.
                        // Throttling the raw stream with `latest: true` lets an unrelated event
                        // (`.connectionStateChanged`, `.storedUTXOs`) arriving in the same window
                        // replace a `foundTransactions`/`minedTransaction` as "latest", silently
                        // dropping the only signal that a pending transaction got mined.
                        sdkSynchronizer.eventStream()
                            .compactMap {
                                if case SynchronizerEvent.foundTransactions(let transactions, _) = $0 {
                                    return Root.Action.foundTransactions(transactions)
                                } else if case SynchronizerEvent.minedTransaction(let transaction) = $0 {
                                    return Root.Action.minedTransaction(transaction)
                                }
                                return nil
                            }
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                    }
                    .cancellable(id: state.CancelEventId, cancelInFlight: true),
                    .publisher {
                        // MOB-1853: a channel of its own, separate from the transaction events above.
                        // Sharing one "latest wins" throttle window with them let one kind of event
                        // silently replace the other as "latest" -- a `minedTransaction` could drop a
                        // `syncStalled`, and a `syncStalled` could just as easily drop a
                        // `minedTransaction`. The SDK emits `gaveUp: true` exactly once per handle, so
                        // losing it here would disable the stall escape hatch for that handle.
                        sdkSynchronizer.eventStream()
                            .compactMap {
                                if case SynchronizerEvent.syncStalled(let attempt, let gaveUp) = $0 {
                                    return Root.Action.syncStalled(attempt: attempt, gaveUp: gaveUp)
                                }
                                return nil
                            }
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                    }
                    .cancellable(id: state.CancelSyncStalledEventId, cancelInFlight: true),
                    .publisher {
                        sdkSynchronizer.stateStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .map {
                                if $0.syncStatus == .upToDate {
                                    return Root.Action.fetchTransactionsForTheSelectedAccount
                                }
                                return Root.Action.noChangeInTransactions
                            }
                    }
                    .cancellable(id: state.CancelTransactionsStateId, cancelInFlight: true),
                    .send(.fetchTransactionsForTheSelectedAccount)
                )
                
            case .noChangeInTransactions:
                return .none
                
            case .foundTransactions:
                return .send(.fetchTransactionsForTheSelectedAccount)
                
            case .minedTransaction:
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .syncStalled(let attempt, let gaveUp):
                LoggerProxy.event("[AutoServerSelection] Sync stalled (attempt: \(attempt), gaveUp: \(gaveUp))")
                // Attempt 1 is the SDK's own cheap reconnect to the SAME server -- it must get its
                // chance before the app tears the synchronizer down for a benchmarked switch. Only
                // a second restart, or recovery giving up outright, unblocks the switch.
                guard gaveUp || attempt >= 2 else { return .none }
                state.isSyncStalledSinceLastProgress = true
                guard gaveUp else { return .send(.refreshAutomaticServer) }
                // Terminal: the SDK's own recovery has given up, and it may have left no engine
                // handle behind. A benchmark-and-maybe-switch alone cannot bring sync back here --
                // manual mode has no candidate to offer, and even Automatic mode's ordinary switch is
                // a no-op once the winning candidate is the server already configured. Rebuild at the
                // best available endpoint instead (the current one included), at most
                // `maxTerminalStallRebuildsPerForeground` times per foreground; past that, the SDK's
                // own error state is left on screen rather than retrying silently forever.
                guard state.terminalStallRebuildsThisForeground < Root.State.maxTerminalStallRebuildsPerForeground else {
                    LoggerProxy.event("[AutoServerSelection] Terminal stall: rebuild budget exhausted for this foreground")
                    return .none
                }
                guard state.bgTask == nil, !state.isServerSetupVisible else { return .none }
                state.terminalStallRebuildsThisForeground += 1
                // MOB-1853: marks the window `.autoServerCandidateReady` must not act in -- see
                // `isTerminalStallRebuildInFlight`'s doc comment (`RootStore.swift`).
                state.isTerminalStallRebuildInFlight = true
                // A candidate parked earlier this foreground is stale now -- rebuildAfterStall
                // computes its own fresh one, so drop it before it can replay through applySwitch.
                state.pendingServerCandidate = nil
                return .merge(
                    // MOB-1853: a benchmark dispatched by an EARLIER `.refreshAutomaticServer`
                    // (attempt 2, before this give-up) may still be running -- it must not be left to
                    // deliver `.autoServerCandidateReady` out from under the rebuild this give-up is
                    // about to start. `applySwitch` itself carries no cancel id of its own (see
                    // `automaticServerRefreshCancelId`'s doc comment) and is not touched here; a
                    // switch already applying keeps running to completion regardless.
                    .cancel(id: state.automaticServerRefreshCancelId),
                    .run { send in
                        let started = await autoServerSelection.rebuildAfterStall()
                        await send(.terminalStallRebuildFinished(started))
                    }
                    .cancellable(id: state.terminalStallRebuildCancelId, cancelInFlight: true)
                )

            case .terminalStallRebuildFinished(let started):
                LoggerProxy.event("[AutoServerSelection] Terminal stall rebuild \(started ? "started a pass" : "did not start a pass")")
                state.isTerminalStallRebuildInFlight = false
                return .none

            case .fetchTransactionsForTheSelectedAccount:
                guard let accountUUID = state.selectedWalletAccount?.id else {
                    LoggerProxy.event("[RootTransactions] fetch skipped: no selected account yet")
                    return .none
                }
                // MOB-1856: refreshes are coalesced -- at most one `getAllTransactions` fetch runs
                // at a time. During a sync, `sdkSynchronizer.eventStream()` is throttled to one
                // event per 0.2s and every `foundTransactions`/`minedTransaction` re-dispatches this
                // action (see above); on a wallet with a long transaction history,
                // `getAllTransactions` reads the WHOLE history and can easily take longer than that
                // 0.2s interval, so before this guard, every throttled tick started its own
                // concurrent full-history fetch and they piled up for the whole sync, each one
                // competing for the same SQLite connection and CPU the sync itself needed. A
                // dispatch that arrives while one is already running just marks the request dirty
                // and returns; the in-flight fetch's own completion below (`.fetchedTransactions`/
                // `.transactionsFetchFailed`) folds every dispatch coalesced during its run into
                // exactly one follow-up fetch, for whichever account is selected at that point. This
                // id still exists so an account switch can cancel whatever fetch is still running
                // for the account just left (see `accountSwitchedEffect` in `RootCoordinator.swift`,
                // which explicitly `.cancel`s this id -- and resets the coalescing flags below --
                // before sending a fresh fetch for the new account); the `.fetchedTransactions`
                // provenance guard below still drops any payload for an account other than the one
                // currently selected, as a second line of defense.
                if state.isTransactionsFetchInFlight {
                    state.isTransactionsFetchDirty = true
                    return .none
                }
                state.isTransactionsFetchInFlight = true
                return .run { send in
                    do {
                        let transactions = try await sdkSynchronizer.getAllTransactions(accountUUID)
                        await send(.fetchedTransactions(accountUUID, transactions))
                    } catch {
                        // A failed fetch must never be silent: a wallet whose every row failed to
                        // decode (field, 2026-08-04 — NULL trust_status meeting a strict decode)
                        // rendered as an EMPTY transaction list with no trace anywhere, reading as
                        // data loss. The list keeps its previous contents; the error goes to the
                        // log where the next investigation can find it. No user-facing alert:
                        // `.transactionsFetchFailed` (below) still clears any list left showing its
                        // loading placeholder and re-arms the reconciliation poller from the KEPT
                        // rows, so together with the pending-transactions poller and the next
                        // synchronizer event, this fetch gets retried.
                        LoggerProxy.event("[RootTransactions] getAllTransactions FAILED — \(error.toZcashError())")
                        await send(.transactionsFetchFailed(accountUUID: accountUUID))
                    }
                }
                .cancellable(id: state.CancelTransactionsFetchId)

            case .fetchedTransactions(let accountUUID, var transactions):
                // MOB-1856: the coalescing gate's own completion signal -- the effect that set
                // `isTransactionsFetchInFlight` has now finished, whichever account it was for, so
                // the gate must open before anything else below (including the provenance guard's
                // own early return) or a fetch coalesced during this run would stay parked forever.
                // A dirty request folds into exactly one follow-up, for whichever account is
                // selected NOW -- which is exactly right even when this very completion is for a
                // stale account.
                state.isTransactionsFetchInFlight = false
                var coalescedFollowUp: Effect<Root.Action> = .none
                if state.isTransactionsFetchDirty {
                    state.isTransactionsFetchDirty = false
                    coalescedFollowUp = .send(.fetchTransactionsForTheSelectedAccount)
                }

                // Load-bearing provenance guard -- drop a payload that belongs to an account other
                // than the one currently selected. Closes the race even when the cancel id above
                // misses (the fetch's own effect completed anyway): during sync, BOTH accounts'
                // wallet-wide `eventStream`/`stateStream` events can dispatch a fetch, and a slow one
                // for the account that was JUST switched away from can still land after the switch.
                // Never merge/reconcile a stale payload -- always drop it whole.
                guard accountUUID == state.selectedWalletAccount?.id else {
                    return coalescedFollowUp
                }

                let mempoolHeight = sdkSynchronizer.latestState().latestBlockHeight + 1

                // Resolve Swaps
                let allSwaps = userMetadataProvider.allSwaps()
                
                // Swaps From ZEC and CrossPays
                let swapsFromZecAndCrossPays = allSwaps.filter {
                    $0.fromAsset == SwapConstants.zecAssetIdOnNear
                }
                
                swapsFromZecAndCrossPays.forEach { swap in
                    if let transaction = transactions.filter({ $0.zAddress == swap.depositAddress }).first {
                        transactions[id: transaction.id]?.type = swap.exactInput ? .swapFromZec : .crossPay
                        transactions[id: transaction.id]?.swapStatus = swap.swapStatus
                    }
                }

                // Swaps To ZEC
                let swapsToZec = allSwaps.filter {
                    $0.toAsset == SwapConstants.zecAssetIdOnNear
                }

                var mixedTransactions = transactions

                swapsToZec.forEach { swap in
                    mixedTransactions.append(
                        TransactionState(
                            depositAddress: swap.depositAddress,
                            timestamp: TimeInterval(swap.lastUpdated / 1000),
                            zecAmount: swap.amountOutFormatted.localeString ?? swap.amountOutFormatted,
                            swapStatus: swap.swapStatus
                        )
                    )
                }

                // Sort all transactions
                let sortedTransactions = mixedTransactions
                    .sorted { lhs, rhs in
                        if let lhsTimestamp = lhs.timestamp, let rhsTimestamp = rhs.timestamp {
                            return lhsTimestamp > rhsTimestamp
                        } else {
                            return lhs.transactionListHeight(mempoolHeight) > rhs.transactionListHeight(mempoolHeight)
                        }
                    }
                
                let identifiedArray = IdentifiedArrayOf<TransactionState>(uniqueElements: sortedTransactions)

                // Reconciliation poller: while anything is pending, the list must not depend solely
                // on push signals (a dropped event or a missed `.upToDate` tick would otherwise leave
                // a mined transaction rendered as "Sending…" forever). Re-read the local database
                // every 30 seconds until nothing is pending — a cheap SQLite read, no network.
                // Managed on every completed fetch, including ones whose payload equals the current
                // state, so an unchanged list keeps the poller alive. Extracted into
                // `reconciliationPoller(for:state:)` below so the ignored-empty-fetch and
                // fetch-failure paths can arm it from the KEPT `state.transactions` instead of a
                // fetch result they never apply.
                let pendingTransactionsPoller = reconciliationPoller(for: identifiedArray, state: state)

                // MOB-1855: a spurious empty fetch must never blank a list that already has rows.
                // `getAllTransactions` can legitimately race a reorg/rescan window mid-sync and
                // answer with zero rows for an account that plainly has transactions; only trust an
                // empty result once the synchronizer itself reports `.upToDate`, or once a list is
                // already invalidated and therefore has nothing correct left to lose. Tests the RAW
                // fetched `transactions`, not `identifiedArray`: `mixedTransactions` above
                // unconditionally appends one synthetic row per in-flight swap-to-ZEC, so a
                // genuinely empty on-chain fetch would otherwise still produce a non-empty
                // `identifiedArray` and defeat this guard for any user with such a swap pending.
                // Both lists still get `transactionsUpdated` so one that WAS mid-load can clear its
                // placeholder, and the poller is armed from the KEPT `state.transactions`, never
                // from this fetch's result, so a still-pending kept row keeps its 30 s reconciler.
                //
                // MOB-1855: `state.transactionsAccountId == accountUUID` on top of the pre-existing
                // conditions -- the array being "kept" here must actually belong to the account THIS
                // fetch just answered for, or the guard would protect a foreign account's leftover
                // rows the same way it protects a legitimate stale-empty-during-sync race. In normal
                // operation `accountSwitchedEffect` already empties `state.transactions` on every
                // switch, so `!state.transactions.isEmpty` above would already be false for a
                // just-switched-to account -- this clause is defense in depth for that guarantee, not
                // the only thing enforcing it.
                let listsAreInvalidated = state.homeState.transactionListState.isInvalidated
                    || state.transactionsCoordFlowState.transactionsManagerState.isInvalidated
                if transactions.isEmpty
                    && !state.transactions.isEmpty
                    && !listsAreInvalidated
                    && !isUpToDate(state.lastKnownSyncStatus)
                    && state.transactionsAccountId == accountUUID {
                    LoggerProxy.event("[RootTransactions] ignored an empty fetch while sync is not up to date; kept \(state.transactions.count) rows")
                    return .merge(
                        reconciliationPoller(for: state.transactions, state: state),
                        .send(.home(.transactionList(.transactionsUpdated))),
                        .send(.transactionsCoordFlow(.transactionsManager(.transactionsUpdated))),
                        coalescedFollowUp
                    )
                }

                // ZIP 318 labels: Activity now PRESENTS migration transactions instead of hiding
                // them — a stored-but-unmined row renders as "Migrating…"/"Splitting Balance…"
                // with the coins-swap glyph (Figma "Transaction Statuses/Labels — Final Designs"),
                // so the store-at-prove rows that once looked like phantom "Sending…" sends now
                // tell the true in-flight story right on the list. This supersedes the M3 Part A
                // filter that removed them. This is still the single canonical list build, so
                // every consumer of the shared `$transactions` sees the same truth.
                //
                // M3 B2 (unchanged): the SAME rows are what the SDK's pending-balance lanes count
                // for the whole prove→mine window, so their received value is still published
                // beside the canonical list — one pass, one clock — for the balance-breakdown
                // sheet to remove from its displayed "Pending" row. `totalReceived` is exactly a
                // migration transaction's contribution to the pending lanes (all its real outputs
                // are internal, and its spent side never enters them); a nil reads as zero, which
                // under-corrects — conservative, never future-tense.
                //
                // MOB-1855: computed here, AFTER the empty-fetch guard above, rather than at the
                // top of this case -- an ignored spurious-empty fetch must not zero this figure for
                // one tick either. `transactions` is unaffected by anything in between: the
                // swap-relabeling loop above only mutates existing rows' `type`/`swapStatus`, never
                // their count or `totalReceived`.
                let unminedMigrationPending = transactions
                    .filter { $0.isUnminedMigrationTransaction }
                    .reduce(Zatoshi.zero) { $0 + ($1.totalReceived ?? Zatoshi.zero) }
                state.$unminedMigrationPendingValue.withLock { $0 = unminedMigrationPending }

                // Update transactions
                if state.transactions != identifiedArray {
                    state.$transactions.withLock {
                        $0 = identifiedArray
                    }
                    // MOB-1855: this write is the one place the array's contents actually change to
                    // reflect `accountUUID`'s fetch, so this is where provenance is recorded too --
                    // see `transactionsAccountId`'s doc comment (`RootStore.swift`).
                    state.transactionsAccountId = accountUUID
                    return .merge(
                        pendingTransactionsPoller,
                        .send(.home(.smartBanner(.evaluatePriority6))),
                        coalescedFollowUp
                    )
                }
                // The fetch still completed even though its result is identical to what's already in
                // `state.transactions` -- most commonly when switching between two accounts that both
                // have no transactions. The write above is skipped in that case, so nothing downstream
                // of the shared `$transactions` publisher fires. Both transaction lists' own
                // `transactionsUpdated` is what clears their `isInvalidated` flag (set by
                // `accountSwitchedEffect` in `RootCoordinator.swift` on every switch), so without
                // sending it here directly, an unchanged-but-completed fetch would leave them stuck
                // showing their loading placeholder forever.
                //
                // Only worth sending while a list is actually still showing that placeholder. A
                // steady sync re-dispatches this fetch every 0.2s and usually yields an unchanged
                // list, and `transactionsUpdated` re-runs each store's derived-state recomputation
                // -- which on the See All screen, with a search term active, includes an SDK memo
                // query. Nothing is waiting on the signal once both flags are already clear.
                guard state.homeState.transactionListState.isInvalidated
                    || state.transactionsCoordFlowState.transactionsManagerState.isInvalidated else {
                    return .merge(pendingTransactionsPoller, coalescedFollowUp)
                }
                return .merge(
                    pendingTransactionsPoller,
                    .send(.home(.transactionList(.transactionsUpdated))),
                    .send(.transactionsCoordFlow(.transactionsManager(.transactionsUpdated))),
                    coalescedFollowUp
                )

            case .transactionsFetchFailed(let accountUUID):
                // MOB-1856: same coalescing-gate reset as `.fetchedTransactions` above, and for the
                // same reason -- this completion also ends the effect that set
                // `isTransactionsFetchInFlight`, whichever account it was for, so the gate must open
                // before the provenance guard below can return early, or a fetch coalesced during
                // this run would stay parked forever.
                state.isTransactionsFetchInFlight = false
                var coalescedFollowUp: Effect<Root.Action> = .none
                if state.isTransactionsFetchDirty {
                    state.isTransactionsFetchDirty = false
                    coalescedFollowUp = .send(.fetchTransactionsForTheSelectedAccount)
                }

                // Same provenance guard as `.fetchedTransactions` above, and for the same reason:
                // without it, a stale failure for an account the user has since switched away from
                // would clear the NEWLY selected account's `isInvalidated` flags and re-arm the
                // poller from ITS `state.transactions` -- which at that point may still be the
                // PREVIOUS account's leftover rows -- marking the new account "loaded" while the
                // wrong rows are still on screen.
                guard accountUUID == state.selectedWalletAccount?.id else {
                    return coalescedFollowUp
                }
                // MOB-1855: a failure carries no rows of its own to apply, so it must never be the path
                // that VALIDATES rows left behind by a different account. `accountSwitchedEffect`
                // (`RootCoordinator.swift`) already empties `state.transactions` on every switch, so
                // reaching this with a non-empty array whose `transactionsAccountId` disagrees with
                // `accountUUID` should not occur -- but "should not occur" is exactly the case a
                // failure path must still cover defensively, since there is no fresh fetch result
                // here to overwrite the wrong rows with. Log it: if this ever fires, that gap is
                // worth investigating on its own.
                if state.transactionsAccountId != accountUUID, !state.transactions.isEmpty {
                    let clearedRowCount = state.transactions.count
                    state.$transactions.withLock { $0 = [] }
                    LoggerProxy.event(
                        "[RootTransactions] transactionsFetchFailed found \(clearedRowCount) foreign-account rows still in state; cleared them"
                    )
                    // MOB-1862: derived from those same foreign rows (`.fetchedTransactions`, above)
                    // and read straight into the balance breakdown's "Pending" row, so it must leave
                    // together with them instead of continuing to describe an account that is no
                    // longer on screen.
                    state.$unminedMigrationPendingValue.withLock { $0 = .zero }
                    // MOB-1853: `transactionsAccountId`'s own invariant (`RootStore.swift`) is that it
                    // always names the account whose rows `$transactions` currently holds -- with the
                    // array just cleared to empty, the field must follow it back to `nil` rather than
                    // keep naming the foreign account whose rows are now gone.
                    state.transactionsAccountId = nil
                }
                // The list keeps its previous contents (nothing to overwrite here at all), but
                // either list may already be showing its loading placeholder -- clear it exactly
                // like every other completed-fetch path, and keep the reconciliation poller alive
                // for whatever `state.transactions` still holds.
                return .merge(
                    reconciliationPoller(for: state.transactions, state: state),
                    .send(.home(.transactionList(.transactionsUpdated))),
                    .send(.transactionsCoordFlow(.transactionsManager(.transactionsUpdated))),
                    coalescedFollowUp
                )

            default: return .none
            }
        }
    }

    /// Builds the reconciliation-poller effect for `transactions`: while any `.zcash` row is
    /// pending (`minedHeight == nil`), a 30 s local-database re-read backstops a lost push signal
    /// (a dropped event, or a missed `.upToDate` tick) that would otherwise leave a mined
    /// transaction rendered as "Sending…" forever; the poller cancels itself once nothing meets
    /// that condition. Takes the transactions to inspect as a parameter, rather than always
    /// reading `state.transactions` directly, so a caller that keeps the existing list -- on a
    /// spurious empty fetch, or on a failed fetch -- can still arm the reconciler from those KEPT
    /// rows instead of from a fetch result it never applies. Restricted to `.zcash` transactions,
    /// whose pending state is resolvable by exactly the local re-read this poller performs; every
    /// other type's `isPending` reports the SWAP status, owned by the swap provider's metadata and
    /// refreshed elsewhere (`.autoUpdateCandidatesSwapDetails` in `RootSwaps`) -- re-reading the SDK
    /// database can never resolve it, and an abandoned or stalled swap never has to resolve, so
    /// arming this poller on one would poll forever against state it cannot possibly settle.
    private func reconciliationPoller(for transactions: IdentifiedArrayOf<TransactionState>, state: Root.State) -> Effect<Root.Action> {
        if transactions.contains(where: { $0.type == .zcash && $0.isPending }) {
            return .run { send in
                while !Task.isCancelled {
                    try await mainQueue.sleep(for: .seconds(30))
                    await send(.fetchTransactionsForTheSelectedAccount)
                }
            }
            .cancellable(id: state.CancelPendingTxPollId, cancelInFlight: true)
        } else {
            return .cancel(id: state.CancelPendingTxPollId)
        }
    }

    /// True only once the synchronizer itself has reported `.upToDate`; `nil` (nothing observed
    /// yet this session, or just cleared at `.didEnterBackground`) is deliberately NOT up to date,
    /// matching `Root.State.isSynchronizerIdleForSwitch`'s treatment of the same optional.
    private func isUpToDate(_ status: SyncStatus?) -> Bool {
        guard let status else { return false }
        switch status {
        case .upToDate: return true
        case .unprepared, .syncing, .stopped, .error: return false
        }
    }
}
