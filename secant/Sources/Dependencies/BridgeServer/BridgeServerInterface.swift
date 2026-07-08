//
//  BridgeServerInterface.swift
//  Zashi
//
//  Zodl Bridge (docs/macos/ZODL_BRIDGE_SPEC.md): the in-app side of the pinned
//  browser→Zodl channel. Receives one-shot ZIP-321 payment requests from the
//  native-messaging helper over a Unix domain socket. Strictly one-way — the
//  only reply is a local delivery ack; no wallet data ever crosses back.
//

import ComposableArchitecture
import Foundation

/// One payment request as delivered by the helper (`bridge/host`). `origin` is
/// browser-attested by our extension; `requestSrc` is the optional BR-7 Tier-1
/// pointer the app re-fetches natively. Semantic ZIP-321 validation happens in
/// routing (URIParserClient.checkRP) — this type is transport-shaped only.
struct BridgePaymentRequest: Equatable, Sendable, Codable {
    let id: String
    let uri: String
    let origin: String
    let requestSrc: String?
}

extension DependencyValues {
    var bridgeServer: BridgeServerClient {
        get { self[BridgeServerClient.self] }
        set { self[BridgeServerClient.self] = newValue }
    }
}

@DependencyClient
struct BridgeServerClient {
    /// Starts the listener (idempotent) and returns the stream of validated
    /// transport-shaped requests. On iOS this is a no-op finished stream.
    var start: @Sendable () -> AsyncStream<BridgePaymentRequest> = { .finished }
    var stop: @Sendable () -> Void
}
