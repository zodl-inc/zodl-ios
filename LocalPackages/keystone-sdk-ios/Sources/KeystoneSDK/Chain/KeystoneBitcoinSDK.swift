//
//  KeystoneBitcoinSDK.swift
//  
//
//  Created by LiYan on 3/30/23.
//

import Foundation
import URRegistryFFI
import URKit

public class KeystoneBitcoinSDK: KeystoneBaseSDK {
    public func parsePSBT(ur: UR) throws -> Data {
        let psbtURString = handle_error(
            get_result: { parse_crypto_psbt($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )

        let psbt = try super.parseUR(urString: psbtURString, ofType: PSBT.self, ofError: KeystoneError.parsePSBTError)
        return psbt.psbt.uppercased().hexadecimal
    }

    public func generatePSBT(psbt: Data) throws -> UREncoder {
        let psbt = handle_error(
            get_result: { generate_crypto_psbt($0, psbt.hexEncodedString())}
        )
        return try super.urStringToEncoder(urString: psbt, ofError: KeystoneError.generatePSBTError)
    }
}
