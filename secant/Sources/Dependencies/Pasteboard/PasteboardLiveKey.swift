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

    // Best-effort compare and clear: clipboard replacement must survive consumption of a gift.
    static func clearIfMatches(_ expected: RedactableString, in pasteboard: UIPasteboard) {
        guard pasteboard.string == expected.data else { return }
        pasteboard.items = []
    }

    static func live() -> Self {
        PasteboardClient(
            setString: { UIPasteboard.general.string = $0.data },
            clearIfMatches: { clearIfMatches($0, in: UIPasteboard.general) },
            getString: { UIPasteboard.general.string?.redacted }
        )
    }
}
