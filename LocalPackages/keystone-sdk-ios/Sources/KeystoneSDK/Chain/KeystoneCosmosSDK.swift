//
//  KeystoneCosmosSDK.swift
//
//
//  Created by Renfeng Shi on 4/6/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneCosmosSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> CosmosSignature {
        let signResult = handle_error(
            get_result: { parse_cosmos_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: CosmosSignature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(cosmosSignRequest: CosmosSignRequest) throws -> UREncoder {
        let accountsJson = String(data: try jsonEncoder.encode(cosmosSignRequest.accounts), encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_cosmos_sign_request($0, cosmosSignRequest.requestId, cosmosSignRequest.signData, cosmosSignRequest.dataType.rawValue, accountsJson, cosmosSignRequest.origin) }
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
