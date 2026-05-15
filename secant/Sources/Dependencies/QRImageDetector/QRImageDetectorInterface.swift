//
//  QRImageDetectorInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-04-18.
//

import SwiftUI
import ComposableArchitecture

extension DependencyValues {
    var qrImageDetector: QRImageDetectorClient {
        get { self[QRImageDetectorClient.self] }
        set { self[QRImageDetectorClient.self] = newValue }
    }
}

@DependencyClient
struct QRImageDetectorClient {
    var check: @Sendable (UIImage?) -> [String]?
}
