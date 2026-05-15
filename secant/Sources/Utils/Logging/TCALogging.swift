//
//  TCALogging.swift
//  Zashi
//
//  Created by Lukáš Korba on 23.01.2023.
//

import Foundation
import os
@preconcurrency import ZcashLightClientKit

extension OSLogger {
    static let live = OSLogger(logLevel: .debug, category: LoggerConstants.tcaLogs)

    func tcaDebug(_ message: String) {
        guard let oslog else { return }

        #if DEBUG
        os_log(
            "%{public}@",
            log: oslog,
            type: .default,
            message
        )
        #endif
    }
}
