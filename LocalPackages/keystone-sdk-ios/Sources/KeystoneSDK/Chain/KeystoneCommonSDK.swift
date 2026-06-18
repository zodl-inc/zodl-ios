//
//  KeystoneCommonSDK.swift
//  
//
//  Created by LiYan on 4/21/23.
//

import Foundation
import URRegistryFFI
import URKit

extension Date {
    static var currentTimestamp: (() -> Int64) = {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public class KeystoneCommonSDK: KeystoneBaseSDK {
    public enum CoinType: Int32, Codable {
        case ltc = 2
        case dash = 5
        case bch = 145
    }

    public func parseSignResult(ur: UR) throws -> TransactionSignResult {
        let signResult = handle_error(
            get_result: { parse_keystone_sign_result($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: TransactionSignResult.self, ofError: KeystoneError.parseSignatureError)
    }

    public func genSignRequest<T>(coinType: CoinType, keystoneSignRequest: KeystoneSignRequest<T>) throws -> UREncoder {
        let signData = String(data: try jsonEncoder.encode(keystoneSignRequest.signData), encoding: .utf8)!
        let timestamp = Date.currentTimestamp()
        let signRequest = handle_error(
            get_result: { generate_keystone_sign_request($0, keystoneSignRequest.requestId, coinType.rawValue, signData, keystoneSignRequest.xfp, keystoneSignRequest.origin, timestamp) }
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
