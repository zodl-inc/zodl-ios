//
//  KeystoneCardanoSDK.swift
//  
//
//  Created by LiYan on 5/22/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneCardanoSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> CardanoSignature {
        let signResult = handle_error(
            get_result: { parse_cardano_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: CardanoSignature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func generateSignRequest(cardanoSignRequest: CardanoSignRequest) throws -> UREncoder {
        let utxos = String(data: try jsonEncoder.encode(cardanoSignRequest.utxos), encoding: .utf8)
        let certKeys = String(data: try jsonEncoder.encode(cardanoSignRequest.certKeys), encoding: .utf8)
        let signRequest = handle_error(
            get_result: { generate_cardano_sign_request($0, cardanoSignRequest.requestId, cardanoSignRequest.signData, utxos, certKeys, cardanoSignRequest.origin) }
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
