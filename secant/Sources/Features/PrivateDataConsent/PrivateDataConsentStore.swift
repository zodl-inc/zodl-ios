//
//  PrivateDataConsentStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.11.2023.
//

import Foundation
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

@Reducer
struct PrivateDataConsent {
    @ObservableState
    struct State: Equatable {
        var exportBinding: Bool
        var exportOnlyLogs = true
        var isAcknowledged: Bool = false
        var isExportingData: Bool
        var isExportingLogs: Bool
        var dataDbURL: [URL] = []
        var exportLogsState: ExportLogs.State
        
        var isExportPossible: Bool {
            !isExportingData && !isExportingLogs && isAcknowledged
        }

        var exportURLs: [URL] {
            exportOnlyLogs
            ? exportLogsState.zippedLogsURLs
            : dataDbURL + exportLogsState.zippedLogsURLs
        }
        
        init(
            dataDbURL: [URL],
            exportBinding: Bool,
            exportLogsState: ExportLogs.State,
            exportOnlyLogs: Bool = true,
            isAcknowledged: Bool = false,
            isExportingData: Bool = false,
            isExportingLogs: Bool = false
        ) {
            self.dataDbURL = dataDbURL
            self.exportBinding = exportBinding
            self.exportLogsState = exportLogsState
            self.exportOnlyLogs = exportOnlyLogs
            self.isAcknowledged = isAcknowledged
            self.isExportingData = isExportingData
            self.isExportingLogs = isExportingLogs
        }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<PrivateDataConsent.State>)
        case exportLogs(ExportLogs.Action)
        case exportLogsRequested
        case exportRequested
        case onAppear
        case shareFinished
    }

    init() { }

    @Dependency(\.databaseFiles) var databaseFiles
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    var body: some Reducer<State, Action> {
        BindingReducer()

        Scope(state: \.exportLogsState, action: \.exportLogs) {
            ExportLogs()
        }
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.dataDbURL = [databaseFiles.dataDbURLFor(zcashSDKEnvironment.network())]
                return .none

            case .exportLogs(.finished):
                state.exportBinding = true
                return .none
                
            case .exportLogs:
                return .none

            case .exportLogsRequested:
                state.isExportingLogs = true
                state.exportOnlyLogs = true
                return .send(.exportLogs(.start))

            case .exportRequested:
                state.exportOnlyLogs = false
#if os(macOS)
                // macOS: the private-data export is the wallet's data.db ONLY — logs are intentionally
                // excluded. The OSLog export is pathologically slow / blocked under the macOS sandbox and
                // left the spinner hanging forever. `dataDbURL` is already resolved in `.onAppear`, so just
                // trigger the share directly; with no logs, `exportURLs` is the single data.db file and the
                // content-aware share opens a native Save panel for it. iOS keeps data.db + logs (below).
                state.exportBinding = true
                return .none
#else
                state.isExportingData = true
                return .send(.exportLogs(.start))
#endif
                
            case .shareFinished:
                state.isExportingData = false
                state.isExportingLogs = false
                state.exportBinding = false
                return .none
                
            case .binding:
                return .none
            }
        }
    }
}
