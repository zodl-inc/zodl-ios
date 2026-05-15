//
//  TaxExporterInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-13.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var taxExporter: TaxExporterClient {
        get { self[TaxExporterClient.self] }
        set { self[TaxExporterClient.self] = newValue }
    }
}

@DependencyClient
struct TaxExporterClient {
    var cointrackerCSVfor: @Sendable ([TransactionState], String) throws -> URL
}
