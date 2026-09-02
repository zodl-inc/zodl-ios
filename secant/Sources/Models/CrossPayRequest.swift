import Foundation
import ZcashLightClientKit

/// A cross-chain payment request resolved from a validated `PaymentURIRequest` (SDK) into a
/// concrete, app-known `SwapAsset`. Covers Bitcoin and Litecoin on-chain transfers, EVM native
/// and ERC-20 transfers across the chains in `evmChainsByID` below, and Solana native/SPL-token
/// transfers. Solana interactive transaction-request links (`.solanaTransaction`), non-mainnet
/// UTXO requests and unrecognised EIP-681 requests are explicitly out of scope and rejected
/// during parsing -- see `CrossPayRequestParser.parse`.
struct CrossPayRequest: Equatable {
    enum Amount: Equatable {
        /// Already in whole units: BIP-21 `amount`, Solana Pay `amount`.
        case display(Decimal)
        /// EIP-681 native `value`. Fixed at 18 decimals by the protocol on every chain,
        /// independent of whatever decimals the matched asset happens to carry.
        case wei(Decimal)
        /// EIP-681 ERC-20 `uint256`, denominated in the token's own decimals.
        case tokenAtomic(Decimal)
    }

    enum AssetReference: Equatable {
        case native(chain: String)
        case evmNative(chainID: String?)
        case contract(chain: String?, chainID: String?, address: String)
    }

    let address: String
    let amount: Amount?
    let assetReference: AssetReference

    func resolveAsset(in assets: some Collection<SwapAsset>, current: SwapAsset?) -> SwapAsset? {
        let candidates: [SwapAsset]

        switch assetReference {
        case let .native(chain):
            candidates = Self.nativeCandidates(in: assets, chain: chain)

        case let .evmNative(chainID):
            guard let chain = Self.resolvedChain(chain: nil, chainID: chainID) else { return nil }
            candidates = Self.nativeCandidates(in: assets, chain: chain)

        case let .contract(chain, chainID, address):
            guard let resolvedChain = Self.resolvedChain(chain: chain, chainID: chainID) else { return nil }
            // Base58 is case-sensitive, so a case-mangled Solana mint is a different mint and must
            // not match; EIP-55 hex is a checksum over the same value, so it must.
            let caseInsensitive = Self.evmChainTickers.contains(resolvedChain.lowercased())
            candidates = assets.filter { asset in
                asset.chain.caseInsensitiveCompare(resolvedChain) == .orderedSame
                    && Self.addressesMatch(asset.contractAddress, address, caseInsensitive: caseInsensitive)
            }
        }

        if let current, candidates.contains(current) {
            return current
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func resolvedAmount(for asset: SwapAsset?) -> Decimal? {
        // An amount is only meaningful against the asset it was denominated in. Returning it for a
        // nil asset lets the number survive a failed resolution and be re-denominated onto whatever
        // the user (or the asset-list default) picks next.
        guard let amount, let asset else { return nil }

        switch amount {
        case let .display(value):
            return value
        case let .wei(value):
            return Self.powerOfTen(Self.weiDecimals).map { value / $0 }
        case let .tokenAtomic(value):
            return Self.powerOfTen(asset.decimals).map { value / $0 }
        }
    }

    private static func nativeCandidates(
        in assets: some Collection<SwapAsset>,
        chain: String
    ) -> [SwapAsset] {
        let natives = nativeTokens(for: chain)
        return assets.filter {
            $0.chain.caseInsensitiveCompare(chain) == .orderedSame
                && natives.contains($0.token.lowercased())
        }
    }

    private static func addressesMatch(_ lhs: String?, _ rhs: String, caseInsensitive: Bool) -> Bool {
        guard let lhs else { return false }
        return caseInsensitive ? lhs.caseInsensitiveCompare(rhs) == .orderedSame : lhs == rhs
    }

    // Known duplication (MOB-1751 review): this table is hand-duplicated in the Android app's
    // CrossPayRequest.kt (EVM_CHAINS). See https://github.com/zodl-inc/zodl-android/pull/2457
    // and https://github.com/zodl-inc/zodl-ios/pull/2002 for the tracked follow-up to collapse
    // this into one shared source.
    private static let evmChainsByID: [String: String] = [
        "1": "eth",
        "10": "op",
        "56": "bsc",
        "137": "pol",
        "196": "xlayer",
        "8453": "base",
        "42161": "arb",
        "43114": "avax"
    ]

    private static let evmChainTickers = Set(evmChainsByID.values)

    /// EIP-681 says a request without `@chain_id` targets "the client's current network setting".
    /// This app has no such setting -- `selectedAsset` is a swap-payout preference left over from
    /// an unrelated earlier swap, and resolving against it made the same QR mean different assets
    /// (and wildly different values) depending on app state. Ethereum mainnet is the universal
    /// default network and keeps resolution a pure function of the URI.
    private static let defaultEvmChain = "eth"

    /// The protocol-fixed denomination of an EIP-681 native `value`, on every chain.
    private static let weiDecimals = 18

    /// `chain` is an explicit, already-trusted ticker from the parser (Solana's literal "sol");
    /// `chainID` is the EIP-681 numeric id, and an id we don't recognise resolves to nothing
    /// rather than silently falling back.
    private static func resolvedChain(chain: String?, chainID: String?) -> String? {
        if let chainID {
            return evmChainsByID[chainID]
        }
        return chain ?? defaultEvmChain
    }

    private static func nativeTokens(for chain: String) -> Set<String> {
        switch chain.lowercased() {
        // Optimism's native asset is ETH; OP itself is an ERC-20 governance token.
        case "arb", "base", "op": ["eth"]
        case "bsc": ["bnb"]
        case "pol": ["matic", "pol"]
        case "xlayer": ["okb"]
        default: [chain.lowercased()]
        }
    }

    /// `nil` outside the range `Decimal` can represent; `pow` returns `NaN` past 10^127, which
    /// otherwise formats into the amount field as the literal string "NaN".
    private static func powerOfTen(_ exponent: Int) -> Decimal? {
        guard (0...127).contains(exponent) else { return nil }
        return pow(Decimal(10), exponent)
    }
}

enum CrossPayRequestParser {
    static func parse(_ value: String) -> CrossPayRequest? {
        guard let request = try? PaymentURIParser.parse(value) else { return nil }
        switch request {
        case let .bitcoin(request):
            return utxoRequest(request, chain: "btc")
        case let .ethereum(request):
            return parseEthereum(request)
        case let .litecoin(request):
            return utxoRequest(request, chain: "ltc")
        case let .solanaTransfer(request):
            let asset = request.splToken.map {
                CrossPayRequest.AssetReference.contract(chain: "sol", chainID: nil, address: $0.value)
            } ?? .native(chain: "sol")
            return CrossPayRequest(
                address: request.recipient.value,
                amount: decimal(request.amount).map(CrossPayRequest.Amount.display),
                assetReference: asset
            )
        case .solanaTransaction:
            return nil
        }
    }

    /// The SDK decodes `network` precisely so callers can reject non-mainnet requests. The app only
    /// ever pays mainnet assets, and nothing downstream does per-chain address validation, so a
    /// testnet address would otherwise resolve to the curated mainnet asset and prefill an amount.
    private static func utxoRequest(_ request: UTXOPaymentURIRequest, chain: String) -> CrossPayRequest? {
        guard request.network == .mainnet else { return nil }
        return CrossPayRequest(
            address: request.address.value,
            amount: decimal(request.amount).map(CrossPayRequest.Amount.display),
            assetReference: .native(chain: chain)
        )
    }

    private static func parseEthereum(_ request: Eip681TransactionRequest) -> CrossPayRequest? {
        switch request {
        case let .native(request):
            guard let recipient = evmAddress(request.recipientAddress) else { return nil }
            return CrossPayRequest(
                address: recipient,
                amount: decimal(hex: request.valueHex).map(CrossPayRequest.Amount.wei),
                assetReference: .evmNative(chainID: request.chainId.map(String.init))
            )
        case let .erc20(request):
            guard let recipient = evmAddress(request.recipientAddress),
                  let contract = evmAddress(request.tokenContractAddress) else { return nil }
            return CrossPayRequest(
                address: recipient,
                amount: decimal(hex: request.valueHex).map(CrossPayRequest.Amount.tokenAtomic),
                assetReference: .contract(
                    chain: nil,
                    chainID: request.chainId.map(String.init),
                    address: contract
                )
            )
        case .unrecognised:
            return nil
        }
    }

    /// The `eip681` crate accepts an ENS name, and a hex string of the wrong length, as a recipient
    /// (`AddressOrEnsName::parse` only rejects a bad ERC-55 checksum). The app has no ENS resolver
    /// and no validation downstream, so anything that isn't a 20-byte hex address is rejected here
    /// rather than handed to the swap provider as a plausible-looking destination.
    private static func evmAddress(_ value: String) -> String? {
        guard value.hasPrefix("0x") else { return nil }
        let digits = value.dropFirst(2)
        guard digits.count == 40, digits.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func decimal(_ amount: PaymentURIAmount?) -> Decimal? {
        amount.flatMap { Decimal(string: $0.value, locale: Locale(identifier: "en_US_POSIX")) }
    }

    /// Fails closed on anything that isn't hex. Coercing a bad digit to zero turned `"0x1g"` into
    /// 16 and a bare `"0x"` into an explicit zero amount, which are wrong numbers rather than
    /// rejections. Unreachable while the SDK validates the field, but nothing here asserts that.
    private static func decimal(hex: String?) -> Decimal? {
        guard let hex, hex.lowercased().hasPrefix("0x") else { return nil }
        let digits = hex.dropFirst(2)
        guard !digits.isEmpty else { return nil }

        var value = Decimal.zero
        for character in digits {
            guard let digit = character.hexDigitValue else { return nil }
            value = value * 16 + Decimal(digit)
        }
        return value
    }
}
