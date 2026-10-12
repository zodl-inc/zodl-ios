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

enum CrossPayScanResult: Equatable {
    case notPaymentRequest
    case paymentRequest(CrossPayRequest)
    case refusedPaymentRequest

    var request: CrossPayRequest? {
        guard case let .paymentRequest(request) = self else { return nil }
        return request
    }
}

enum CrossPayRequestParser {
    /// Separates ordinary addresses from payment requests the SDK or app refuses. Pay needs all
    /// three outcomes so a rejected URI cannot fall through to the legacy raw-address behavior.
    static func classify(_ value: String) -> CrossPayScanResult {
        #if ZODL_INTERNAL || SECANT_TESTNET
        // CashAddr includes its network prefix before a colon, but that prefix is part of the
        // address rather than a payment-URI scheme. Preserve the legacy raw-address path only for
        // fully validated mainnet P2PKH/P2SH addresses; malformed, testnet and unknown schemes
        // still fail closed below.
        if isMainnetCashAddress(value) {
            return .notPaymentRequest
        }

        guard let request = try? PaymentURIParser.parse(value) else {
            return URLComponents(string: value)?.scheme == nil
                ? .notPaymentRequest
                : .refusedPaymentRequest
        }

        let parsedRequest: CrossPayRequest?
        switch request {
        case let .bitcoin(request):
            parsedRequest = utxoRequest(request, chain: "btc")
        case let .ethereum(request):
            parsedRequest = parseEthereum(request)
        case let .litecoin(request):
            parsedRequest = utxoRequest(request, chain: "ltc")
        case let .solanaTransfer(request):
            parsedRequest = solanaRequest(request)
        case .solanaTransaction:
            parsedRequest = nil
        }

        return parsedRequest.map(CrossPayScanResult.paymentRequest) ?? .refusedPaymentRequest
        #else
        // Cross-pay is intentionally disabled in production builds for now. Preserve the legacy
        // behavior there by treating every scan as raw address input.
        return .notPaymentRequest
        #endif
    }

    static func parse(_ value: String) -> CrossPayRequest? {
        classify(value).request
    }

    /// The SDK decodes `network` precisely so callers can reject non-mainnet requests. The app only
    /// ever pays mainnet assets, and nothing downstream does per-chain address validation, so a
    /// testnet address would otherwise resolve to the curated mainnet asset and prefill an amount.
    private static func utxoRequest(_ request: UTXOPaymentURIRequest, chain: String) -> CrossPayRequest? {
        guard request.network == .mainnet else { return nil }

        let amount: CrossPayRequest.Amount?
        if let encodedAmount = request.amount {
            guard let value = decimal(encodedAmount) else { return nil }
            amount = .display(value)
        } else {
            amount = nil
        }

        return CrossPayRequest(
            address: request.address.value,
            amount: amount,
            assetReference: .native(chain: chain)
        )
    }

    /// References and memo are transaction instructions under Solana Pay. The current swap
    /// provider request carries only a destination address and amount, so accepting either would
    /// pay the merchant while silently dropping the metadata it needs to identify the invoice.
    private static func solanaRequest(_ request: SolanaPayTransferRequest) -> CrossPayRequest? {
        guard request.references.isEmpty, request.memo == nil else { return nil }

        let amount: CrossPayRequest.Amount?
        if let encodedAmount = request.amount {
            guard let value = decimal(encodedAmount) else { return nil }
            amount = .display(value)
        } else {
            amount = nil
        }

        let asset = request.splToken.map {
            CrossPayRequest.AssetReference.contract(chain: "sol", chainID: nil, address: $0.value)
        } ?? .native(chain: "sol")
        return CrossPayRequest(
            address: request.recipient.value,
            amount: amount,
            assetReference: asset
        )
    }

    private static func parseEthereum(_ request: Eip681TransactionRequest) -> CrossPayRequest? {
        switch request {
        case let .native(request):
            guard let recipient = evmAddress(request.recipientAddress) else { return nil }

            let amount: CrossPayRequest.Amount?
            if let encodedAmount = request.valueHex {
                guard let value = decimal(hex: encodedAmount) else { return nil }
                amount = .wei(value)
            } else {
                amount = nil
            }

            return CrossPayRequest(
                address: recipient,
                amount: amount,
                assetReference: .evmNative(chainID: request.chainId.map(String.init))
            )
        case let .erc20(request):
            guard let recipient = evmAddress(request.recipientAddress),
                  let contract = evmAddress(request.tokenContractAddress),
                  let value = decimal(hex: request.valueHex) else { return nil }
            return CrossPayRequest(
                address: recipient,
                amount: .tokenAtomic(value),
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
        return value.isNaN ? nil : value
    }

    /// Validates the ordinary mainnet CashAddr forms the app's BCH asset accepts as raw addresses.
    /// This is intentionally narrower than a `bitcoincash:` prefix allowlist: Pay has no later
    /// per-chain address validation, so checksum, canonical padding, type and payload size are all
    /// checked here before a colon-bearing scan bypasses payment-URI rejection.
    private static func isMainnetCashAddress(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let hasLowercase = bytes.contains { (97...122).contains($0) }
        let hasUppercase = bytes.contains { (65...90).contains($0) }
        guard !(hasLowercase && hasUppercase) else { return false }

        let components = value.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "bitcoincash" else { return false }

        let payloadBytes = Array(components[1].utf8)
        guard payloadBytes.count > 8 else { return false }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        let alphabetValues = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })
        let payload = payloadBytes.compactMap { alphabetValues[$0] }
        guard payload.count == payloadBytes.count else { return false }

        let prefix = Array("bitcoincash".utf8).map { $0 & 0x1f }
        guard cashAddressPolymod(prefix + [0] + payload) == 0 else { return false }

        let data = Array(payload.dropLast(8))
        guard let decoded = convertCashAddressBits(data), let version = decoded.first else { return false }
        guard version & 0x80 == 0 else { return false }

        let type = version >> 3
        guard type == 0 || type == 1 else { return false }
        let hashSizes = [20, 24, 28, 32, 40, 48, 56, 64]
        return decoded.count - 1 == hashSizes[Int(version & 0x07)]
    }

    private static func cashAddressPolymod(_ values: [UInt8]) -> UInt64 {
        let generators: [UInt64] = [
            0x98f2_bc8e_61,
            0x79b7_6d99_e2,
            0xf33e_5fb3_c4,
            0xae2e_abe2_a8,
            0x1e4f_43e4_70
        ]
        var checksum: UInt64 = 1
        for value in values {
            let top = checksum >> 35
            checksum = ((checksum & 0x07ff_ffff_ff) << 5) ^ UInt64(value)
            for index in generators.indices where (top >> index) & 1 != 0 {
                checksum ^= generators[index]
            }
        }
        return checksum ^ 1
    }

    /// Strict, canonical 5-to-8 conversion for the version byte plus address hash.
    private static func convertCashAddressBits(_ values: [UInt8]) -> [UInt8]? {
        var accumulator = 0
        var bitCount = 0
        var result: [UInt8] = []
        for value in values {
            guard value < 32 else { return nil }
            accumulator = ((accumulator << 5) | Int(value)) & 0x0fff
            bitCount += 5
            while bitCount >= 8 {
                bitCount -= 8
                result.append(UInt8((accumulator >> bitCount) & 0xff))
            }
        }

        guard bitCount < 5 else { return nil }
        guard bitCount == 0 || ((accumulator << (8 - bitCount)) & 0xff) == 0 else { return nil }
        return result
    }
}
