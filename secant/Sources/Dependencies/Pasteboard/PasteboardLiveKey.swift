//
//  PasteboardLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension PasteboardClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
#if canImport(UIKit)
        Self(
            setString: { UIPasteboard.general.string = $0.data },
            getString: { UIPasteboard.general.string?.redacted }
        )
#else
        Self(
            setString: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString($0.data, forType: .string)
            },
            getString: { NSPasteboard.general.string(forType: .string)?.redacted }
        )
#endif
    }
}
