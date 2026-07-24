//
//  Array+Chunked.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.05.2022.
//

import Foundation

extension Array where Element: Identifiable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
