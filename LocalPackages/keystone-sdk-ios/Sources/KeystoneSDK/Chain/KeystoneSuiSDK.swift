//
//  KeystoneSuiSDK.swift
//  
//
//  Created by Renfeng Shi on 2023/5/18.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneSuiSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> SuiSignature {
        let signResult = handle_error(
            get_result: { parse_sui_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: SuiSignature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(suiSignRequest: SuiSignRequest) throws -> UREncoder {
        let accountsJson = String(data: try jsonEncoder.encode(suiSignRequest.accounts), encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_sui_sign_request($0, suiSignRequest.requestId, suiSignRequest.intentMessage, accountsJson, suiSignRequest.origin)}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
