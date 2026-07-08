//
//  BridgeVerifierInterface.swift
//  Zashi
//
//  BR-7 Tier 1 (docs/macos/ZODL_BRIDGE_SPEC.md): natively re-fetch the payment
//  request from the merchant's OWN domain — outside the browser's reach — and
//  verify the fetch domain against the browser-attested tab origin. Turns the
//  unverifiable "trust the page's bytes" into "verify by domain": a DOM-rewriting
//  attacker must point off-domain, and code catches that.
//

import ComposableArchitecture
import Foundation

enum BridgeVerification: Equatable, Sendable {
    /// `uri` is the FETCHED request (replaces the page-embedded one entirely).
    case verified(uri: String, domain: String)
    case failed
}

extension DependencyValues {
    var bridgeVerifier: BridgeVerifierClient {
        get { self[BridgeVerifierClient.self] }
        set { self[BridgeVerifierClient.self] = newValue }
    }
}

@DependencyClient
struct BridgeVerifierClient {
    /// (requestSrc URL string, browser-attested tab origin) → verification result.
    var verify: @Sendable (String, String) async -> BridgeVerification = { _, _ in .failed }
}

/// The domain comparison, pure and unit-tested. Registrable-domain flavor without a
/// PSL dependency: exact host match, or the fetch host is a SUBDOMAIN of the tab host
/// (tab host normalized by stripping one leading "www."). Covers the real-world shape
/// (checkout `cipherpay.app` / invoices `api.cipherpay.app`) with no cross-domain
/// false accepts (`cipherpay.app.evil.com` does not end with ".cipherpay.app").
enum BridgeDomainRule {
    static func matches(tabOrigin: String, fetchURL: URL) -> Bool {
        guard
            let tabHost = URL(string: tabOrigin)?.host?.lowercased(),
            let fetchHost = fetchURL.host?.lowercased(),
            !tabHost.isEmpty, !fetchHost.isEmpty
        else { return false }

        var tab = tabHost
        if tab.hasPrefix("www.") { tab.removeFirst(4) }

        if fetchHost == tab { return true }
        return fetchHost.hasSuffix(".\(tab)")
    }

    /// https only — except plain-http loopback, mirroring the helper's origin rule
    /// (the demo fixture). The production merchant path is always https.
    static func isAcceptableFetchURL(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        if url.scheme == "https" { return true }
        if url.scheme == "http" { return host == "localhost" || host == "127.0.0.1" }
        return false
    }

    /// Accept a raw ZIP-321 body or a JSON body carrying `zcash_uri` (the CipherPay
    /// public-invoice shape, spec calibration note).
    static func extractURI(from body: Data) -> String? {
        guard body.count <= 4096 else { return nil }
        if let text = String(data: body, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("zcash:") { return trimmed }
        }
        if
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let uri = object["zcash_uri"] as? String,
            uri.hasPrefix("zcash:")
        {
            return uri
        }
        return nil
    }
}
