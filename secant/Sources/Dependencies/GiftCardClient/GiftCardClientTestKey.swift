//
//  GiftCardClientTestKey.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension GiftCardClient: TestDependencyKey {
    static let testValue = Self()
    static let previewValue = Self.mock()
}

extension GiftCardClient {
    /// What the mocked card holds and how redeeming it ends.
    struct MockScenario: Sendable {
        /// A Zodl card: its value plus the fee of sweeping it, so it gives exactly its stated amount.
        var status: GiftCardStatus = .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000))
        var networkType: NetworkType = .mainnet
        var message: String? = "Welcome to Zcash Summit"
        var statedAmount: Zatoshi? = Zatoshi(10_000_000)
        var checkError: GiftCardClientError?
        var redeemError: GiftCardClientError?
        /// How many `redeem` calls throw `redeemError` before one succeeds; `nil` means every one
        /// does. Models a broadcast that fails once and goes through on the retry.
        var redeemFailuresBeforeSuccess: Int?
        var txId = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
        /// What a redemption reports as received; by default the ready card's `redeemable`.
        var received: Zatoshi?
        /// Progress values reported before `check` answers.
        var progressSteps: [Double] = [0.25, 0.5, 0.75, 1.0]
        /// Simulated sync time; zero in tests.
        var delay: Duration = .zero

        static let ready = MockScenario()
        static let pending = MockScenario(status: .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3))
        static let empty = MockScenario(status: .empty)
        static let dust = MockScenario(status: .dust)
        static let testnet = MockScenario(networkType: .testnet)
        static let redeemFails = MockScenario(redeemError: .redeemFailed)
        static let redeemFailsOnce = MockScenario(redeemError: .redeemFailed, redeemFailuresBeforeSuccess: 1)
        static let checkFails = MockScenario(checkError: .checkFailed)
    }

    /// A fully working stand-in for previews and tests. It recognizes links with the live prefix
    /// check and treats any recognized link as a card described by `scenario`; a link whose
    /// fragment is empty is reported as damaged, so the invalid-link screen can be exercised too.
    /// It is not a parser and never derives anything from the link's secret.
    static func mock(_ scenario: MockScenario = .ready) -> Self {
        let redeemAttempts = LockIsolated(0)
        return Self(
            isGiftCardLink: { GiftCardLink.isCandidate($0) },
            parse: { link in
                guard GiftCardLink.isCandidate(link) else {
                    throw GiftCardClientError.notAGiftCardLink
                }
                guard let fragment = link.split(separator: "#", maxSplits: 1).dropFirst().first, !fragment.isEmpty else {
                    throw GiftCardClientError.invalidLink
                }
                return GiftCardSummary(
                    origin: link.lowercased().contains(GiftCardLink.zodlHost) ? .zodl : .vizor,
                    networkType: scenario.networkType,
                    birthdayHeight: 3_000_000,
                    statedAmount: scenario.statedAmount,
                    message: scenario.message
                )
            },
            open: { _ in GiftCardHandle() },
            progress: { _ in
                AsyncStream { continuation in
                    for step in scenario.progressSteps {
                        continuation.yield(step)
                    }
                    continuation.finish()
                }
            },
            check: { _ in
                if scenario.delay > .zero {
                    try await Task.sleep(for: scenario.delay)
                }
                if let error = scenario.checkError {
                    throw error
                }
                return scenario.status
            },
            redeem: { _, _ in
                if scenario.delay > .zero {
                    try await Task.sleep(for: scenario.delay)
                }
                let attempt = redeemAttempts.withValue { value in
                    value += 1
                    return value
                }
                if let error = scenario.redeemError, scenario.redeemFailuresBeforeSuccess.map({ attempt <= $0 }) ?? true {
                    throw error
                }
                if let received = scenario.received {
                    return GiftCardRedemption(txId: scenario.txId, received: received)
                }
                if case let .ready(_, redeemable) = scenario.status {
                    return GiftCardRedemption(txId: scenario.txId, received: redeemable)
                }
                return GiftCardRedemption(txId: scenario.txId, received: nil)
            },
            cleanup: { _ in },
            removeLeftoverWallets: { }
        )
    }
}
