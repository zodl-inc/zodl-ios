//
//  ZatoshiStringRepresentation.swift
//
//
//  Created by Lukáš Korba on 10.11.2023.
//

import Foundation
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture

struct ZatoshiStringRepresentation: Equatable {
    enum PrefixSymbol: Equatable {
        case none
        case minus
        case plus
    }
    
    enum Format: Equatable {
        case abbreviated
        case expanded
    }

    let mostSignificantDigits: String
    let leastSignificantDigits: String
    let feeFormat = ZatoshiStringRepresentation.feeFormat

    init(
        _ zatoshi: Zatoshi,
        prefixSymbol: PrefixSymbol = .none,
        format: Format = .abbreviated
    ) {
        var symbol = ""
        
        switch prefixSymbol {
        case .minus: symbol = "-"
        case .plus: symbol = "+"
        default: break
        }
        
        // 0 zatoshi case
        if zatoshi.amount == 0 {
            self.mostSignificantDigits = "\(symbol)\(Zatoshi(0).decimalZashiFormatted())"
            self.leastSignificantDigits = ""
        } else if zatoshi.amount < 100_000 && format == .abbreviated {
            // 0 for most significant but non-0 for least ones
            self.mostSignificantDigits = "\(symbol)\(Zatoshi(0).decimalZashiFormatted())..."
            self.leastSignificantDigits = ""
        } else {
            if format == .expanded {
                let formatted = zatoshi.decimalZashiFullFormatted()
                
                let leastSignificantDigits = String(formatted.suffix(5))
                let mostSignificantDigits = formatted.dropLast(5)
                
                var leastTrimmed = ""
                var useTheRest = false
                
                for char in leastSignificantDigits.reversed() {
                    if char != "0" {
                        useTheRest = true
                    }
                    
                    if useTheRest {
                        leastTrimmed += String(char)
                    }
                }
                
                leastTrimmed = String(leastTrimmed.reversed())
                
                self.mostSignificantDigits = "\(symbol)\(mostSignificantDigits)"
                self.leastSignificantDigits = "\(leastTrimmed)"
            } else {
                let formatted = zatoshi.decimalZashiFormatted()
                                
                self.mostSignificantDigits = "\(symbol)\(formatted)"
                self.leastSignificantDigits = ""
            }
        }
    }
}

extension ZatoshiStringRepresentation {
    static let placeholer = Self(Zatoshi(123_456_000))
}

extension ZatoshiStringRepresentation {
    static var feeFormat: String { String(localizable: .generalFee(Zatoshi(100_000).decimalZashiFormatted())) }
}
