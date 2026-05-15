//
//  ExportLogs.swift
//
//
//  Created by Lukáš Korba on 06-20-2024.
//

import ComposableArchitecture

@preconcurrency import ZcashLightClientKit

// MARK: Alerts

extension AlertState where Action == ExportLogs.Action {
    static func failed(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .exportLogsAlertFailedTitle))
        } message: {
            TextState(String(localizable: .exportLogsAlertFailedMessage(error.detailedMessage)))
        }
    }
}

// MARK: Placeholders

extension ExportLogs.State {
    static var initial: Self {
        .init()
    }
}
