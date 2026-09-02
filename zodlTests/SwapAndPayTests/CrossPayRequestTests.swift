//
//  CrossPayRequestTests.swift
//  zodlTests
//
//  Covers the app-side adapter over the SDK's payment URI parser
//  (Models/CrossPayRequest.swift): which requests are accepted at all, which app asset a request
//  resolves to, and how its amount is denominated.
//

import Foundation
import Testing
@testable import zodl_internal

@Suite struct CrossPayRequestTests {
    private let recipient = "0x92bF6Fbd794bA41093013Db027400B174aE4b5Cd"
    private let usdcContract = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
    private let solanaMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    // MARK: - Happy paths

    @Test func supportedRequestsMapToCrossPayFields() throws {
        let btcAsset = asset(token: "BTC", chain: "btc", decimals: 8)
        let bitcoin = try #require(
            CrossPayRequestParser.parse(
                "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=0.015&label=Shop"
            )
        )
        #expect(bitcoin.address == "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo")
        #expect(bitcoin.resolveAsset(in: [btcAsset], current: nil) == btcAsset)
        #expect(bitcoin.resolvedAmount(for: btcAsset) == Decimal(string: "0.015"))

        let ltcAsset = asset(token: "LTC", chain: "ltc", decimals: 8)
        let litecoin = try #require(
            CrossPayRequestParser.parse(
                "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?amount=1.25&message=Coffee"
            )
        )
        #expect(litecoin.address == "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA")
        #expect(litecoin.resolveAsset(in: [ltcAsset], current: nil) == ltcAsset)
        #expect(litecoin.resolvedAmount(for: ltcAsset) == Decimal(string: "1.25"))

        let baseUsdc = asset(token: "USDC", chain: "base", decimals: 6, contractAddress: usdcContract)
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)@8453/transfer?address=\(recipient)&uint256=2500000"
            )
        )
        #expect(request.address == recipient)
        #expect(request.resolveAsset(in: [baseUsdc], current: nil) == baseUsdc)
        #expect(request.resolvedAmount(for: baseUsdc) == Decimal(string: "2.5"))

        let solanaUsdc = asset(token: "USDC", chain: "sol", decimals: 6, contractAddress: solanaMint)
        let solana = try #require(
            CrossPayRequestParser.parse(
                "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=\(solanaMint)"
            )
        )
        #expect(solana.address == "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN")
        #expect(solana.resolveAsset(in: [solanaUsdc], current: solanaUsdc) == solanaUsdc)
        #expect(solana.resolvedAmount(for: solanaUsdc) == Decimal(string: "0.01"))
    }

    // MARK: - Chain resolution

    @Test func evmRequestWithoutChainIdResolvesToEthereumMainnet() throws {
        // EIP-681 has no `chain` string, only a numeric chainId, so a request without an explicit
        // `@chainId` reaches resolveAsset with no chain at all. It used to fall back to the
        // currently-selected asset's chain, which made the same QR mean different assets depending
        // on an unrelated earlier swap. Ethereum mainnet is the universal default network and keeps
        // resolution a pure function of the URI.
        let ethUsdc = asset(token: "USDC", chain: "eth", decimals: 6, contractAddress: usdcContract)
        let baseUsdc = asset(token: "USDC", chain: "base", decimals: 6, contractAddress: usdcContract)
        let arbUsdc = asset(token: "USDC", chain: "arb", decimals: 6, contractAddress: usdcContract)
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)/transfer?address=\(recipient)&uint256=2500000"
            )
        )

        // `current` is a candidate on its own chain, so anything that still consults it returns
        // arbUsdc here rather than the Ethereum-mainnet asset the request actually names.
        #expect(request.resolveAsset(in: [ethUsdc, baseUsdc, arbUsdc], current: arbUsdc) == ethUsdc)
        #expect(request.resolveAsset(in: [ethUsdc, baseUsdc, arbUsdc], current: nil) == ethUsdc)
    }

    @Test func evmNativeRequestWithoutChainIdResolvesToEthereumMainnet() throws {
        // The same rule for native requests. `current` here is an EVM asset whose own chain has a
        // native token, which is exactly the shape that used to resolve `ethereum:...?value=1e18`
        // to 1 AVAX -- roughly a 100x per-unit value difference from the 1 ETH it asked for.
        let ethereum = asset(token: "ETH", chain: "eth", decimals: 18)
        let avalanche = asset(token: "AVAX", chain: "avax", decimals: 18)
        let request = try #require(CrossPayRequestParser.parse("ethereum:\(recipient)?value=1e18"))

        #expect(request.resolveAsset(in: [ethereum, avalanche], current: avalanche) == ethereum)
    }

    @Test func evmNativeRequestNeverManufacturesANativeTokenFromANonNativeSelection() throws {
        // `current` used to seed the chain even when it wasn't itself a native asset, so a selected
        // USDT@bsc resolved a chain-less native request to BNB@bsc -- an asset the user had not
        // selected and the request had not named.
        let bscUsdt = asset(token: "USDT", chain: "bsc", decimals: 18, contractAddress: usdcContract)
        let bnb = asset(token: "BNB", chain: "bsc", decimals: 18)
        let request = try #require(CrossPayRequestParser.parse("ethereum:\(recipient)?value=1e18"))

        #expect(request.resolveAsset(in: [bscUsdt, bnb], current: bscUsdt) == nil)
    }

    @Test func unknownChainIdResolvesToNothing() throws {
        // zkSync Era. A chain id we don't map must fail closed rather than fall back to a default.
        let ethUsdc = asset(token: "USDC", chain: "eth", decimals: 6, contractAddress: usdcContract)
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)@324/transfer?address=\(recipient)&uint256=2500000"
            )
        )

        #expect(request.resolveAsset(in: [ethUsdc], current: ethUsdc) == nil)
    }

    @Test func optimismNativeAssetIsEthNotOp() throws {
        // OP is an ERC-20 governance token; Optimism's native asset is ETH only.
        let opToken = asset(token: "OP", chain: "op", decimals: 18)
        let request = try #require(CrossPayRequestParser.parse("ethereum:\(recipient)@10?value=1e18"))

        #expect(request.resolveAsset(in: [opToken], current: opToken) == nil)
    }

    // MARK: - Contract matching

    @Test func solanaMintsAreComparedCaseSensitively() throws {
        // Base58 is case-sensitive, so a case-mangled mint is a different mint (and not a valid one)
        // and must not resolve to the wallet's genuine USDC.
        let solanaUsdc = asset(
            token: "USDC",
            chain: "sol",
            decimals: 6,
            contractAddress: solanaMint.uppercased()
        )
        let request = try #require(
            CrossPayRequestParser.parse(
                "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=\(solanaMint)"
            )
        )

        #expect(request.resolveAsset(in: [solanaUsdc], current: nil) == nil)
    }

    @Test func evmContractsAreComparedCaseInsensitively() throws {
        // EIP-55 mixed case is a checksum over the same address, so casing must not matter.
        let baseUsdc = asset(
            token: "USDC",
            chain: "base",
            decimals: 6,
            contractAddress: usdcContract.uppercased().replacingOccurrences(of: "0X", with: "0x")
        )
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)@8453/transfer?address=\(recipient)&uint256=2500000"
            )
        )

        #expect(request.resolveAsset(in: [baseUsdc], current: nil) == baseUsdc)
    }

    // MARK: - Amounts

    @Test func evmNativeValueIsAlwaysWeiRegardlessOfTheAssetDecimals() throws {
        // An EIP-681 native `value` is protocol-fixed at 18 decimals on every chain; only the ERC-20
        // `uint256` is in the token's own decimals. BNB@bsc is a bridge token whose decimals are
        // bridge-defined, so dividing the native value by them is wrong by that factor.
        let bnb = asset(token: "BNB", chain: "bsc", decimals: 8)
        let request = try #require(CrossPayRequestParser.parse("ethereum:\(recipient)@56?value=1e18"))

        #expect(request.resolveAsset(in: [bnb], current: nil) == bnb)
        #expect(request.resolvedAmount(for: bnb) == 1)
    }

    @Test func erc20ValueUsesTheTokenDecimals() throws {
        let baseUsdc = asset(token: "USDC", chain: "base", decimals: 6, contractAddress: usdcContract)
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)@8453/transfer?address=\(recipient)&uint256=2500000"
            )
        )

        #expect(request.resolvedAmount(for: baseUsdc) == Decimal(string: "2.5"))
    }

    @Test func amountIsUnavailableWithoutAResolvedAsset() throws {
        // An amount is only meaningful against the asset it was denominated in. Returning it for a
        // nil asset let the number survive a failed resolution and be re-denominated onto whatever
        // the user picked next -- 0.01 of an unknown SPL token became 0.01 SOL.
        let bitcoin = try #require(
            CrossPayRequestParser.parse("bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=0.015")
        )
        #expect(bitcoin.resolvedAmount(for: nil) == nil)

        let solana = try #require(
            CrossPayRequestParser.parse(
                "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=\(solanaMint)"
            )
        )
        #expect(solana.resolvedAmount(for: nil) == nil)
    }

    @Test func outOfRangeAssetDecimalsYieldNoAmount() throws {
        // `decimals` is read straight off the provider JSON with no range check. A negative value
        // used to trap building `0..<exponent`, and a very large one produced Decimal.nan, which the
        // formatter renders into the amount field as the literal string "NaN".
        let request = try #require(
            CrossPayRequestParser.parse(
                "ethereum:\(usdcContract)@8453/transfer?address=\(recipient)&uint256=2500000"
            )
        )

        #expect(request.resolvedAmount(for: asset(token: "USDC", chain: "base", decimals: -1, contractAddress: usdcContract)) == nil)
        #expect(request.resolvedAmount(for: asset(token: "USDC", chain: "base", decimals: 200, contractAddress: usdcContract)) == nil)
    }

    // MARK: - Rejections

    @Test func nonMainnetUtxoRequestsAreRejected() {
        // The SDK decodes `network` precisely so callers can reject these. SwapAndPay does no local
        // per-chain address validation, so a testnet address would otherwise resolve to the curated
        // mainnet asset and prefill an amount.
        #expect(CrossPayRequestParser.parse("bitcoin:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx?amount=0.1") == nil)
        #expect(CrossPayRequestParser.parse("bitcoin:bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080?amount=0.1") == nil)
        #expect(CrossPayRequestParser.parse("litecoin:tltc1qw508d6qejxtdg4y5r3zarvary0c5xw7klfsuq0?amount=0.1") == nil)
    }

    @Test func mainnetUtxoRequestsAreStillAccepted() {
        #expect(CrossPayRequestParser.parse("bitcoin:bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4?amount=0.1") != nil)
        #expect(CrossPayRequestParser.parse("litecoin:ltc1qw508d6qejxtdg4y5r3zarvary0c5xw7kgmn4n9?amount=0.1") != nil)
    }

    @Test func nonAddressEvmRecipientsAreRejected() {
        // The `eip681` crate accepts an ENS name, and a hex string of the wrong length, as a
        // recipient. The app has no ENS resolver and no validation downstream, so either would reach
        // the swap provider as a plausible-looking but unresolvable destination.
        #expect(CrossPayRequestParser.parse("ethereum:vitalik.eth?value=1e18") == nil)
        #expect(CrossPayRequestParser.parse("ethereum:0x\(String(repeating: "a", count: 64))?value=1e18") == nil)
        #expect(
            CrossPayRequestParser.parse(
                "ethereum:vitalik.eth/transfer?address=\(recipient)&uint256=2500000"
            ) == nil
        )
    }

    @Test func plainAddressIsNotReinterpretedAsAPaymentRequest() {
        #expect(CrossPayRequestParser.parse("bc1qplain") == nil)
    }

    @Test func unsupportedSchemeIsRejected() {
        #expect(CrossPayRequestParser.parse("near:alice.near") == nil)
    }

    @Test func solanaInteractiveTransactionRequestIsRejected() {
        #expect(CrossPayRequestParser.parse("solana:https://example.com/pay") == nil)
    }

    @Test func unrecognisedEip681MethodIsRejected() {
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
