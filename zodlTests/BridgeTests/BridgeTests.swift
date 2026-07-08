//
//  BridgeTests.swift
//  zodlTests
//
//  Zodl Bridge — the security-relevant pure logic (spec BR-7): the Tier-1 domain
//  rule (verify by domain, not address) and the fetched-body URI extraction.
//

import Foundation
import Testing

@testable import zodl_internal

@Suite struct BridgeDomainRuleTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func exactHostMatches() {
        #expect(BridgeDomainRule.matches(tabOrigin: "https://cipherpay.app", fetchURL: url("https://cipherpay.app/api/invoices/1")))
    }

    @Test func subdomainOfTabHostMatches() {
        // The real-world CipherPay shape: checkout on the apex, invoices on api.
        #expect(BridgeDomainRule.matches(tabOrigin: "https://cipherpay.app", fetchURL: url("https://api.cipherpay.app/api/invoices/1")))
    }

    @Test func wwwTabIsNormalized() {
        #expect(BridgeDomainRule.matches(tabOrigin: "https://www.cipherpay.app", fetchURL: url("https://api.cipherpay.app/x")))
    }

    @Test func lookalikeSuffixDomainRefused() {
        // cipherpay.app.evil.com must NOT pass — no cross-registrable false accepts.
        #expect(!BridgeDomainRule.matches(tabOrigin: "https://cipherpay.app", fetchURL: url("https://cipherpay.app.evil.com/x")))
    }

    @Test func prefixLookalikeRefused() {
        #expect(!BridgeDomainRule.matches(tabOrigin: "https://cipherpay.app", fetchURL: url("https://evil-cipherpay.app/x")))
    }

    @Test func unrelatedDomainRefused() {
        #expect(!BridgeDomainRule.matches(tabOrigin: "https://shop.example", fetchURL: url("https://attacker.example/x")))
    }

    @Test func tabSubdomainDoesNotWidenToParentSiblings() {
        // tab = shop.example.com; fetch = other.example.com is NOT a subdomain of it.
        #expect(!BridgeDomainRule.matches(tabOrigin: "https://shop.example.com", fetchURL: url("https://other.example.com/x")))
    }

    @Test func loopbackDemoMatches() {
        #expect(BridgeDomainRule.matches(tabOrigin: "http://localhost:8873", fetchURL: url("http://localhost:8873/invoice.txt")))
    }

    @Test func fetchURLSchemeRules() {
        #expect(BridgeDomainRule.isAcceptableFetchURL(url("https://cipherpay.app/x")))
        #expect(BridgeDomainRule.isAcceptableFetchURL(url("http://localhost:8873/x")))
        #expect(!BridgeDomainRule.isAcceptableFetchURL(url("http://shop.example/x")))
        #expect(!BridgeDomainRule.isAcceptableFetchURL(url("ftp://cipherpay.app/x")))
    }
}

@Suite struct BridgeURIExtractionTests {
    @Test func rawZip321BodyExtracts() {
        let body = Data("zcash:u1abc?amount=0.001\n".utf8)
        #expect(BridgeDomainRule.extractURI(from: body) == "zcash:u1abc?amount=0.001")
    }

    @Test func jsonInvoiceBodyExtracts() {
        // The CipherPay public-invoice shape (spec calibration note).
        let body = Data(#"{"id":"inv1","zcash_uri":"zcash:u1abc?amount=0.001","status":"pending"}"#.utf8)
        #expect(BridgeDomainRule.extractURI(from: body) == "zcash:u1abc?amount=0.001")
    }

    @Test func nonZcashBodyRefused() {
        #expect(BridgeDomainRule.extractURI(from: Data("bitcoin:xyz".utf8)) == nil)
        #expect(BridgeDomainRule.extractURI(from: Data(#"{"zcash_uri":"bitcoin:xyz"}"#.utf8)) == nil)
    }

    @Test func oversizeBodyRefused() {
        let body = Data(("zcash:" + String(repeating: "a", count: 5000)).utf8)
        #expect(BridgeDomainRule.extractURI(from: body) == nil)
    }
}
