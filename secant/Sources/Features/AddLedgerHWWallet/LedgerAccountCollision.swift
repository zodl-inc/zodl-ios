//
//  LedgerAccountCollision.swift
//  Zashi
//
//  MOB-2020 Ledger error states: librustzcash refuses to import a Ledger whose viewing key
//  already belongs to an account in the wallet (`SqliteClientError::AccountCollision(uuid)`) --
//  for example a Ledger that shares a recovery phrase with the Zodl wallet or the Keystone. The
//  SDK has no `ZcashError` case for this refusal, so unlike LedgerIssue.swift (which matches only
//  on the ZcashError/LedgerClientError case, never on message text), this type has no choice but
//  to read the Rust error text itself. It arrives as
//  `ZcashError.rustImportAccountUfvk(message)`, whose message is the raw Rust string, e.g.
//  "Error while initializing accounts: An account corresponding to the data provided already
//  exists in the wallet with UUID AccountUuid(67e55044-10b1-426f-9247-bb680e5fe0c8)." That text is
//  read only to classify the failure and locate the existing account -- it is never logged or
//  otherwise surfaced.
//
//  This type has two checks: `existingAccount(matching:among:)` runs right after pairing, before
//  any import is attempted, and matches by exact UFVK string encoding; `isCollision` /
//  `collidingAccount` are the import-time backstop, reading librustzcash's own refusal for a
//  collision the pre-import check didn't catch.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Recognizes librustzcash's "account already in the wallet" import refusal and finds the
/// existing account it names.
enum LedgerAccountCollision {
    /// A UUID formatted the way Rust's error text prints one -- lowercase, hyphenated RFC 4122.
    private static let uuidPattern = "[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"

    /// The pre-import check: the `walletAccounts` element already carrying this exact UFVK
    /// encoding, or `nil` when none does. An account with no UFVK never matches. This runs on the
    /// device picker as soon as pairing succeeds, before an import is even attempted -- the
    /// import-time refusal (`isCollision` / `collidingAccount`) stays in place as the backstop
    /// for a key that shares any one component (its Orchard, Sapling or transparent key) with an
    /// account already stored -- librustzcash matches component by component, this check only on
    /// the whole encoding.
    static func existingAccount(matching ufvk: String, among walletAccounts: [WalletAccount]) -> WalletAccount? {
        walletAccounts.first { $0.account.ufvk?.stringEncoded == ufvk }
    }

    /// `true` only for `ZcashError.rustImportAccountUfvk` whose message is this specific refusal,
    /// never any other import failure.
    static func isCollision(_ error: Error) -> Bool {
        message(from: error)?.contains("already exists in the wallet") ?? false
    }

    /// The `walletAccounts` element the colliding Ledger already matches, found by parsing the
    /// UUID out of the Rust error text -- `nil` when `error` is not `isCollision`, or when the
    /// message's UUID doesn't (or no longer) name one of `walletAccounts`.
    static func collidingAccount(in error: Error, among walletAccounts: [WalletAccount]) -> WalletAccount? {
        guard isCollision(error), let message = message(from: error) else { return nil }
        guard let uuidRange = message.range(of: uuidPattern, options: .regularExpression),
              let uuid = UUID(uuidString: String(message[uuidRange])) else {
            return nil
        }
        // `AccountUUID.id` stores the same 16 bytes, in the same order as the canonical string --
        // `withUnsafeBytes(of:)` on the tuple `UUID.uuid` walks its fields in that same order.
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return walletAccounts.first { $0.id.id == uuidBytes }
    }

    /// `ZcashError.rustImportAccountUfvk`'s raw Rust error text, or `nil` for any other error.
    private static func message(from error: Error) -> String? {
        guard case ZcashError.rustImportAccountUfvk(let message) = error else { return nil }
        return message
    }
}
