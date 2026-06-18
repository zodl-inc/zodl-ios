//
//  EthereumSDK.swift
//  
//
//  Created by LiYan on 3/27/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneEthereumSDK: KeystoneBaseSDK {
    public func parseSignature(ur: UR) throws -> Signature {
        let signResult = handle_error(
            get_result: { parse_eth_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseSignature(signResult: signResult)
    }

    public func generateSignRequest(ethSignRequest: EthSignRequest) throws -> UREncoder {
        let signRequest = handle_error(
            get_result: { generate_eth_sign_request($0, ethSignRequest.requestId, ethSignRequest.signData, ethSignRequest.dataType.rawValue, ethSignRequest.chainId, ethSignRequest.path, ethSignRequest.xfp, ethSignRequest.address, ethSignRequest.origin)}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
