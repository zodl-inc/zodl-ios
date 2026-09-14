//
//  TransactionGuardTestKey.swift
//  Zashi
//

import ComposableArchitecture

extension TransactionGuardClient: TestDependencyKey {
    /// Tests get a pass-through guard: submissions and switches run immediately, never blocking.
    static let testValue = TransactionGuardClient(
        acquire: {},
        acquireWithTimeout: { _ in },
        tryAcquire: { true },
        release: {}
    )
}
