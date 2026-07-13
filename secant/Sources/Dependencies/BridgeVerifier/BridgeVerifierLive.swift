//
//  BridgeVerifierLive.swift
//  Zashi
//
//  Fetch rules (spec BR-7): https-only (loopback dev exception), ALL redirects
//  blocked (stricter than the spec's no-cross-origin minimum), ≤4 KB body,
//  5 s timeout, ephemeral session (no cookies/cache — no tracking surface).
//

import ComposableArchitecture
import Foundation

extension BridgeVerifierClient: DependencyKey {
    static let liveValue = BridgeVerifierClient(
        verify: { requestSrc, tabOrigin in
            guard
                let url = URL(string: requestSrc),
                BridgeDomainRule.isAcceptableFetchURL(url),
                BridgeDomainRule.matches(tabOrigin: tabOrigin, fetchURL: url)
            else { return .failed }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            let session = URLSession(
                configuration: configuration,
                delegate: NoRedirectDelegate(),
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            guard
                let (data, response) = try? await session.data(from: url),
                let http = response as? HTTPURLResponse,
                http.statusCode == 200,
                let uri = BridgeDomainRule.extractURI(from: data)
            else { return .failed }

            // Domain label shown in the confirm card = the host the bytes came from.
            return .verified(uri: uri, domain: url.host ?? "")
        }
    )
}

/// Refuses every redirect: the verified domain must be the domain that answered.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
