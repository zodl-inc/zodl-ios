//
//  Spendability.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-12-2025.
//

enum Spendability: Equatable, Codable, Hashable {
    /// Spendable balance equals total balance
    case everything
    /// Some of the total balance is spendable but not all
    case something
    /// None of the balance is spendable at the moment, waiting on confirmations until spendable
    case nothing
}
