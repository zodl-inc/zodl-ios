import Foundation
import Testing
import os
@testable import zodl_internal

@Suite struct SwapAndPayGiftCardPrivacyTests {
    enum CandidateFormat: CaseIterable {
        case zodl
        case zodlBareHost
        case vizor
        case malformedZodl
        case malformedVizor

        var link: String {
            switch self {
            case .zodl: "https://gift.zodl.com/#v=1&key=synthetic-bearer-fixture&height=3000000"
            case .zodlBareHost: "https://gift.zodl.com#v=1&key=synthetic-bearer-fixture&height=3000000"
            case .vizor: "https://link.vizor.cash/payment-links/open#v3=synthetic-bearer-fixture"
            case .malformedZodl: "https://gift.zodl.com/#key=synthetic-bearer-fixture&v=broken"
            case .malformedVizor: "https://link.vizor.cash/payment-links/open#v3=%%%synthetic-bearer-fixture"
            }
        }
    }

    enum AddressRole: CaseIterable {
        case refund
        case destination
    }

    struct QuoteScenario {
        let role: AddressRole
        let isSwapToZec: Bool
        let whitespaceAndCase: Bool

        static let all = AddressRole.allCases.flatMap { role in
            [false, true].flatMap { isSwapToZec in
                [false, true].map { whitespaceAndCase in
                    QuoteScenario(role: role, isSwapToZec: isSwapToZec, whitespaceAndCase: whitespaceAndCase)
                }
            }
        }
    }

    @Test(arguments: CandidateFormat.allCases, QuoteScenario.all)
    func quoteRejectsGiftCardsBeforeFeeLookupOrTransport(
        format: CandidateFormat,
        scenario: QuoteScenario
    ) async throws {
        let requests = OSAllocatedUnfairLock(initialState: [Data]())
        let feeReads = OSAllocatedUnfairLock(initialState: 0)
        let provider = Near1Click.live(quoteTransport: { _, data in
            requests.withLock { $0.append(data) }
            return try Self.response()
        }, feeAddress: {
            feeReads.withLock { $0 += 1 }
            return "synthetic-fee-address"
        })
        let link = scenario.whitespaceAndCase ? " \n\(format.link.uppercased())\t " : format.link
        var failure: Error?
        do {
            _ = try await provider.quote(
                false, scenario.isSwapToZec, true, 100, Self.zecAsset, Self.otherAsset,
                scenario.role == .refund ? link : "ordinary-refund-address",
                scenario.role == .destination ? link : "ordinary-destination-address",
                "100000000"
            )
        } catch {
            failure = error
        }
        // Keep assertions secret-free even when the provider guard is missing.
        let expectedMessage = String(localizable: .swapGiftCardAddressNotAllowed)
        let isExpectedError = (failure as? SwapAndPayClient.EndpointError) == .message(expectedMessage)
        let errorContainsSecret = failure.map { String(describing: $0).lowercased().contains("synthetic-bearer-fixture") } ?? false
        let didTransportSecret = requests.withLock { data in
            data.contains { String(decoding: $0, as: UTF8.self).lowercased().contains("synthetic-bearer-fixture") }
        }
        #expect(isExpectedError)
        #expect(!errorContainsSecret)
        #expect(!didTransportSecret)
        #expect(requests.withLock { $0.count } == 0)
        #expect(feeReads.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true]) func ordinaryQuotePreservesRequestRoles(isSwapToZec: Bool) async throws {
        let requests = OSAllocatedUnfairLock(initialState: [Data]())
        let feeReads = OSAllocatedUnfairLock(initialState: 0)
        let provider = Near1Click.live(quoteTransport: { url, data in
            #expect(url == "https://1click.chaindefuser.com/v0/quote")
            requests.withLock { $0.append(data) }
            return try Self.response()
        }, feeAddress: {
            feeReads.withLock { $0 += 1 }
            return "synthetic-fee-address"
        })
        let result = try await provider.quote(
            false, isSwapToZec, true, 100, Self.zecAsset, Self.otherAsset,
            "ordinary-refund-address", "ordinary-destination-address", "100000000"
        )
        let data = try #require(requests.withLock { $0.first })
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(requests.withLock { $0.count } == 1)
        #expect(feeReads.withLock { $0 } == 1)
        #expect(request["refundTo"] as? String == (isSwapToZec ? "ordinary-destination-address" : "ordinary-refund-address"))
        #expect(request["recipient"] as? String == (isSwapToZec ? "ordinary-refund-address" : "ordinary-destination-address"))
        #expect(request["originAsset"] as? String == (isSwapToZec ? "nep141:eth.omft.near" : "nep141:zec.omft.near"))
        #expect(request["destinationAsset"] as? String == (isSwapToZec ? "nep141:zec.omft.near" : "nep141:eth.omft.near"))
        #expect(request["amount"] as? String == "100000000")
        #expect(result.depositAddress == "synthetic-deposit-address")
    }

    private static let zecAsset = SwapAsset(
        provider: "near", chain: "zec", token: "ZEC", assetId: "nep141:zec.omft.near", usdPrice: 1, decimals: 8
    )
    private static let otherAsset = SwapAsset(
        provider: "near", chain: "eth", token: "ETH", assetId: "nep141:eth.omft.near", usdPrice: 1, decimals: 18
    )

    private static func response() throws -> (Data, URLResponse) {
        let url = try #require(URL(string: "https://provider.invalid/fixture"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let data = Data(#"{"quote":{"depositAddress":"synthetic-deposit-address","amountIn":"100000000","amountInUsd":"1","minAmountIn":"1","amountOut":"100000000","amountOutUsd":"1","timeEstimate":5}}"#.utf8)
        return (data, response)
    }
}
