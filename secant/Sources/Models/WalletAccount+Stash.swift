//
//  WalletAccount+Stash.swift
//  modules
//
//  MOB-1859: `walletAccounts()` no longer generates the rotation stash (`nextPrivateUA`) on
//  every load — that generation is a wallet-database write, and doing it for every account on
//  every load contended with the sync engine during catch-up. This file holds the pieces that
//  used to be duplicated across call sites, or missing entirely: a pure helper that carries a
//  stash forward across a reload instead of losing it, the shared background work that
//  (re)generates a stash address (previously copy-pasted between HomeStore and SwapAndPayStore),
//  and the single write path that keeps every shared copy of an account's stash — the
//  `walletAccounts` array included — in sync with each other.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension WalletAccount {
    /// Copies each account's pre-generated rotation stash (`nextPrivateUA`) from `current` into
    /// the freshly loaded `loaded` list, matched by `id`. A fresh load always comes back with a
    /// nil stash for every account (MOB-1859), so without this merge, reloading the accounts
    /// list — a foreground refresh, a Keystone disconnect/reconnect, a newly imported account —
    /// would silently drop whatever stash Receive/Swap had already pre-generated for the
    /// accounts that already existed. An account with no matching entry in `current` (freshly
    /// imported, or the very first load) simply keeps the nil stash it already has: it gets one
    /// lazily, either from a background refill dispatched after the load or from the next
    /// Receive/Swap visit.
    static func mergingPrivateUAStash(from current: [WalletAccount], into loaded: [WalletAccount]) -> [WalletAccount] {
        loaded.map { account in
            var account = account
            account.nextPrivateUA = current.first { $0.id == account.id }?.nextPrivateUA
            return account
        }
    }
}

/// The rotate-ahead-by-one stash behind the "next private address" that Receive and Swap
/// promote into view when the user taps in (MOB-1803): a fresh unified address is pre-generated
/// and held in `WalletAccount.nextPrivateUA`, never shown, so a visit can promote it into the
/// displayed `privateUA` slot synchronously instead of waiting on a wallet-database write. This
/// namespace holds the two pieces every caller needs: which receivers a stash address is
/// generated with, and the background work that (re)generates one and reports it back.
///
/// `refill` deliberately stops short of returning an `Effect<Action>`: `Root.Action` — one of
/// this helper's three callers — does not conform to `Sendable` (it carries payloads, such as
/// `BGProcessingTask`, that can't), so a generic `Action` parameter used inside a `send(...)`
/// call cannot type-check under strict concurrency for every caller at once. Working only in
/// `WalletAccount`/`UnifiedAddress?`/`AccountUUID` — all `Sendable` — sidesteps that: each caller
/// keeps its own concretely-typed `.run { send in … }.cancellable(id:)`, which is where that
/// wrapping already lived, and only the generation loop and the receiver rule are shared.
enum PrivateUAStash {
    /// The receiver set a stash address is generated with. A Keystone hardware account can only
    /// receive shielded funds through an orchard-only address; every other account uses the full
    /// sapling+orchard receiver set. The single source of truth for this rule — previously
    /// inlined at each call site, including the one that used to run inside `walletAccounts()`.
    static func receivers(for account: WalletAccount) -> Set<ReceiverType> {
        account.vendor == .keystone ? [.orchard] : [.sapling, .orchard]
    }

    /// Generates a fresh stash address for each of `accounts`, in order, awaiting each in turn,
    /// and reports every result back through `onGenerated` as it lands. Callers pass a single
    /// selected account (Home's and SwapAndPay's own refill-after-promotion effect) or every
    /// account whose stash came back nil from a load (Root's `.loadedWalletAccounts`). This is
    /// meant to run inside a caller's own `.run { send in … }` — never awaited on a path the UI
    /// blocks on — with the caller wrapping that in its own `.cancellable(id:)` so a newer
    /// request supersedes a still-running one. Errors are swallowed with `try?`, matching every
    /// other call site of this SDK method: a failed generation just leaves that account's stash
    /// nil for the next attempt to retry.
    static func refill(
        accounts: [WalletAccount],
        sdkSynchronizer: SDKSynchronizerClient,
        onGenerated: @Sendable (UnifiedAddress?, AccountUUID) async -> Void
    ) async {
        for account in accounts {
            let accountId = account.id
            let freshUA = try? await sdkSynchronizer.getCustomUnifiedAddress(accountId, receivers(for: account))
            await onGenerated(freshUA, accountId)
        }
    }

    /// Writes `nextPrivateUA` for `accountId` into every shared slot that can hold a copy of that
    /// account, so the `walletAccounts` array can never fall out of sync with the live copies
    /// rotation actually reads and writes. Without this, only `selectedWalletAccount` (and,
    /// where tracked, `zashiWalletAccount`) ever saw a stash — the array entry stayed nil forever,
    /// so an account switch (`WalletAccountsSheet`, which installs the tapped ARRAY entry as the
    /// new selection) always installed a nil stash, forcing the slow live-fill path on every
    /// first Receive/Swap visit after a switch, not just the very first one ever.
    ///
    /// Every stash write goes through this one function: Root's background refill after a load,
    /// Home's and SwapAndPay's refill after a promotion, and the promotion step itself (which
    /// calls this with `nil` to clear the stash it just consumed). Clearing through here too
    /// matters as much as writing: if the array entry kept a stash that was already promoted and
    /// shown, switching away and back would re-install and re-show that same address, breaking
    /// the MOB-1803 guarantee that a promoted address is never shown twice.
    ///
    /// `zashiWalletAccount` defaults to `nil` because not every feature tracks it — only
    /// `Root.State` declares all three `@Shared` slots; `Home.State` and `SwapAndPay.State`
    /// declare just `walletAccounts` and `selectedWalletAccount`.
    static func write(
        _ nextPrivateUA: UnifiedAddress?,
        forAccountId accountId: AccountUUID,
        walletAccounts: Shared<[WalletAccount]>,
        selectedWalletAccount: Shared<WalletAccount?>,
        zashiWalletAccount: Shared<WalletAccount?>? = nil
    ) {
        walletAccounts.withLock { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
            accounts[index].nextPrivateUA = nextPrivateUA
        }
        selectedWalletAccount.withLock {
            guard $0?.id == accountId else { return }
            $0?.nextPrivateUA = nextPrivateUA
        }
        if let zashiWalletAccount {
            zashiWalletAccount.withLock {
                guard $0?.id == accountId else { return }
                $0?.nextPrivateUA = nextPrivateUA
            }
        }
    }
}
