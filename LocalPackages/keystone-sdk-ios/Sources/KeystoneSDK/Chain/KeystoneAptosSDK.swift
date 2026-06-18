//
//  KeystoneAptosSDK.swift
//  
//
//  Created by LiYan on 4/17/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneAptosSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> AptosSignature {
        let signResult = handle_error(
            get_result: { parse_aptos_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: AptosSignature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(aptosSignRequest: AptosSignRequest) throws -> UREncoder {
        let accountsJson = String(data: try jsonEncoder.encode(aptosSignRequest.accounts), encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_aptos_sign_request($0, aptosSignRequest.requestId, aptosSignRequest.signData, accountsJson, aptosSignRequest.origin, aptosSignRequest.signType.rawValue)}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
