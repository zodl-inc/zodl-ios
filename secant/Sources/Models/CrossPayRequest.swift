import Foundation
import ZcashLightClientKit

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
            let chain = Self.resolvedEvmChain(chainID: chainID, fallback: current?.chain.lowercased())
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
            // knows about instead of the one the request actually meant.
            let resolvedChain = Self.resolvedEvmChain(chainID: chainID, fallback: chain ?? current?.chain.lowercased())
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

    private static func evmChain(for chainID: String) -> String? {
        [
            "1": "eth",
            "10": "op",
            "56": "bsc",
            "137": "pol",
            "196": "xlayer",
            "8453": "base",
            "42161": "arb",
            "43114": "avax"
        ][chainID]
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
