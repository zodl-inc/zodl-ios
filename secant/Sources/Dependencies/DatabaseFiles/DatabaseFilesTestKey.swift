//
//  DatabaseFilesTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import Foundation
import ComposableArchitecture
import XCTestDynamicOverlay

extension DatabaseFilesClient {
    static let noOp = Self(
        documentsDirectory: { .emptyURL },
        fsBlockDbRootFor: { _ in .emptyURL },
        cacheDbURLFor: { _ in .emptyURL },
        dataDbURLFor: { _ in .emptyURL },
        outputParamsURLFor: { _ in .emptyURL },
        pendingDbURLFor: { _ in .emptyURL },
        spendParamsURLFor: { _ in .emptyURL },
        toDirURLFor: { _ in .emptyURL },
        areDbFilesPresentFor: { _ in false }
    )
}
