//
//  PasteboardLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture
import UIKit

extension PasteboardClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            setString: { UIPasteboard.general.string = $0.data },
            getString: { UIPasteboard.general.string?.redacted }
        )
    }
}
