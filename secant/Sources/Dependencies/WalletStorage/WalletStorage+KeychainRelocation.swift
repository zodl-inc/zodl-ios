//
//  WalletStorage+KeychainRelocation.swift
//  Zashi
//
//  MOB-1485: one-time relocation of every ZODL keychain item from the legacy file-based login
//  keychain into the Data Protection keychain (macOS only). The login keychain gates each item
//  behind a code-signature ACL, so differently-signed builds (Xcode vs Developer ID vs
//  TestFlight) threw password dialogs at launch; the DP keychain authorizes silently from the
//  code signature. See docs/macos/KEYCHAIN_SE_HARDENING.md, "Data Protection keychain relocation".
//
//  PLATFORM RULE (learned the hard way, verified via secd's log on a real Mac): on macOS,
//  SecItem calls WITHOUT `kSecUseDataProtectionKeychain` are NOT scoped to the file keychain —
//  SecItemCopyMatching sees, and SecItemDelete deletes, Data Protection items too. Every
//  file-keychain operation here therefore goes through the `fileKeychain*` client primitives,
//  which the live client scopes via `SecKeychainItemRef`. An unscoped call would re-discover the
//  app's own DP items as "legacy leftovers" and the delete-the-original step would destroy the
//  freshly relocated DP copy — the wallet would vanish on every relaunch.
//

import Foundation
import Security
import os

/// Once-per-process outcome of the keychain relocation.
enum KeychainRelocationState: Equatable, Sendable {
    case notStarted
    case done
    case failed(OSStatus)
}

/// Outcome of the file-keychain discovery scan.
enum LegacyScanOutcome: Equatable {
    case found([WalletStorage.LegacyItem])
    case failed(OSStatus)
}

extension WalletStorage {
    /// A ZODL-owned item still sitting in the file keychain.
    struct LegacyItem: Equatable, Comparable {
        let service: String
        let account: String
        /// The legacy engine's handle (`SecKeychainItemRef`) for THIS file-keychain item — the
        /// only way to read or delete exactly the file copy and never a same-named DP item.
        /// Excluded from equality/ordering: it is an opaque handle, not identity.
        let ref: CFTypeRef

        static func == (lhs: LegacyItem, rhs: LegacyItem) -> Bool {
            (lhs.service, lhs.account) == (rhs.service, rhs.account)
        }

        static func < (lhs: LegacyItem, rhs: LegacyItem) -> Bool {
            (lhs.service, lhs.account) < (rhs.service, rhs.account)
        }
    }

    /// Throwing relocation gate — the first statement of every throwing public accessor. After a
    /// failed relocation this keeps throwing `KeychainError.unknown(status)`, which Root's
    /// `walletInitializationState` maps to the OSStatusError screen: a denied relocation must
    /// never read as "no wallet", or a real wallet would be routed to onboarding.
    func ensureRelocated() throws {
        let outcome = relocationGate.withLock { state in
            if state == KeychainRelocationState.notStarted {
                state = runRelocation()
            }
            return state
        }
        if case .failed(let status) = outcome {
            throw KeychainError.unknown(status)
        }
    }

    /// Best-effort gate for the non-throwing convenience accessors (reminder/flag getters): on a
    /// failed relocation they degrade to their empty value. Safe, because every wallet-presence /
    /// seed / metadata path is throwing and a failed relocation parks the launch on the error
    /// screen before any of these matter.
    func ensureRelocatedBestEffort() {
        relocationGate.withLock { state in
            if state == KeychainRelocationState.notStarted {
                state = runRelocation()
            }
        }
    }

    /// Moves every ZODL item found in the file keychain into the DP keychain. Runs at most once
    /// per process, while holding the gate lock — concurrent first accessors simply wait, exactly
    /// as they used to wait on the login-keychain ACL prompts these same reads produced. Uses
    /// `secItem` primitives directly (never the public accessors), so it cannot re-enter the gate.
    private func runRelocation() -> KeychainRelocationState {
        guard useDataProtectionKeychain else {
            return KeychainRelocationState.done
        }
        let leftovers: [LegacyItem]
        switch legacyFileKeychainItems() {
        case .failed(let status):
            return KeychainRelocationState.failed(status)
        case .found(let items):
            leftovers = items
        }
        for item in leftovers {
            if let status = relocate(item) {
                return KeychainRelocationState.failed(status)
            }
        }
        return KeychainRelocationState.done
    }

    /// Attribute-only scan for FILE-keychain items whose service belongs to this ZODL flavor.
    /// Attribute reads are never ACL-gated, so this is promptless. The client primitive returns
    /// only genuinely file-backed items (each with its `SecKeychainItemRef`), so items already in
    /// the DP keychain can never be re-discovered here. Sorted for deterministic processing order.
    func legacyFileKeychainItems() -> LegacyScanOutcome {
        var result: CFTypeRef?
        let status = secItem.fileKeychainItems(&result)
        if status == errSecItemNotFound {
            return .found([])
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return .failed(status)
        }
        let owned = items.compactMap { attributes -> LegacyItem? in
            guard
                let service = attributes[kSecAttrService as String] as? String,
                isOwnedService(service),
                let ref = attributes[kSecValueRef as String]
            else { return nil }
            let account = attributes[kSecAttrAccount as String] as? String ?? ""
            return LegacyItem(service: service, account: account, ref: ref as CFTypeRef)
        }
        return .found(owned.sorted())
    }

    /// Whether a file-keychain service string belongs to THIS flavor of ZODL. The flavor prefix
    /// must match first (testnet items carry `testnet_`, mainnet items are bare), then the bare
    /// name must be one of our known items — exact names or the per-account `_`-suffixed families.
    /// Everything else (other apps, the other flavor) is foreign and must never be touched.
    func isOwnedService(_ service: String) -> Bool {
        guard service.hasPrefix(zcashStoredWalletPrefix) else { return false }
        let bare = String(service.dropFirst(zcashStoredWalletPrefix.count))
        let exactNames: Set<String> = [
            Constants.zcashStoredWallet,
            Constants.zcashStoredWalletSeed,
            Constants.zcashStoredWalletMeta,
            Constants.zcashStorageVersion,
            Constants.zcashStoredAdressBookEncryptionKeys,
            Constants.zcashStoredWalletBackupReminder,
            Constants.zcashStoredWalletBackupAcknowledged,
            Constants.zcashStoredShieldingAcknowledged,
            Constants.zcashStoredTorSetupFlag,
            Constants.zcashStoredZodlAnnouncementFlag,
            Constants.zcashStoredVotingHotkey
        ]
        if exactNames.contains(bare) {
            return true
        }
        let prefixFamilies = [
            "\(Constants.zcashStoredUserMetadataEncryptionKeys)_",
            "\(Constants.zcashStoredShieldingReminder)_",
            "\(Constants.zcashStoredVotingHotkey)_"
        ]
        return prefixFamilies.contains { bare.hasPrefix($0) }
    }

    /// Moves one item: read the file bytes → write into DP (file bytes win over a crashed run's
    /// duplicate) → read back and verify → only then delete the file original. Returns nil on
    /// success, the failing OSStatus otherwise. The file read and delete are pinned to the item's
    /// `SecKeychainItemRef` — a service-name query without the DP flag would also hit the DP copy
    /// this very function just wrote. The file data read is the only step a login-keychain ACL
    /// can gate — on cross-signature installs this is the one final prompt.
    private func relocate(_ item: LegacyItem) -> OSStatus? {
        var fileResult: CFTypeRef?
        let readStatus = secItem.fileKeychainReadData(item.ref, &fileResult)
        if readStatus == errSecItemNotFound {
            return nil
        }
        guard readStatus == errSecSuccess else {
            return readStatus
        }
        guard let payload = fileResult as? Data else {
            return errSecDecode
        }

        let addAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: payload
        ]
        var addResult: AnyObject?
        let addStatus = secItem.add(addAttributes as CFDictionary, &addResult)
        if addStatus == errSecDuplicateItem {
            var matchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecUseDataProtectionKeychain as String: true
            ]
            if !item.account.isEmpty {
                matchQuery[kSecAttrAccount as String] = item.account
            }
            let updateStatus = secItem.update(matchQuery as CFDictionary, [kSecValueData as String: payload] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                return updateStatus
            }
        } else if addStatus != errSecSuccess {
            return addStatus
        }

        var verifyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecUseDataProtectionKeychain as String: true
        ]
        if !item.account.isEmpty {
            verifyQuery[kSecAttrAccount as String] = item.account
        }
        var verifyResult: AnyObject?
        let verifyStatus = secItem.copyMatching(verifyQuery as CFDictionary, &verifyResult)
        guard verifyStatus == errSecSuccess else {
            return verifyStatus
        }
        guard let verified = verifyResult as? Data, verified == payload else {
            return errSecDecode
        }

        let deleteStatus = secItem.fileKeychainDeleteItem(item.ref)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return deleteStatus
        }
        return nil
    }

    /// macOS: after a reset wipes the DP keychain, also delete any of OUR items still sitting in
    /// the legacy FILE keychain (un-relocated / half-relocated / failed relocation states).
    /// Deletes go by `SecKeychainItemRef` (file-only, never read item data), so this is promptless
    /// and can never touch the DP keychain; foreign items are never touched. Best-effort by
    /// design — reset is the escape hatch and must not throw over legacy leftovers.
    func sweepLegacyFileKeychainItems() {
        guard useDataProtectionKeychain else { return }
        guard case .found(let leftovers) = legacyFileKeychainItems() else { return }
        for item in leftovers {
            _ = secItem.fileKeychainDeleteItem(item.ref)
        }
    }

    /// After a reset, a previously-failed relocation is stale: the sweep just emptied the file
    /// keychain of our items, so the next access must re-derive the gate from reality (trivially
    /// `done` after a successful sweep; a genuine retry if the scan could not run). Without this,
    /// the sticky failure would outlive the reset and Root's post-reset verification read would
    /// mis-report a successful wipe as an error.
    func resetRelocationGate() {
        relocationGate.withLock { state in
            state = KeychainRelocationState.notStarted
        }
    }
}
