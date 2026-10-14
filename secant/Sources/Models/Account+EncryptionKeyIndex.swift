//
//  Account+EncryptionKeyIndex.swift
//  modules
//
//  MOB-2020: a Ledger account is imported with no ZIP 32 account index -- the SDK requires the
//  index to be `nil` at import time, since a Ledger never reveals it. `UserMetadataEncryptionKeys`
//  and `AddressBookEncryptionKeys` key their caches by that index, so an index-less account needs
//  a stand-in to be cached and derived at all.
//

@preconcurrency import ZODLSwiftWalletSDK

extension Account {
    /// The index an account's encryption keys are cached and derived under.
    ///
    /// For a normally-derived account this is `hdAccountIndex`. A Ledger account has no
    /// `hdAccountIndex`, so its encryption keys are keyed and derived at index 0 instead -- the
    /// same index the shared address book key already uses for every account. V0 allows only one
    /// Ledger account, so no two index-less accounts ever share a keychain item: those items are
    /// named by account name, not by this index.
    var encryptionKeyIndex: Zip32AccountIndex {
        hdAccountIndex ?? Zip32AccountIndex(0)
    }
}
