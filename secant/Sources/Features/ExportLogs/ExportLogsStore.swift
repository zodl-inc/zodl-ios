//
//  ExportLogsStore.swift
//  secant
//
//  Created by Michal Fousek on 06.03.2023.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct ExportLogs {
    @ObservableState
    struct State: Equatable {
        @Presents var alert: AlertState<Action>?
        var exportLogsDisabled = false
        var isSharingLogs = false
        var zippedLogsURLs: [URL] = []
        
        init(
            exportLogsDisabled: Bool = false,
            isSharingLogs: Bool = false,
            zippedLogsURLs: [URL] = []
        ) {
            self.exportLogsDisabled = exportLogsDisabled
            self.isSharingLogs = isSharingLogs
            self.zippedLogsURLs = zippedLogsURLs
        }
    }

    enum Action: Equatable {
        case alert(PresentationAction<Action>)
        case start
        case finished(URL?)
        case failed(ZcashError)
        case shareFinished
    }

    @Dependency(\.logsHandler) var logsHandler

    init() {}
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none

            case .start:
                state.exportLogsDisabled = true
                return .run { send in
                    do {
                        let zippedLogsURL = try await logsHandler.exportAndStoreLogs(
                            LoggerConstants.sdkLogs,
                            LoggerConstants.tcaLogs,
                            LoggerConstants.walletLogs
                        )
                        await send(.finished(zippedLogsURL))
                    } catch {
                        await send(.failed(error.toZcashError()))
                    }
                }

            case .finished(let zippedLogsURL):
                if let zippedLogsURL {
                    state.zippedLogsURLs = [zippedLogsURL]
                }
                state.exportLogsDisabled = false
                state.isSharingLogs = true
                return .none

            case let .failed(error):
                state.exportLogsDisabled = false
                state.isSharingLogs = false
                state.alert = AlertState.failed(error)
                return .none

            case .shareFinished:
                state.isSharingLogs = false
                return .none
            }
        }
    }
}
