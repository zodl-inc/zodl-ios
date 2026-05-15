//
//  InitializationState.swift
//  Zashi
//
//  Created by Lukáš Korba on 30.03.2022.
//

import Foundation

enum AppStartState: Equatable {
    case backgroundTask
    case didEnterBackground
    case didFinishLaunching
    case unknown
    case willEnterForeground
}

enum InitializationState: Equatable {
    case failed
    case filesMissing
    case initialized
    case keysMissing
    case osStatus(OSStatus)
    case uninitialized
}

enum SDKInitializationError: Error {
    case failed
}
