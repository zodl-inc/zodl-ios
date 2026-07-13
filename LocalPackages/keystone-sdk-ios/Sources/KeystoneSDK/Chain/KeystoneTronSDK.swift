//
//  KeystoneTronSDK.swift
//  
//
//  Created by LiYan on 4/12/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneTronSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> TronSignature {
        let signResult = handle_error(
            get_result: { parse_tron_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: TronSignature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(tronSignRequest: TronSignRequest) throws -> UREncoder {
        let tokenInfoData = try JSONEncoder().encode(tronSignRequest.tokenInfo)
        let tokenInfo = String(data: tokenInfoData, encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_tron_sign_request($0, tronSignRequest.requestId, tronSignRequest.signData, tronSignRequest.path, tronSignRequest.xfp, tokenInfo, tronSignRequest.origin, Date.currentTimestamp())}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
