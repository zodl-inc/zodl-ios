//
//  KeystoneNearSDK.swift
//  
//
//  Created by Renfeng Shi on 4/26/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneNearSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> NearSignature {
        let signResult = handle_error(
            get_result: { parse_near_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try parseUR(urString: signResult, ofType: NearSignature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(nearSignRequest: NearSignRequest) throws -> UREncoder {
        let signData = String(data: try jsonEncoder.encode(nearSignRequest.signData), encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_near_sign_request($0, nearSignRequest.requestId, signData, nearSignRequest.path, nearSignRequest.xfp, nearSignRequest.account, nearSignRequest.origin)}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
