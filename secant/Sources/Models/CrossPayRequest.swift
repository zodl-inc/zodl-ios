import Foundation
import ZcashLightClientKit

/// A cross-chain payment request resolved from a validated `PaymentURIRequest` (SDK) into a
/// concrete, app-known `SwapAsset`. Covers Bitcoin and Litecoin on-chain transfers, EVM native
/// and ERC-20 transfers across the chains in `evmChainsByID` below, and Solana native/SPL-token
/// transfers. Solana interactive transaction-request links (`.solanaTransaction`) and
/// unrecognised EIP-681 requests are explicitly out of scope and rejected during parsing --
/// see `CrossPayRequestParser.parse`.
struct CrossPayRequest: Equatable {
    enum Amount: Equatable {
        case display(Decimal)
        case atomic(Decimal)
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
            candidates = assets.filter {
                $0.chain.caseInsensitiveCompare(chain) == .orderedSame
                    && Self.nativeTokens(for: chain).contains($0.token.lowercased())
            }

        case let .evmNative(chainID):
            // Fall back to the currently-selected asset's chain only when it's actually an EVM
            // chain. Without this, a SOL/BTC/LTC asset selected as `current` would pass through
            // untouched (nativeTokens' permissive default matches any chain string against
            // itself), silently pairing a native-EVM payment request with a non-EVM asset.
            let chain = Self.resolvedEvmChain(chainID: chainID, fallback: Self.evmChainIfKnown(current?.chain))
            guard let chain else { return nil }
            candidates = assets.filter {
                $0.chain.caseInsensitiveCompare(chain) == .orderedSame
                    && Self.nativeTokens(for: chain).contains($0.token.lowercased())
            }

        case let .contract(chain, chainID, address):
            // When the request carries no chain id at all (every ERC-20 request: EIP-681 has no
            // `chain` string, only a numeric chainId), fall back to the currently-selected asset's
            // chain, same as `.evmNative`. Without this, a token contract address shared across
            // chains (a common CREATE2 deployment pattern) would match on ANY chain the wallet
            // knows about instead of the one the request actually meant. `chain` (e.g. Solana's
            // literal "sol") is an explicit, already-trusted value from the parser, not something
            // that needs the same EVM-chain validation as the `current`-derived fallback.
            let resolvedChain = Self.resolvedEvmChain(chainID: chainID, fallback: chain ?? Self.evmChainIfKnown(current?.chain))
            guard chainID == nil || resolvedChain != nil else { return nil }
            guard let resolvedChain else { return nil }
            candidates = assets.filter { asset in
                asset.chain.caseInsensitiveCompare(resolvedChain) == .orderedSame
                    && asset.contractAddress?.caseInsensitiveCompare(address) == .orderedSame
            }
        }

        if let current, candidates.contains(current) {
            return current
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func resolvedAmount(for asset: SwapAsset?) -> Decimal? {
        guard let amount else { return nil }
        switch amount {
        case let .display(value):
            return value
        case let .atomic(value):
            guard let asset else { return nil }
            return value / Self.powerOfTen(asset.decimals)
        }
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

    private static func evmChain(for chainID: String) -> String? {
        evmChainsByID[chainID]
    }

    /// Returns `chain` unchanged if it's a recognized EVM chain ticker, else `nil`. Used to guard
    /// the currently-selected-asset fallback in `resolveAsset`: `current` may be on any chain
    /// (SOL, BTC, LTC, ...), and only an EVM one is a valid disambiguation for an EVM request
    /// with no explicit chain id.
    private static func evmChainIfKnown(_ chain: String?) -> String? {
        guard let chain = chain?.lowercased(), evmChainTickers.contains(chain) else { return nil }
        return chain
    }

    private static func resolvedEvmChain(chainID: String?, fallback: String?) -> String? {
        guard let chainID else { return fallback }
        return evmChain(for: chainID)
    }

    private static func nativeTokens(for chain: String) -> Set<String> {
        switch chain.lowercased() {
        case "arb", "base": ["eth"]
        case "bsc": ["bnb"]
        case "op": ["eth", "op"]
        case "pol": ["matic", "pol"]
        case "xlayer": ["okb"]
        default: [chain.lowercased()]
        }
    }

    private static func powerOfTen(_ exponent: Int) -> Decimal {
        (0..<exponent).reduce(Decimal(1)) { value, _ in value * 10 }
    }
}

enum CrossPayRequestParser {
    static func parse(_ value: String) -> CrossPayRequest? {
        guard let request = try? PaymentURIParser.parse(value) else { return nil }
        switch request {
        case let .bitcoin(request):
            return CrossPayRequest(
                address: request.address.value,
                amount: decimal(request.amount).map(CrossPayRequest.Amount.display),
                assetReference: .native(chain: "btc")
            )
        case let .ethereum(request):
            return parseEthereum(request)
        case let .litecoin(request):
            return CrossPayRequest(
                address: request.address.value,
                amount: decimal(request.amount).map(CrossPayRequest.Amount.display),
                assetReference: .native(chain: "ltc")
            )
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

    private static func parseEthereum(_ request: Eip681TransactionRequest) -> CrossPayRequest? {
        switch request {
        case let .native(request):
            return CrossPayRequest(
                address: request.recipientAddress,
                amount: decimal(hex: request.valueHex).map(CrossPayRequest.Amount.atomic),
                assetReference: .evmNative(chainID: request.chainId.map(String.init))
            )
        case let .erc20(request):
            return CrossPayRequest(
                address: request.recipientAddress,
                amount: decimal(hex: request.valueHex).map(CrossPayRequest.Amount.atomic),
                assetReference: .contract(
                    chain: nil,
                    chainID: request.chainId.map(String.init),
                    address: request.tokenContractAddress
                )
            )
        case .unrecognised:
            return nil
        }
    }

    private static func decimal(_ amount: PaymentURIAmount?) -> Decimal? {
        amount.flatMap { Decimal(string: $0.value, locale: Locale(identifier: "en_US_POSIX")) }
    }

    private static func decimal(hex: String?) -> Decimal? {
        guard let hex, hex.lowercased().hasPrefix("0x") else { return nil }
        return hex.dropFirst(2).reduce(Decimal.zero) { value, character in
            value * 16 + Decimal(character.hexDigitValue ?? 0)
        }
    }
}
