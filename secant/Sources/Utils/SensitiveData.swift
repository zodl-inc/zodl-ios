//
//  SensitiveData.swift
//  secantTests
//
//  Created by Lukáš Korba on 06.02.2023.
//

import Foundation
@preconcurrency import ZcashLightClientKit

// MARK: - Redactable Protocol

/// `Undescribable` comes from the SDK and it is a reliable and tested protocol ensuring custom
/// destriptions and dumps never print outs the exact value but `--redacted--` instead.
/// `Redactable` protocol is just a helper so we can let developers to see the sensitive data when
/// developing and debugging but production or release builds (even testflight) are set to redacted by default.
#if DEBUG
protocol Redactable { }
#else
protocol Redactable: Undescribable { }
#endif

// MARK: - Redactable Seed Phrase

/// Read-only redacted holder for a seed phrase.
struct SeedPhrase: Codable, Equatable, Redactable {
    private let seedPhrase: String

    init(_ seedPhrase: String) {
        self.seedPhrase = seedPhrase
    }
    
    /// This method returns seed phrase, all 24 words with no protection or support of `Redactable` protocol.
    /// Use it wisely and never log outcome of this method or share with anybody.
    func value() -> String {
        seedPhrase
    }
}

// MARK: - Redactable Birthday

/// Read-only redacted holder for a birthday.
struct Birthday: Codable, Equatable, Redactable {
    private let birthday: BlockHeight?

    init(_ birthday: BlockHeight?) {
        self.birthday = birthday
    }

    /// This method returns birthday with no protection or support of `Redactable` protocol.
    /// Use it wisely and never log outcome of this method or share with anybody.
    func value() -> BlockHeight? {
        birthday
    }
}

// MARK: - Redactable String

/// Redactable holder for a string.
struct RedactableString: Equatable, Hashable, Redactable {
    let data: String
    
    init(_ data: String = "") { self.data = data }
    
    static var empty = "".redacted
}

/// Utility that converts a string to a redacted counterpart.
extension String {
    var redacted: RedactableString { RedactableString(self) }
}

// MARK: - Redactable BlockHeight

/// Redactable holder for a block height.
struct RedactableBlockHeight: Equatable, Redactable {
    let data: BlockHeight

    init(_ data: BlockHeight = -1) { self.data = data }
}

/// Utility that converts a block height to a redacted counterpart.
extension BlockHeight {
    var redacted: RedactableBlockHeight { RedactableBlockHeight(self) }
}

// MARK: - Redactable AccountBalance

/// Redactable holder for a block height.
struct RedactableAccountBalance: Equatable, Redactable {
    let data: AccountBalance?

    init(_ data: AccountBalance? = nil) { self.data = data }
}

/// Utility that converts a block height to a redacted counterpart.
extension AccountBalance {
    var redacted: RedactableAccountBalance? { RedactableAccountBalance(self) }
}

// MARK: - Redactable SynchronizerState

/// Redactable holder for a block height.
struct RedactableSynchronizerState: Equatable, Redactable {
    struct SynchronizerStateWrapper: Equatable {
        var syncSessionID: UUID
        var accountsBalances: [AccountUUID: AccountBalance]
        var syncStatus: SyncStatus
        var latestBlockHeight: BlockHeight
    }

    let data: SynchronizerStateWrapper

    init(_ data: SynchronizerState) {
        self.data = SynchronizerStateWrapper(
            syncSessionID: data.syncSessionID,
            accountsBalances: data.accountsBalances,
            syncStatus: data.syncStatus,
            latestBlockHeight: data.latestBlockHeight
        )
    }
}

/// Utility that converts a block height to a redacted counterpart.
extension SynchronizerState {
    var redacted: RedactableSynchronizerState {
        RedactableSynchronizerState(self)
    }
}

// MARK: - Redactable Int64

/// Redactable holder for an Int64.
struct RedactableInt64: Equatable, Redactable {
    let data: Int64

    init(_ data: Int64 = -1) { self.data = data }
}

/// Utility that converts a block height to a redacted counterpart.
extension Int64 {
    var redacted: RedactableInt64 { RedactableInt64(self) }
}
