//
//  SupportDataGeneratorTestKey.swift
//  secant
//
//  Created by Michal Fousek on 28.02.2023.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension SupportDataGeneratorClient {
    static let noOp = Self(
        generate: { SupportData(toAddress: "", subject: "", message: "") }
    )
}
