//
//  ExportTransactionHistoryStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-13.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

@Reducer
struct ExportTransactionHistory {
    @ObservableState
    struct State: Equatable {
        var exportBinding = false
        var isExportingData = false
        var dataURL: URL = .emptyURL
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []

        var isExportPossible: Bool {
            !isExportingData
        }
        
        var accountName: String {
            selectedWalletAccount?.vendor.name() ?? ""
        }

        init() { }
    }
    
    enum Action: Equatable {
        case exportRequested
        case preparationOfUrlsFailed
        case shareFinished
        case urlsPrepared(URL)
    }

    init() { }

    @Dependency(\.taxExporter) var taxExporter

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .exportRequested:
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                state.isExportingData = true
                let accountName = account.vendor.name()
                do {
                    let url = try taxExporter.cointrackerCSVfor(state.transactions.elements, accountName)
                    return .send(.urlsPrepared(url))
                } catch {
                    return .send(.preparationOfUrlsFailed)
                }

            case .preparationOfUrlsFailed:
                state.isExportingData = false
                return .none
                
            case .urlsPrepared(let url):
                state.dataURL = url
                state.exportBinding = true
                return .none

            case .shareFinished:
                state.isExportingData = false
                state.exportBinding = false
                return .none
            }
        }
    }
}
