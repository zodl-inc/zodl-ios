//
//  ZcashError+DetailedMessage.swift
//  
//
//  Created by Lukáš Korba on 24.03.2024.
//

@preconcurrency import ZcashLightClientKit

extension ZcashError {
    var detailedMessage: String {
        "[\(self.code.rawValue)] \(self.message)\n\(self)"
    }
    
    var isInsufficientBalance: Bool {
        detailedMessage.lowercased().contains("insufficient balance")
        || detailedMessage.lowercased().contains("the transaction requires an additional change output of zatbalance")
    }
}
