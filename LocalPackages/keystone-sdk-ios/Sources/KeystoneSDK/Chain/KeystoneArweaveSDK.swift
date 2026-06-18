//
//  KeystoneArweaveSDK.swift
//
//
//  Created by LiYan on 4/27/23.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneArweaveSDK: KeystoneBaseSDK {

    public func parseSignature(ur: UR) throws -> Signature {
        let signResult = handle_error(
            get_result: { parse_arweave_signature($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: Signature.self, ofError: KeystoneError.parseSignatureError)
    }

    public func parseAccount(ur: UR) throws -> ArweaveAccount {
        let signResult = handle_error(
            get_result: { parse_arweave_account($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: signResult, ofType: ArweaveAccount.self, ofError: KeystoneError.syncAccountsError)
    }

    public func generateSignRequest(arweaveSignRequest: ArweaveSignRequest) throws -> UREncoder {
        let signRequest = handle_error(
            get_result: { generate_arweave_sign_request($0, arweaveSignRequest.requestId, arweaveSignRequest.signData, arweaveSignRequest.signType.rawValue, arweaveSignRequest.saltLen.rawValue, arweaveSignRequest.masterFingerprint, arweaveSignRequest.account, arweaveSignRequest.origin)}
        )
        return try super.generateSignRequest(signRequest: signRequest)
    }
}
