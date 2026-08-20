import Foundation

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
            let resolvedChain = Self.resolvedEvmChain(chainID: chainID, fallback: chain)
            guard chainID == nil || resolvedChain != nil else { return nil }
            candidates = assets.filter { asset in
                (resolvedChain.map { asset.chain.caseInsensitiveCompare($0) == .orderedSame } ?? true)
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
        case "arb", "base", "eth": ["eth"]
        case "avax": ["avax"]
        case "bch": ["bch"]
        case "bsc": ["bnb"]
        case "btc": ["btc"]
        case "dash": ["dash"]
        case "doge": ["doge"]
        case "ltc": ["ltc"]
        case "near": ["near", "wnear"]
        case "op": ["eth", "op"]
        case "pol": ["matic", "pol"]
        case "sol": ["sol"]
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }

        let scheme = trimmed[..<separator].lowercased()
        let payload = String(trimmed[trimmed.index(after: separator)...])

        switch scheme {
        case "bitcoin": return parseBitcoinLike(payload, chain: "btc")
        case "bitcoincash": return parseBitcoinLike(payload, chain: "bch", preserveScheme: true)
        case "dash": return parseBitcoinLike(payload, chain: "dash")
        case "dogecoin": return parseBitcoinLike(payload, chain: "doge")
        case "ethereum": return parseEthereum(payload)
        case "litecoin": return parseBitcoinLike(payload, chain: "ltc")
        case "near": return parseNear(payload)
        case "solana": return parseSolana(payload)
        default: return nil
        }
    }

    private static func parseBitcoinLike(
        _ payload: String,
        chain: String,
        preserveScheme: Bool = false
    ) -> CrossPayRequest? {
        let (target, query) = splitQuery(payload)
        let addressValue = target.removingPrefix("//").removingPercentEncoding ?? target.removingPrefix("//")
        guard !addressValue.isEmpty else { return nil }
        let params = queryParameters(query)
        let address = preserveScheme ? "bitcoincash:\(addressValue)" : addressValue
        return CrossPayRequest(
            address: address,
            amount: decimal(params["amount"]).map(CrossPayRequest.Amount.display),
            assetReference: .native(chain: chain)
        )
    }

    private static func parseEthereum(_ payload: String) -> CrossPayRequest? {
        let (targetAndFunction, query) = splitQuery(payload.removingPrefix("pay-"))
        let segments = targetAndFunction.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var targetAndChain = String(segments[0])
        let function = segments.count == 2 ? String(segments[1]).lowercased() : nil
        var chainID: String?

        if let chainSeparator = targetAndChain.lastIndex(of: "@") {
            chainID = String(targetAndChain[targetAndChain.index(after: chainSeparator)...])
            targetAndChain = String(targetAndChain[..<chainSeparator])
        }

        guard !targetAndChain.isEmpty, chainID?.allSatisfy(\.isNumber) != false else { return nil }
        let params = queryParameters(query)

        if function == nil || function?.isEmpty == true {
            return CrossPayRequest(
                address: targetAndChain,
                amount: decimal(params["value"]).map(CrossPayRequest.Amount.atomic),
                assetReference: .evmNative(chainID: chainID)
            )
        }

        guard function == "transfer",
              isHexAddress(targetAndChain),
              let recipient = params["address"],
              isHexAddress(recipient) else { return nil }

        return CrossPayRequest(
            address: recipient,
            amount: decimal(params["uint256"]).map(CrossPayRequest.Amount.atomic),
            assetReference: .contract(chain: nil, chainID: chainID, address: targetAndChain)
        )
    }

    private static func parseSolana(_ payload: String) -> CrossPayRequest? {
        let (target, query) = splitQuery(payload)
        let address = target.removingPrefix("//").removingPercentEncoding ?? target.removingPrefix("//")
        guard !address.isEmpty, URL(string: address)?.scheme == nil else { return nil }
        let params = queryParameters(query)
        let reference = params["spl-token"].map {
            CrossPayRequest.AssetReference.contract(chain: "sol", chainID: nil, address: $0)
        } ?? .native(chain: "sol")
        return CrossPayRequest(
            address: address,
            amount: decimal(params["amount"]).map(CrossPayRequest.Amount.display),
            assetReference: reference
        )
    }

    private static func parseNear(_ payload: String) -> CrossPayRequest? {
        let (target, query) = splitQuery(payload)
        let address = target.removingPrefix("//").removingPercentEncoding ?? target.removingPrefix("//")
        guard !address.isEmpty else { return nil }
        return CrossPayRequest(
            address: address,
            amount: decimal(queryParameters(query)["amount"]).map(CrossPayRequest.Amount.display),
            assetReference: .native(chain: "near")
        )
    }

    private static func splitQuery(_ value: String) -> (String, String?) {
        guard let separator = value.firstIndex(of: "?") else { return (value, nil) }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }

    private static func queryParameters(_ query: String?) -> [String: String] {
        guard let query else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = query
        return components.queryItems?.reduce(into: [:]) { result, item in
            guard result[item.name.lowercased()] == nil, let value = item.value else { return }
            result[item.name.lowercased()] = value
        } ?? [:]
    }

    private static func decimal(_ value: String?) -> Decimal? {
        guard let value else { return nil }
        let number = NSDecimalNumber(string: value, locale: Locale(identifier: "en_US_POSIX"))
        return number == .notANumber || number.compare(NSDecimalNumber.zero) == .orderedAscending
            ? nil
            : number.decimalValue
    }

    private static func isHexAddress(_ value: String) -> Bool {
        value.count == 42
            && value.lowercased().hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
