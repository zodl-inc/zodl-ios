//
//  ReminedMeTimestamp.swift
//  modules
//
//  Created by Lukáš Korba on 10.04.2025.
//

import Foundation

struct ReminedMeTimestamp: Equatable, Codable {
    var timestamp: TimeInterval
    var occurence: Int
    
    init(timestamp: TimeInterval, occurence: Int) {
        self.timestamp = timestamp
        self.occurence = occurence
    }
}
