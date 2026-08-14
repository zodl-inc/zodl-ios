//
//  WalletStorage.swift
//  Zashi
//
//  Created by Lukáš Korba on 03/10/2022.
//

import Foundation
import os
@preconcurrency import MnemonicSwift
@preconcurrency import ZcashLightClientKit

/// Zcash implementation of the keychain that is not universal but designed to deliver functionality needed by the wallet itself.
/// All the APIs should be thread safe according to official doc:
/// https://developer.apple.com/documentation/security/certificate_key_and_trust_services/working_with_concurrency?language=objc
struct WalletStorage {
    enum Constants {
        static let zcashStoredWallet = "zcashStoredWallet"
        /// macOS Secure-Enclave storage (see docs/macos/KEYCHAIN_SE_HARDENING.md): the seed lives as
        /// ECIES ciphertext under `…Seed`, its non-secret metadata as plaintext under `…Meta`. On iOS
        /// the single `zcashStoredWallet` blob is used instead.
        static let zcashStoredWalletSeed = "zcashStoredWalletSeed"
        static let zcashStoredWalletMeta = "zcashStoredWalletMeta"
        /// Auth-free storage-format version marker (plaintext) — drives the one-time SE migration.
        static let zcashStorageVersion = "zcashStorageVersion"
        static let zcashStorageVersionSecureEnclave = 2
        static let zcashStoredAdressBookEncryptionKeys = "zcashStoredAdressBookEncryptionKeys"
        static let zcashStoredUserMetadataEncryptionKeys = "zcashStoredMetadataEncryptionKeys"

        static let zcashStoredWalletBackupReminder = "zcashStoredWalletBackupReminder"
        static let zcashStoredShieldingReminder = "zcashStoredShieldingReminder"
        static func zcashStoredShieldingReminder(accountName: String) -> String {
            "\(Constants.zcashStoredShieldingReminder)_\(accountName)"
        }

        static let zcashStoredWalletBackupAcknowledged = "zcashStoredWalletBackupAcknowledged"
        static let zcashStoredShieldingAcknowledged = "zcashStoredShieldingAcknowledged"
        static let zcashStoredTorSetupFlag = "zcashStoredTorSetupFlag"
        static let zcashStoredVotingHotkey = "zcashStoredVotingHotkey"
        static let zcashStoredZodlAnnouncementFlag = "zcashStoredZodlAnnouncementFlag"
        // This key is deliberately NOT removed in `resetZashi`. The Ironwood announcement is shown once
        // per device and must survive a wallet reset and an app reinstall; wiping it here would re-show
        // the screen after every restore. It gets added to the reset method only when we decide to
        // retire the announcement screen.
        static let zcashStoredIronwoodAnnouncementFlag = "zcashStoredIronwoodAnnouncementFlag"

        /// Versioning of the stored data
        static let zcashKeychainVersion = 1

        static func accountMetadataFilename(account: Account) -> String {
            Constants.zcashStoredUserMetadataEncryptionKeys + "_\(account.name?.lowercased() ?? "")"
        }

        /// Per-account keychain key for the voting hotkey. The suffix is the
        /// SDK `AccountUUID` hex so two accounts (e.g. Zashi + Keystone) on the
        /// same device get distinct hotkeys and therefore distinct on-chain
        /// voter identities.
        static func zcashStoredVotingHotkey(accountId: AccountUUID) -> String {
            "\(Constants.zcashStoredVotingHotkey)_\(accountId.id.map { String(format: "%02x", $0) }.joined())"
        }
    }
    
    /// States of the Swap API access opt-in
    enum SwapAPIAccess: Equatable, Codable, Hashable {
        /// A user decided to allow the API access over Tor
        case protected
        /// A user skipped the protected step by use over Tor so the swaps are done via direct calls, no IP protection
        case direct
    }

    enum KeychainError: Error, Equatable {
        case decoding
        case duplicate
        case encoding
        case noDataFound
        case unknown(OSStatus)
    }

    enum WalletStorageError: Error {
        case alreadyImported
        case secureEnclaveUnavailable
        case uninitializedAddressBookEncryptionKeys
        case uninitializedUserMetadataEncryptionKeys
        case uninitializedWallet
        case storageError(Error)
        case unsupportedVersion(Int)
        case unsupportedLanguage(MnemonicLanguageType)
    }

    let secItem: SecItemClient
    /// Non-nil only on macOS: the seed is wrapped by a non-extractable Secure Enclave key instead of
    /// being stored as plaintext. Nil on iOS and in tests, where the legacy plaintext path is used.
    private let secureEnclave: SecureEnclaveClient?
    var zcashStoredWalletPrefix = ""
    /// macOS live wiring sets this (WalletStorageLiveKey): every keychain query then targets the
    /// iOS-style Data Protection keychain — access decided silently from the code signature —
    /// instead of the legacy file-based login keychain, whose per-item signature ACLs throw
    /// password dialogs at differently-signed builds (Xcode vs Developer ID vs TestFlight).
    /// Existing items are relocated once by WalletStorage+KeychainRelocation. Never set on iOS.
    var useDataProtectionKeychain = false

    /// Once-per-process relocation gate (WalletStorage+KeychainRelocation.swift). Copies of an
    /// `OSAllocatedUnfairLock` share one underlying allocation, so every dependency closure that
    /// holds a copy of the live storage shares this single gate.
    let relocationGate = OSAllocatedUnfairLock<KeychainRelocationState>(initialState: KeychainRelocationState.notStarted)

    /// Restore/create primes the just-supplied seed here (macOS / Secure-Enclave only) so the first-init
    /// burst — `prepare` plus the seed-derived metadata / address-book keys — reuses it instead of
    /// re-decrypting the SE-wrapped seed 2–3 times (each a biometric prompt). Consumed by the first
    /// `exportWallet()`, never persisted; a timestamp backstop prevents stale reuse. iOS / spends are
    /// unaffected (nil unless just stored). Held in a reference box because `WalletStorage` is a value
    /// type shared by-copy across the dependency closures. See docs/macos/KEYCHAIN_SE_HARDENING.md.
    private let primedSeedBox = PrimedSeedBox()

    /// Thread-safe single-use holder for the primed seed (see `primedSeedBox`).
    private final class PrimedSeedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (wallet: StoredWallet, primedAt: Date)?
        private let maxAge: TimeInterval = 600

        func set(_ wallet: StoredWallet) {
            lock.lock(); defer { lock.unlock() }
            value = (wallet, Date())
        }

        /// Returns and CONSUMES the seed if within the freshness window; otherwise drops it and returns
        /// nil so the caller decrypts as usual. Single-use: the first first-init read takes it.
        func consumeIfFresh() -> StoredWallet? {
            lock.lock(); defer { lock.unlock() }
            guard let primed = value else { return nil }
            value = nil
            return Date().timeIntervalSince(primed.primedAt) < maxAge ? primed.wallet : nil
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            value = nil
        }
    }

    init(secItem: SecItemClient, secureEnclave: SecureEnclaveClient? = nil) {
        self.secItem = secItem
        self.secureEnclave = secureEnclave
    }

    /// FALLBACK reason for the Secure-Enclave seed-read prompt when a caller passes no per-action reason
    /// (first init / background shielding). User-facing seed accesses thread a context reason via
    /// `exportWallet(reason:)` — see `AuthenticationContext` — so the prompt says what the access is for.
    private var seedAuthenticationReason: String {
#if os(macOS)
        // macOS composes the prompt as "{app} is trying to {reason}", so the reason must be a verb
        // phrase; reuse the localized macOS reason ("unlock your wallet"). iOS keeps its sentence.
        String(localizable: .localAuthenticationReasonMac)
#else
        "Authenticate to access your Zodl wallet"
#endif
    }

    func importWallet(
        bip39 phrase: String,
        birthday: BlockHeight?,
        language: MnemonicLanguageType = .english,
        hasUserPassedPhraseBackupTest: Bool = false
    ) throws {
        try ensureRelocated()
        // Future-proof of the bundle to potentially avoid migration. We enforce english mnemonic.
        guard language == .english else {
            throw WalletStorageError.unsupportedLanguage(language)
        }

        let wallet = StoredWallet(
            language: language,
            seedPhrase: SeedPhrase(phrase),
            version: Constants.zcashKeychainVersion,
            birthday: Birthday(birthday),
            hasUserPassedPhraseBackupTest: hasUserPassedPhraseBackupTest
        )

        do {
            if let secureEnclave {
                try storeWalletSecurely(wallet, secureEnclave: secureEnclave)
                // Reuse the just-supplied seed across the first-init burst (no re-decrypt → no prompts).
                setPrimedSeed(wallet)
            } else {
                guard let data = try encode(object: wallet) else {
                    throw KeychainError.encoding
                }

                try setData(data, forKey: Constants.zcashStoredWallet)
            }
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch let error as WalletStorageError {
            throw error
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    /// macOS: encrypt the seed with the Secure Enclave key (public-key ECIES — no prompt) and store the
    /// ciphertext, plus the non-secret metadata as a separate plaintext item.
    private func storeWalletSecurely(_ wallet: StoredWallet, secureEnclave: SecureEnclaveClient) throws {
        guard secureEnclave.isAvailable() else {
            throw WalletStorageError.secureEnclaveUnavailable
        }
        let cipher = try secureEnclave.encryptSeed(Data(wallet.seedPhrase.value().utf8))
        try setData(cipher, forKey: Constants.zcashStoredWalletSeed)

        guard let metaData = try encode(object: wallet.metadata) else {
            throw KeychainError.encoding
        }
        try setData(metaData, forKey: Constants.zcashStoredWalletMeta)
    }

    private func setPrimedSeed(_ wallet: StoredWallet) {
        primedSeedBox.set(wallet)
    }

    private func consumePrimedSeed() -> StoredWallet? {
        primedSeedBox.consumeIfFresh()
    }

    func clearPrimedSeed() {
        primedSeedBox.clear()
    }

    /// Returns the full wallet INCLUDING the seed. On macOS this decrypts the Secure-Enclave-wrapped
    /// seed and therefore triggers the OS auth prompt — call only when the seed is genuinely needed
    /// (spend / export / first init). For birthday / backup-flag / existence use `exportWalletMetadata`
    /// / `areKeysPresent`, which never decrypt.
    func exportWallet(reason: String? = nil) async throws -> StoredWallet {
        try ensureRelocated()
        // Restore/create primed the seed — reuse it once instead of an SE decrypt (and its prompt).
        if secureEnclave != nil, let primed = consumePrimedSeed() {
            return primed
        }
        if let secureEnclave {
            return try await exportWalletSecurely(secureEnclave: secureEnclave, reason: reason)
        }
        return try loadPlaintextWallet()
    }

    private func exportWalletSecurely(secureEnclave: SecureEnclaveClient, reason: String?) async throws -> StoredWallet {
        let meta = try exportWalletMetadata()
        guard meta.version == Constants.zcashKeychainVersion else {
            throw WalletStorageError.unsupportedVersion(meta.version)
        }

        let cipher: Data?
        do {
            cipher = try data(forKey: Constants.zcashStoredWalletSeed)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        }
        guard let cipher else {
            throw WalletStorageError.uninitializedWallet
        }

        let seedData = try await secureEnclave.decryptSeed(cipher, reason ?? seedAuthenticationReason)
        guard let seedPhrase = String(data: seedData, encoding: .utf8) else {
            throw WalletStorageError.uninitializedWallet
        }

        return StoredWallet(
            language: .english,
            seedPhrase: SeedPhrase(seedPhrase),
            version: meta.version,
            birthday: meta.birthday,
            hasUserPassedPhraseBackupTest: meta.hasUserPassedPhraseBackupTest
        )
    }

    /// iOS / no-Secure-Enclave: read the single plaintext `StoredWallet` blob (legacy path, unchanged).
    private func loadPlaintextWallet() throws -> StoredWallet {
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredWallet)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        } catch {
            throw error
        }

        guard let reqData else {
            throw WalletStorageError.uninitializedWallet
        }

        guard let wallet = try decode(json: reqData, as: StoredWallet.self) else {
            throw WalletStorageError.uninitializedWallet
        }

        guard wallet.version == Constants.zcashKeychainVersion else {
            throw WalletStorageError.unsupportedVersion(wallet.version)
        }

        return wallet
    }

    /// Reads the non-secret wallet metadata WITHOUT decrypting the seed (no biometric prompt). On macOS
    /// this is the separate plaintext item; on iOS it is projected from the single blob.
    func exportWalletMetadata() throws -> WalletMetadata {
        try ensureRelocated()
        let reqData: Data?

        if secureEnclave != nil {
            do {
                reqData = try data(forKey: Constants.zcashStoredWalletMeta)
            } catch KeychainError.noDataFound {
                throw WalletStorageError.uninitializedWallet
            }
            guard let reqData, let meta = try decode(json: reqData, as: WalletMetadata.self) else {
                throw WalletStorageError.uninitializedWallet
            }
            return meta
        }

        return try loadPlaintextWallet().metadata
    }

    func areKeysPresent() throws -> Bool {
        try ensureRelocated()
        let key = secureEnclave != nil ? Constants.zcashStoredWalletSeed : Constants.zcashStoredWallet
        let present = itemExists(forKey: key)
        return present
    }

    /// Whether the seed can be stored securely on this device. macOS requires a Secure Enclave and has
    /// no plaintext fallback, so creation/restore on a Mac without one (pre-T2 Intel) would hard-error;
    /// callers can use this to surface a clear message instead. Always `true` on iOS and on Macs with a
    /// Secure Enclave (Apple silicon, T2 Intel).
    func isSecureStorageAvailable() -> Bool {
        secureEnclave?.isAvailable() ?? true
    }

    func updateBirthday(_ height: BlockHeight) throws {
        try ensureRelocated()
        if secureEnclave != nil {
            var meta = try exportWalletMetadata()
            meta.birthday = Birthday(height)
            guard let data = try encode(object: meta) else {
                throw KeychainError.encoding
            }
            try updateData(data, forKey: Constants.zcashStoredWalletMeta)
        } else {
            var wallet = try loadPlaintextWallet()
            wallet.birthday = Birthday(height)
            guard let data = try encode(object: wallet) else {
                throw KeychainError.encoding
            }
            try updateData(data, forKey: Constants.zcashStoredWallet)
        }
    }

    func markUserPassedPhraseBackupTest(_ flag: Bool = true) throws {
        try ensureRelocated()
        if secureEnclave != nil {
            var meta = try exportWalletMetadata()
            meta.hasUserPassedPhraseBackupTest = flag
            guard let data = try encode(object: meta) else {
                throw KeychainError.encoding
            }
            try updateData(data, forKey: Constants.zcashStoredWalletMeta)
        } else {
            var wallet = try loadPlaintextWallet()
            wallet.hasUserPassedPhraseBackupTest = flag
            guard let data = try encode(object: wallet) else {
                throw KeychainError.encoding
            }
            try updateData(data, forKey: Constants.zcashStoredWallet)
        }
    }

    // MARK: - Secure Enclave migration (macOS)

    /// One-time, crash-safe migration of a legacy plaintext seed into the Secure Enclave: read the old
    /// plaintext item, re-store the seed as enclave ciphertext + plaintext metadata, VERIFY the enclave
    /// copy is readable (one biometric prompt) and only then delete the plaintext. Safe to call on every
    /// launch — no-op on iOS, and an auth-free version check short-circuits once migrated. So existing
    /// testers upgrade invisibly instead of landing on onboarding. See docs/macos/KEYCHAIN_SE_HARDENING.md.
    func migrateToSecureEnclaveIfNeeded() async throws {
        try ensureRelocated()
        guard let secureEnclave, secureEnclave.isAvailable() else {
            return
        }
        let version = storageVersion()
        if version >= Constants.zcashStorageVersionSecureEnclave {
            return
        }

        let seedItemExists = itemExists(forKey: Constants.zcashStoredWalletSeed)
        let plaintextExists = itemExists(forKey: Constants.zcashStoredWallet)

        // Already SE-wrapped (fresh install, or a prior run that wrote the ciphertext but crashed before
        // clearing the plaintext): verify the enclave copy, then make sure no plaintext lingers.
        if seedItemExists {
            // Verify + drop any lingering plaintext from a prior crashed run; otherwise just stamp.
            if plaintextExists {
                _ = try await exportWallet()
                try? deleteData(forKey: Constants.zcashStoredWallet)
            }
            try setStorageVersion(Constants.zcashStorageVersionSecureEnclave)
            return
        }

        // Nothing SE-wrapped yet: migrate the plaintext seed if there is one.
        guard
            plaintextExists,
            let oldData = try? data(forKey: Constants.zcashStoredWallet),
            let wallet = try? decode(json: oldData, as: StoredWallet.self)
        else {
            return
        }

        try storeWalletSecurely(wallet, secureEnclave: secureEnclave)   // encrypt + write (no prompt)
        _ = try await exportWallet()                                    // verify the enclave copy (prompt)
        try? deleteData(forKey: Constants.zcashStoredWallet)            // verified → drop the plaintext
        try setStorageVersion(Constants.zcashStorageVersionSecureEnclave)
    }

    private func storageVersion() -> Int {
        guard
            let data = try? data(forKey: Constants.zcashStorageVersion),
            let version = try? decode(json: data, as: Int.self)
        else { return 0 }
        return version
    }

    private func setStorageVersion(_ version: Int) throws {
        guard let data = try encode(object: version) else { throw KeychainError.encoding }
        do {
            try setData(data, forKey: Constants.zcashStorageVersion)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStorageVersion)
        }
    }

    /// Deliberately NOT gated on `ensureRelocated()`: reset is the escape hatch out of a failed
    /// relocation. It only deletes (deletes are never ACL-gated) and wipes BOTH keychains on macOS.
    func resetZashi() throws {
        clearPrimedSeed()
        try? deleteData(forKey: Constants.zcashStorageVersion)
        try? deleteData(forKey: Constants.zcashStoredWalletSeed)
        try? deleteData(forKey: Constants.zcashStoredWalletMeta)
        try? secureEnclave?.deleteKey()
        try deleteData(forKey: Constants.zcashStoredWallet)
        try? deleteData(forKey: Constants.zcashStoredAdressBookEncryptionKeys)
        try? deleteData(forKey: "\(Constants.zcashStoredUserMetadataEncryptionKeys)_zashi")
        try? deleteData(forKey: "\(Constants.zcashStoredUserMetadataEncryptionKeys)_keystone")
        try? deleteData(forKey: Constants.zcashStoredWalletBackupReminder)
        try? deleteData(forKey: "\(Constants.zcashStoredShieldingReminder)_zashi")
        try? deleteData(forKey: "\(Constants.zcashStoredShieldingReminder)_keystone")
        try? deleteData(forKey: Constants.zcashStoredWalletBackupAcknowledged)
        try? deleteData(forKey: Constants.zcashStoredShieldingAcknowledged)
        try? deleteData(forKey: Constants.zcashStoredTorSetupFlag)
        try? deleteData(forKey: Constants.zcashStoredZodlAnnouncementFlag)
        // Voting hotkeys are stored per-account under
        // "<zcashStoredVotingHotkey>_<accountUUIDHex>". Enumerate every such
        // entry and wipe it, so no per-account mnemonic survives a wallet
        // reset. Also remove the bare and empty-tagged keys for users
        // upgrading from earlier builds that stored under those names.
        for key in keychainKeys(withPrefix: "\(Constants.zcashStoredVotingHotkey)_") {
            try? deleteData(forKey: key)
        }
        try? deleteData(forKey: Constants.zcashStoredVotingHotkey)
        sweepLegacyFileKeychainItems()
        resetRelocationGate()
    }
    
    func importAddressBookEncryptionKeys(_ keys: AddressBookEncryptionKeys) throws {
        try ensureRelocated()
        do {
            guard let data = try encode(object: keys) else {
                throw KeychainError.encoding
            }
            
            try setData(data, forKey: Constants.zcashStoredAdressBookEncryptionKeys)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportAddressBookEncryptionKeys() throws -> AddressBookEncryptionKeys {
        try ensureRelocated()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredAdressBookEncryptionKeys)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedAddressBookEncryptionKeys
        } catch {
            throw error
        }
        
        guard let reqData else {
            throw WalletStorageError.uninitializedAddressBookEncryptionKeys
        }
        
        guard let wallet = try decode(json: reqData, as: AddressBookEncryptionKeys.self) else {
            throw WalletStorageError.uninitializedAddressBookEncryptionKeys
        }

        return wallet
    }
    
    func importUserMetadataEncryptionKeys(_ keys: UserMetadataEncryptionKeys, account: Account) throws {
        try ensureRelocated()
        do {
            guard let data = try encode(object: keys) else {
                throw KeychainError.encoding
            }
            
            try setData(data, forKey: Constants.accountMetadataFilename(account: account))
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportUserMetadataEncryptionKeys(account: Account) throws -> UserMetadataEncryptionKeys {
        try ensureRelocated()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.accountMetadataFilename(account: account))
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedUserMetadataEncryptionKeys
        } catch {
            throw error
        }
        
        guard let reqData else {
            throw WalletStorageError.uninitializedUserMetadataEncryptionKeys
        }
        
        guard let wallet = try decode(json: reqData, as: UserMetadataEncryptionKeys.self) else {
            throw WalletStorageError.uninitializedUserMetadataEncryptionKeys
        }

        return wallet
    }
    
    func clearEncryptionKeys(_ account: Account) throws {
        try ensureRelocated()
        try deleteData(forKey: Constants.accountMetadataFilename(account: account))
    }
    
    // MARK: - Remind Me
    
    func importWalletBackupReminder(_ reminder: ReminedMeTimestamp) throws {
        try ensureRelocated()
        guard let data = try? encode(object: reminder) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredWalletBackupReminder)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredWalletBackupReminder)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportWalletBackupReminder() -> ReminedMeTimestamp? {
        ensureRelocatedBestEffort()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredWalletBackupReminder)
        } catch {
            return nil
        }
        
        guard let reqData else {
            return nil
        }
        
        return try? decode(json: reqData, as: ReminedMeTimestamp.self)
    }

    func importShieldingReminder(_ reminder: ReminedMeTimestamp, accountName: String) throws {
        try ensureRelocated()
        guard let data = try? encode(object: reminder) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportShieldingReminder(accountName: String) -> ReminedMeTimestamp? {
        ensureRelocatedBestEffort()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))
        } catch {
            return nil
        }
        
        guard let reqData else {
            return nil
        }
        
        return try? decode(json: reqData, as: ReminedMeTimestamp.self)
    }
    
    func resetShieldingReminder(accountName: String) {
        ensureRelocatedBestEffort()
        try? deleteData(forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))

    }
    
    // MARK: - Acknowledged flags
    
    func importWalletBackupAcknowledged(_ acknowledged: Bool) throws {
        try ensureRelocated()
        guard let data = try? encode(object: acknowledged) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredWalletBackupAcknowledged)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredWalletBackupAcknowledged)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportWalletBackupAcknowledged() -> Bool {
        ensureRelocatedBestEffort()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredWalletBackupAcknowledged)
        } catch {
            return false
        }
        
        guard let reqData else {
            return false
        }
        
        return (try? decode(json: reqData, as: Bool.self)) ?? false
    }
    
    func importShieldingAcknowledged(_ acknowledged: Bool) throws {
        try ensureRelocated()
        guard let data = try? encode(object: acknowledged) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredShieldingAcknowledged)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredShieldingAcknowledged)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportShieldingAcknowledged() -> Bool {
        ensureRelocatedBestEffort()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredShieldingAcknowledged)
        } catch {
            return false
        }
        
        guard let reqData else {
            return false
        }
        
        return (try? decode(json: reqData, as: Bool.self)) ?? false
    }

    func importTorSetupFlag(_ enabled: Bool) throws {
        try ensureRelocated()
        guard let data = try? encode(object: enabled) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredTorSetupFlag)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredTorSetupFlag)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportTorSetupFlag() -> Bool? {
        ensureRelocatedBestEffort()
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredTorSetupFlag)
        } catch {
            return nil
        }
        
        guard let reqData else {
            return nil
        }
        
        return try? decode(json: reqData, as: Bool.self)
    }

    func importIronwoodAnnouncementFlag(_ enabled: Bool) throws {
        guard let data = try? encode(object: enabled) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredIronwoodAnnouncementFlag)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredIronwoodAnnouncementFlag)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    func exportIronwoodAnnouncementFlag() -> Bool? {
        let reqData: Data?

        do {
            reqData = try data(forKey: Constants.zcashStoredIronwoodAnnouncementFlag)
        } catch {
            return nil
        }

        guard let reqData else {
            return nil
        }

        return try? decode(json: reqData, as: Bool.self)
    }

    // MARK: - Voting Hotkey

    func importVotingHotkey(_ phrase: String, accountId: AccountUUID) throws {
        try ensureRelocated()
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
        try ensureRelocated()
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

    // MARK: - Wallet Storage Codable & Query helpers
    
    func decode<T: Decodable>(json: Data, as clazz: T.Type) throws -> T? {
        do {
            let decoder = JSONDecoder()
            let data = try decoder.decode(T.self, from: json)
            return data
        } catch {
            throw KeychainError.decoding
        }
    }

    func encode<T: Codable>(object: T) throws -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(object)
        } catch {
            throw KeychainError.encoding
        }
    }
    
    func baseQuery(forAccount account: String = "", andKey forKey: String) -> [String: Any] {
        var query: [String: AnyObject] = [
            /// Uniquely identify this keychain accessor
            kSecAttrService as String: (zcashStoredWalletPrefix + forKey) as AnyObject,
            kSecAttrAccount as String: account as AnyObject,
            kSecClass as String: kSecClassGenericPassword,
            /// The data in the keychain item can be accessed only while the device is unlocked by the user.
            /// This is recommended for items that need to be accessible only while the application is in the foreground.
            /// Items with this attribute do not migrate to a new device.
            /// Thus, after restoring from a backup of a different device, these items will not be present.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true as AnyObject
        }

        return query
    }

    /// Query for MATCHING an existing item to mutate (delete / update). Deliberately omits BOTH
    /// `kSecAttrAccessible` AND — for the single-instance items (empty `account`) — `kSecAttrAccount`,
    /// unlike `baseQuery`.
    ///
    /// Two distinct macOS file (login) keychain quirks made `SecItemDelete` / `SecItemUpdate` silently
    /// match nothing while `SecItemCopyMatching` tolerated the very same query — so `deleteData` /
    /// `updateData` no-op'd, items survived a `resetZashi()`, and the wallet ended up half-wiped and
    /// stuck at launch ("Keychain keys are still present"):
    ///   1. Including the accessibility constant in the mutate query → no match. (Fixed earlier.)
    ///   2. An item ADDED with `kSecAttrAccount: ""` persists with a NULL account, and a mutate query
    ///      carrying account "" then matches that NULL-account item on NOTHING — even though copy-match
    ///      with the same "" still finds it. (This is what kept the SE-wrapped seed undeletable; proven
    ///      on a stuck wallet — `security delete-generic-password -s zcashStoredWalletSeed`, matching by
    ///      service alone, removed exactly the item the app's `account: ""` delete couldn't.)
    /// The single-instance items (seed / meta / version / wallet) use account "" and are uniquely
    /// identified by service alone, so we match by service for them; per-account items pass a real
    /// account and keep it. Neither omission affects correctness on iOS. See
    /// docs/macos/KEYCHAIN_SE_HARDENING.md.
    func mutationQuery(forAccount account: String = "", andKey forKey: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecAttrService as String: zcashStoredWalletPrefix + forKey,
            kSecClass as String: kSecClassGenericPassword
        ]
        if !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func restoreQuery(forAccount account: String = "", andKey forKey: String) -> [String: Any] {
        var query = baseQuery(forAccount: account, andKey: forKey)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnRef as String] = kCFBooleanFalse
        query[kSecReturnPersistentRef as String] = kCFBooleanFalse
        query[kSecReturnAttributes as String] = kCFBooleanFalse

        return query
    }

    /// Returns every keychain key (with the `zcashStoredWalletPrefix` stripped)
    /// whose service starts with the given prefix. Used by `resetZashi` to wipe
    /// per-account items whose suffixes aren't known statically.
    func keychainKeys(withPrefix keyPrefix: String) -> [String] {
        let fullPrefix = zcashStoredWalletPrefix + keyPrefix
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        var result: AnyObject?
        let status = secItem.copyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { attrs in
            guard let service = attrs[kSecAttrService as String] as? String,
                  service.hasPrefix(fullPrefix) else {
                return nil
            }
            return String(service.dropFirst(zcashStoredWalletPrefix.count))
        }
    }

    /// Whether a keychain item exists for `forKey`, WITHOUT returning (or, for an SE-wrapped seed,
    /// decrypting) its data — so an existence check never triggers a biometric prompt.
    func itemExists(forKey: String, account: String = "") -> Bool {
        var query = baseQuery(forAccount: account, andKey: forKey)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanFalse as Any

        var result: AnyObject?
        return secItem.copyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Restore data for key
    func data(
        forKey: String,
        account: String = ""
    ) throws -> Data? {
        let query = restoreQuery(forAccount: account, andKey: forKey)

        var result: AnyObject?
        let status = secItem.copyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.noDataFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
        
        return result as? Data
    }
    
    /// Use carefully:  Deletes data for key
    func deleteData(
        forKey: String,
        account: String = ""
    ) throws {
        let query = mutationQuery(forAccount: account, andKey: forKey)

        let status = secItem.delete(query as CFDictionary)

        // If the item is not present, the goal of the function is fulfilled => no error
        if status == errSecItemNotFound {
            return
        }

        guard status == noErr else {
            throw KeychainError.unknown(status)
        }
    }
    
    /// Store data for key
    func setData(
        _ data: Data,
        forKey: String,
        account: String = ""
    ) throws {
        var query = baseQuery(forAccount: account, andKey: forKey)
        query[kSecValueData as String] = data as AnyObject

        var result: AnyObject?
        let status = secItem.add(query as CFDictionary, &result)
        
        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicate
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }

    /// Use carefully:  Update data for key
    func updateData(
        _ data: Data,
        forKey: String,
        account: String = ""
    ) throws {
        let query = mutationQuery(forAccount: account, andKey: forKey)

        let attributes: [String: AnyObject] = [
            kSecValueData as String: data as AnyObject
        ]

        let status = secItem.update(query as CFDictionary, attributes as CFDictionary)
        
        guard status != errSecItemNotFound else {
            throw KeychainError.noDataFound
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }
}
