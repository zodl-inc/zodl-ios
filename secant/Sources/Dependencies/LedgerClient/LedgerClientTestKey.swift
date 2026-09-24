//
//  LedgerClientTestKey.swift
//  Zashi
//

import ComposableArchitecture
import XCTestDynamicOverlay
@preconcurrency import ZcashLightClientKit

extension LedgerClient {
    static let noOp = Self(
        scanDevices: { AsyncThrowingStream { $0.finish() } },
        connect: { _ in },
        pairAccount: { _ in throw LedgerClientError.notConnected },
        disconnect: { },
        signPCZT: { _, _, _ in AsyncThrowingStream { $0.finish(throwing: LedgerClientError.notConnected) } }
    )
}
