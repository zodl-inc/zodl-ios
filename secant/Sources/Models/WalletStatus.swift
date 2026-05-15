//
//  WalletStatus.swift
//  secant
//
//  Created by Lukáš Korba on 2026-04-10.
//


import SwiftUI
import ComposableArchitecture

enum WalletStatus: Equatable {
    case disconnected
    case none
    case restoring
    case resyncing

    var isNotReadyForFullySyncedOperation: Bool {
        self == .restoring || self == .resyncing
    }
    
    func text() -> String {
        switch self {
        case .restoring: return String(localizable: .walletStatusRestoringWallet)
        case .disconnected: return String(localizable: .walletStatusDisconnected)
        default: return ""
        }
    }
}
