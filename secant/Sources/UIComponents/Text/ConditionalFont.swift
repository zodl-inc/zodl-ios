//
//  ConditionalFont.swift
//
//
//  Created by Lukáš Korba on 08.11.2023.
//

import SwiftUI

extension Text {
    func conditionalFont(condition: Bool, true: Font, else: Font) -> Text {
        if condition {
            return self
                .font(`true`)
        } else {
            return self
                .font(`else`)
        }
    }
}
