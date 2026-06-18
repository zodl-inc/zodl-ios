//
//  KeystoneEvmSDK.swift
//  
//
//  Created by Renfeng Shi on 2023/7/17.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneEvmSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> Signature {
        let signResult = handle_error(
            get_result: { parse_evm_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: Signature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(evmSignRequest: EvmSignRequest) throws -> UREncoder {
        let accountsJson = String(data: try jsonEncoder.encode(evmSignRequest.account), encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_evm_sign_request($0, evmSignRequest.requestId, evmSignRequest.signData, evmSignRequest.dataType.rawValue, evmSignRequest.customChainIdentifier, accountsJson, evmSignRequest.origin) }
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
