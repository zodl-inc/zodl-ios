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

import Foundation
import Security

extension OSStatus: Error {}

/// Once-per-process outcome of the keychain relocation.
enum KeychainRelocationState: Equatable, Sendable {
    case notStarted
    case done
    case failed(OSStatus)
}

extension WalletStorage {
    /// A ZODL-owned item still sitting in the file keychain.
    struct LegacyItem: Equatable, Comparable {
        let service: String
        let account: String

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
        case .failure(let status):
            return KeychainRelocationState.failed(status)
        case .success(let items):
            leftovers = items
        }
        for item in leftovers {
            if let status = relocate(item) {
                return KeychainRelocationState.failed(status)
            }
        }
        return KeychainRelocationState.done
    }

    /// Attribute-only scan of the FILE keychain for items whose service belongs to this ZODL
    /// flavor. Attribute reads are never ACL-gated, so this is promptless. Sorted for
    /// deterministic processing order.
    func legacyFileKeychainItems() -> Result<[LegacyItem], OSStatus> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any
        ]
        var result: AnyObject?
        let status = secItem.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .success([])
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return .failure(status)
        }
        let owned = items.compactMap { attributes -> LegacyItem? in
            guard
                let service = attributes[kSecAttrService as String] as? String,
                isOwnedService(service)
            else { return nil }
            let account = attributes[kSecAttrAccount as String] as? String ?? ""
            return LegacyItem(service: service, account: account)
        }
        return .success(owned.sorted())
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

    /// Moves one item: read file bytes → write into DP (file bytes win over a crashed run's
    /// duplicate) → read back and verify → only then delete the file original. Returns nil on
    /// success, the failing OSStatus otherwise. The file data read is the only step a
    /// login-keychain ACL can gate — on cross-signature installs this is the one final prompt.
    private func relocate(_ item: LegacyItem) -> OSStatus? {
        var fileQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        if !item.account.isEmpty {
            fileQuery[kSecAttrAccount as String] = item.account
        }
        var fileResult: AnyObject?
        let readStatus = secItem.copyMatching(fileQuery as CFDictionary, &fileResult)
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

        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service
        ]
        if !item.account.isEmpty {
            deleteQuery[kSecAttrAccount as String] = item.account
        }
        let deleteStatus = secItem.delete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return deleteStatus
        }
        return nil
    }
}
