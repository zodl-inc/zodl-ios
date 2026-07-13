//
//  KeystoneSDKSolanaSDK.swift
//  
//
//  Created by LiYan on 3/21/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneSolanaSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> Signature {
        let signResult = handle_error(
            get_result: { parse_sol_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseSignature(signResult: signResult)
    }

    public func generateSignRequest(solSignRequest: SolSignRequest) throws -> UREncoder {
        let signRequest = handle_error(
            get_result: { generate_sol_sign_request($0, solSignRequest.requestId, solSignRequest.signData, solSignRequest.path, solSignRequest.xfp, solSignRequest.address, solSignRequest.origin, solSignRequest.signType.rawValue)}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
