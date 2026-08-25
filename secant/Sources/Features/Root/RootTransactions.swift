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

            case .fetchTransactionsForTheSelectedAccount:
                guard let accountUUID = state.selectedWalletAccount?.id else {
                    return .none
                }
                // This id exists so an account switch can cancel whatever fetch is still running
                // for the account just left (see `accountSwitchedEffect` in `RootCoordinator.swift`,
                // which explicitly `.cancel`s this id before sending a fresh fetch for the new
                // account). `cancelInFlight` is deliberately NOT used here: during a sync,
                // `sdkSynchronizer.eventStream()` is throttled to one event per 0.2s and every
                // `foundTransactions`/`minedTransaction` re-dispatches this action (see above) -- on
                // a wallet where `getAllTransactions` takes longer than that 0.2s interval,
                // `cancelInFlight` would cancel every one of those fetches before it could complete,
                // starving `.fetchedTransactions` for the whole sync. Letting concurrent fetches for
                // the same account run to completion is harmless: the `.fetchedTransactions`
                // provenance guard below still drops any payload for an account other than the one
                // currently selected.
                return .run { send in
                    do {
                        let transactions = try await sdkSynchronizer.getAllTransactions(accountUUID)
                        await send(.fetchedTransactions(accountUUID, transactions))
                    } catch {
                        // A failed fetch must never be silent: a wallet whose every row failed to
                        // decode (field, 2026-08-04 — NULL trust_status meeting a strict decode)
                        // rendered as an EMPTY transaction list with no trace anywhere, reading as
                        // data loss. The list keeps its previous contents; the error goes to the
                        // log where the next investigation can find it. No user-facing alert: the
                        // pending-transactions poller and the next synchronizer event both retry
                        // this fetch.
                        LoggerProxy.event("[RootTransactions] getAllTransactions FAILED — \(error.toZcashError())")
                    }
                }
                .cancellable(id: state.CancelTransactionsFetchId)

            case .fetchedTransactions(let accountUUID, var transactions):
                // Load-bearing provenance guard -- drop a payload that belongs to an account other
                // than the one currently selected. Closes the race even when the cancel id above
                // misses (the fetch's own effect completed anyway): during sync, BOTH accounts'
                // wallet-wide `eventStream`/`stateStream` events can dispatch a fetch, and a slow one
                // for the account that was JUST switched away from can still land after the switch.
                // Never merge/reconcile a stale payload -- always drop it whole.
                guard accountUUID == state.selectedWalletAccount?.id else {
                    return .none
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
                let unminedMigrationPending = transactions
                    .filter { $0.isUnminedMigrationTransaction }
                    .reduce(Zatoshi.zero) { $0 + ($1.totalReceived ?? Zatoshi.zero) }
                state.$unminedMigrationPendingValue.withLock { $0 = unminedMigrationPending }

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
                // state, so an unchanged list keeps the poller alive.
                //
                // Deliberately restricted to `.zcash` transactions, whose pending state is
                // `minedHeight == nil` and therefore resolvable by exactly the local re-read this
                // poller performs. For every other type `isPending` reports the SWAP status
                // (`TransactionState.isPending`), which is owned by the swap provider's metadata and
                // refreshed by `.autoUpdateCandidatesSwapDetails` in `RootSwaps` — re-reading the
                // SDK database can never resolve it. Including those here would leave a swap parked
                // in `.pending`/`.incomplete` (an abandoned or stalled swap never has to resolve)
                // polling every 30 seconds for the rest of the session, with no state it could
                // possibly settle.
                let pendingTransactionsPoller: Effect<Root.Action>
                if identifiedArray.contains(where: { $0.type == .zcash && $0.isPending }) {
                    pendingTransactionsPoller = .run { send in
                        while !Task.isCancelled {
                            try await mainQueue.sleep(for: .seconds(30))
                            await send(.fetchTransactionsForTheSelectedAccount)
                        }
                    }
                    .cancellable(id: state.CancelPendingTxPollId, cancelInFlight: true)
                } else {
                    pendingTransactionsPoller = .cancel(id: state.CancelPendingTxPollId)
                }

                // Update transactions
                if state.transactions != identifiedArray {
                    state.$transactions.withLock {
                        $0 = identifiedArray
                    }
                    return .merge(
                        pendingTransactionsPoller,
                        .send(.home(.smartBanner(.evaluatePriority6)))
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
                    return pendingTransactionsPoller
                }
                return .merge(
                    pendingTransactionsPoller,
                    .send(.home(.transactionList(.transactionsUpdated))),
                    .send(.transactionsCoordFlow(.transactionsManager(.transactionsUpdated)))
                )

            default: return .none
            }
        }
    }
}
