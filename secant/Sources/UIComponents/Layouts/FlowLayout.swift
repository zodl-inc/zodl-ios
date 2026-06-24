//
//  FlowLayout.swift
//  Zashi
//
//  A wrapping HStack: lays children left-to-right and wraps to the next line when the current row
//  is full. Used where a horizontal run of items must WRAP to multiple lines instead of scrolling on
//  a single line — e.g. the macOS seed-restore word suggestions, where there is no software keyboard
//  to anchor a single-line bar, so the matches wrap into a band below the grid.
//
//  `Layout` is available on the package minimums (iOS 16 / macOS 13), so no availability guard.
//

import SwiftUI

struct FlowLayout: Layout {
    /// Gap both between items on a row and between rows.
    var spacing: CGFloat = 8
    /// How each (possibly short) row is positioned within the available width. `.center` matches the
    /// centered macOS content column; `.leading` hugs the left like a conventional autocomplete list.
    var alignment: HorizontalAlignment = .center
    /// Cap the layout's HEIGHT to this many rows (e.g. `2`). Extra rows are still laid out — just below
    /// the reported frame — so the caller clips them with `.clipped()`. This gives "strict N lines, count
    /// varies with width": which items fit is decided by measurement, not a fixed count. `nil` = all rows.
    var maxRows: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let allRows = rows(maxWidth: maxWidth, subviews: subviews)
        let sized = maxRows.map { Array(allRows.prefix(max(0, $0))) } ?? allRows
        let width = maxWidth.isFinite ? maxWidth : (allRows.map(\.width).max() ?? 0)
        let height = sized.enumerated().reduce(CGFloat.zero) { total, row in
            total + row.element.height + (row.offset == 0 ? 0 : spacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // Place EVERY row (including any beyond `maxRows`); the rows past the cap land below the reported
        // frame and are hidden by the caller's `.clipped()`. Every subview is placed, so no layout warning.
        var y = bounds.minY
        for row in rows(maxWidth: bounds.width, subviews: subviews) {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .leading:  x = bounds.minX
            default:        x = bounds.minX + (bounds.width - row.width) / 2
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    // MARK: - Rows

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0   // total width including inter-item spacing
        var height: CGFloat = 0  // tallest item in the row
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projectedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && projectedWidth > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = projectedWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
