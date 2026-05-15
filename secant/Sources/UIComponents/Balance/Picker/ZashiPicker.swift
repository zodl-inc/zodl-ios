//
//  ZashiPicker.swift
//
//
//  Created by Lukáš Korba on 03.05.2024.
//

import SwiftUI

struct ZashiPicker<Data, Content> : View where Data: Hashable, Content: View {
    let sources: [Data]
    let selection: Data?
    private let itemBuilder: (Data) -> Content

    init(
        _ sources: [Data],
        selection: Data?,
        @ViewBuilder itemBuilder: @escaping (Data) -> Content
    ) {
        self.sources = sources
        self.selection = selection
        self.itemBuilder = itemBuilder
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            HStack(spacing: 0) {
                ForEach(sources, id: \.self) { item in
                    itemBuilder(item)
                }
            }
        }
    }
}
