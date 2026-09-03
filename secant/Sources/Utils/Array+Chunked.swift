//
//  Array+Chunked.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.05.2022.
//

import Foundation

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        // `stride(from:to:by:)` traps at runtime when `by` is 0
        // ("Fatal error: Stride size must not be zero"), and a negative size is
        // meaningless here. Guard both: a non-positive chunk size returns the
        // whole array as a single chunk (empty stays empty) instead of crashing.
        guard size > 0 else {
            return isEmpty ? [] : [self]
        }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Array where Element: Identifiable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
