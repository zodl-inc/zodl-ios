//
//  KeystoneSDK.swift
//
//
//  Created by LiYan on 21/3/2023.
//

import Foundation
import URRegistryFFI
import URKit

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}


public class KeystoneSDK {
    public lazy var sol: KeystoneSolanaSDK = {
        return KeystoneSolanaSDK()
    }()
    public lazy var eth: KeystoneEthereumSDK = {
        return KeystoneEthereumSDK()
    }()
    public lazy var btc: KeystoneBitcoinSDK = {
        return KeystoneBitcoinSDK()
    }()
    public lazy var cosmos: KeystoneCosmosSDK = {
       return KeystoneCosmosSDK()
    }()
    public lazy var evm: KeystoneEvmSDK = {
       return KeystoneEvmSDK()
    }()
    public lazy var tron: KeystoneTronSDK = {
       return KeystoneTronSDK()
    }()
    public lazy var aptos: KeystoneAptosSDK = {
       return KeystoneAptosSDK()
    }()
    public lazy var ltc: KeystoneLitecoinSDK = {
        return KeystoneLitecoinSDK()
    }()
    public lazy var dash: KeystoneDashSDK = {
        return KeystoneDashSDK()
    }()
    public lazy var bch: KeystoneBchSDK = {
        return KeystoneBchSDK()
    }()
    public lazy var near: KeystoneNearSDK = {
        return KeystoneNearSDK()
    }()
    public lazy var arweave: KeystoneArweaveSDK = {
        return KeystoneArweaveSDK()
    }()
    public lazy var sui: KeystoneSuiSDK = {
        return KeystoneSuiSDK()
    }()
    public lazy var cardano: KeystoneCardanoSDK = {
        return KeystoneCardanoSDK()
    }()


    private let wallet: KeystoneWallet = KeystoneWallet()
    private var urDecoder: URDecoder = URDecoder()

    public static var maxFragmentLen = 200;

    public init(){}

    public func decodeQR(qrCode: String) throws -> DecodeResult {
        let isReceiveSucceed = urDecoder.receivePart(qrCode)
        switch urDecoder.result {
            case .success(let ur):
                return DecodeResult(progress: 100, ur: ur)
            case .failure:
                resetQRDecoder()
                throw QRCodeError.invalidQRCode
            case nil:
                if isReceiveSucceed {
                    let progress = Int(urDecoder.estimatedPercentComplete * 100)
                    return DecodeResult(progress: progress)
                } else {
                    resetQRDecoder()
                    throw QRCodeError.unexpectedQRCode
                }
        }
    }

    public func resetQRDecoder(){
        urDecoder = URDecoder()
    }

    // Sync Keystone hardware wallet
    public func parseMultiAccounts(ur: UR) throws -> MultiAccounts {
        return try wallet.parseMultiAccounts(ur: ur)
    }
    
    public func parseZcashAccounts(ur: UR) throws -> ZcashAccounts {
        return try wallet.parseZcashAccounts(ur: ur)
    }
}
