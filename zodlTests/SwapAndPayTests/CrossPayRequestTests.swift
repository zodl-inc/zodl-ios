import Foundation
import Testing
@testable import zodl_internal

struct CrossPayRequestTests {
    private let recipient = "0x92bF6Fbd794bA41093013Db027400B174aE4b5Cd"
    private let usdcContract = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

    @Test func supportedRequestsMapToCrossPayFields() throws {
        let bitcoin = try #require(
            CrossPayRequestParser.parse(
                "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=0.015&label=Shop"
            )
        )
        #expect(bitcoin.address == "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo")
        #expect(bitcoin.resolvedAmount(for: asset(token: "BTC", chain: "btc", decimals: 8)) == Decimal(string: "0.015"))

        let baseUsdc = asset(
            token: "USDC",
            chain: "base",
            decimals: 6,
            contractAddress: usdcContract
        )
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)@8453/transfer?address=\(recipient)&uint256=2500000"
            )
        )

        #expect(request.address == recipient)
        #expect(request.resolveAsset(in: [baseUsdc], current: nil) == baseUsdc)
        #expect(request.resolvedAmount(for: baseUsdc) == Decimal(string: "2.5"))

        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let solanaUsdc = asset(token: "USDC", chain: "sol", decimals: 6, contractAddress: mint)
        let solana = try #require(
            CrossPayRequestParser.parse(
                "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=\(mint)"
            )
        )
        #expect(solana.address == "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN")
        #expect(solana.resolveAsset(in: [solanaUsdc], current: nil) == solanaUsdc)
        #expect(solana.resolvedAmount(for: solanaUsdc) == Decimal(string: "0.01"))
    }

    @Test func unsupportedAndPlainValuesAreNotReinterpreted() {
        #expect(CrossPayRequestParser.parse("bc1qplain") == nil)
        #expect(CrossPayRequestParser.parse("near:alice.near") == nil)
        #expect(CrossPayRequestParser.parse("solana:https://example.com/pay") == nil)
        #expect(CrossPayRequestParser.parse("ethereum:\(usdcContract)/approve?address=\(recipient)") == nil)
    }

    private func asset(
        token: String,
        chain: String,
        decimals: Int,
        contractAddress: String? = nil
    ) -> SwapAsset {
        SwapAsset(
            provider: "near",
            chain: chain,
            token: token,
            assetId: "\(chain).\(token)",
            contractAddress: contractAddress,
            usdPrice: 1,
            decimals: decimals
        )
    }
}
