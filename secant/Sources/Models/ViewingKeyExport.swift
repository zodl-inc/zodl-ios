//
//  ViewingKeyExport.swift
//  Zodl
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum ViewingKeyKind: CaseIterable, Equatable, Sendable {
    case incoming
    case full
}

struct ViewingKeyMaterial: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let rawValue: String

    var description: String { "<redacted viewing key>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ViewingKeyPNG: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let data: Data

    var description: String { "<redacted viewing key PNG>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
    }

    init(data: Data) {
        self.data = data
    }
}

struct ViewingKeyExportSession: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: UUID
    let accountID: AccountUUID
    let vendor: WalletAccount.Vendor
    let network: NetworkType

    private let account: Account

    var description: String { "<redacted viewing key export session>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
    }

    init(id: UUID, account: WalletAccount, network: NetworkType) {
        self.id = id
        self.accountID = account.id
        self.vendor = account.vendor
        self.network = network
        self.account = account.account
    }

    func key(for kind: ViewingKeyKind) -> ViewingKeyMaterial? {
        switch kind {
        case .incoming:
            return account.uivk.map { ViewingKeyMaterial($0.stringEncoded) }
        case .full:
            return account.ufvk.map { ViewingKeyMaterial($0.stringEncoded) }
        }
    }

    func matches(account candidate: WalletAccount?, network candidateNetwork: NetworkType) -> Bool {
        guard let candidate else { return false }

        return network == candidateNetwork
            && accountID == candidate.id
            && vendor == candidate.vendor
            && hasSameSDKProvenance(as: candidate.account)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.network == rhs.network
            && lhs.accountID == rhs.accountID
            && lhs.vendor == rhs.vendor
            && lhs.hasSameSDKProvenance(as: rhs.account)
    }

    private func hasSameSDKProvenance(as candidate: Account) -> Bool {
        account.id == candidate.id
            && account.keySource == candidate.keySource
            && account.seedFingerprint == candidate.seedFingerprint
            && account.hdAccountIndex == candidate.hdAccountIndex
            && account.ufvk == candidate.ufvk
            && account.uivk == candidate.uivk
    }
}
