//
//  TaxExporterLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-13.
//

import Foundation
import ComposableArchitecture
import UIKit

extension TaxExporterClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            cointrackerCSVfor: {
                let calendar = Calendar(identifier: .gregorian)

                let thisYear = calendar.component(.year, from: Date())
                let prevYear = thisYear - 1

                // export previous year
                let transactionsToExport = $0.compactMap { transaction -> TransactionState? in
                    guard let timestamp = transaction.timestamp else {
                        return nil
                    }

                    let date = Date(timeIntervalSince1970: timestamp)

                    let year = calendar.component(.year, from: date)
                    return year == prevYear ? transaction : nil
                }.sorted { lhs, rhs in
                    guard let lhsTimeStamp = lhs.timestamp, let rhsTimeStamp = rhs.timestamp else {
                        return false
                    }

                    return lhsTimeStamp < rhsTimeStamp
                }

                var csvString = "Date,Received Quantity,Received Currency,Sent Quantity,Sent Currency,Fee Amount,Fee Currency,Tag\n"

                let formatter = DateFormatter()
                formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
                formatter.timeZone = TimeZone(abbreviation: "UTC") // Ensure UTC time

                transactionsToExport.forEach { transaction in
                    guard !transaction.isShieldingTransaction else {
                        return
                    }

                    guard let timestamp = transaction.timestamp else {
                        return
                    }

                    var row = ""

                    // Date
                    let date = Date(timeIntervalSince1970: timestamp)
                    row = "\(formatter.string(from: date)),"

                    // Received Quantity
                    row = "\(row)\(transaction.isSentTransaction ? "" : transaction.zecAmount.decimalZashiUSFormatted()),"

                    // Received Currency
                    row = "\(row)\(transaction.isSentTransaction ? "" : "ZEC"),"

                    // Sent Quantity
                    row = "\(row)\(transaction.isSentTransaction ? transaction.zecAmount.decimalZashiTaxUSFormatted() : ""),"

                    // Sent Currency
                    row = "\(row)\(transaction.isSentTransaction ? "ZEC" : ""),"

                    // Fee Amount
                    if let fee = transaction.fee {
                        row = "\(row)\(fee.decimalZashiTaxUSFormatted()),"
                    } else {
                        row = "\(row),"
                    }

                    // Fee Currency
                    row = "\(row)\(transaction.fee == nil ? "" : "ZEC"),"

                    // Tag
                    row = "\(row)\n"

                    csvString += row
                }

                let csvData = csvString.data(using: .utf8) ?? Data()

                // Create a temporary file URL
                let component = String(localizable: .taxExportFileName($1, String(prevYear)))
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(component)

                do {
                    try csvData.write(to: tempURL)
                    return tempURL
                } catch {
                    throw error
                }
            }
        )
    }
}
