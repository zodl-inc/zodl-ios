//
//  PasteboardInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

@DependencyClient
struct PasteboardClient {
    var setString: @Sendable (RedactableString) -> Void
    var getString: @Sendable () -> RedactableString?
}
