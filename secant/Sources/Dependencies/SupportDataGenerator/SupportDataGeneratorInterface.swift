//
//  SupportDataGeneratorInterface.swift
//  secant
//
//  Created by Michal Fousek on 28.02.2023.
//

import ComposableArchitecture

extension DependencyValues {
    var supportDataGenerator: SupportDataGeneratorClient {
        get { self[SupportDataGeneratorClient.self] }
        set { self[SupportDataGeneratorClient.self] = newValue }
    }
}

@DependencyClient
struct SupportDataGeneratorClient {
    var generate: @Sendable () -> SupportData = { SupportData(toAddress: "", subject: "", message: "") }
}
