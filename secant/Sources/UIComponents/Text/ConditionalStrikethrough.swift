//
//  ConditionalStrikethrough.swift
//
//
//  Created by Lukáš Korba on 08.11.2023.
//

import SwiftUI

extension Text {
    func conditionalStrikethrough(_ on: Bool) -> Text {
        if on {
            return self
                .strikethrough()
        } else {
            return self
        }
    }
}
