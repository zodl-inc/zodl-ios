//
//  KeystoneZcashSDK.swift
//  KeystoneSDK
//
//  Created by Sora Li on 2024/11/26.
//

import Foundation
import URRegistryFFI
import URKit


public class KeystoneZcashSDK: KeystoneBaseSDK {
    public func parseZcashPczt(ur: UR) throws -> Data {
        let pcztString = handle_error(
            get_result: { parse_zcash_pczt($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        let pczt = try super.parseUR(urString: pcztString, ofType: PCZT.self, ofError: KeystoneError.parsePSBTError)
        return pczt.pczt.uppercased().hexadecimal
    }

    public func generateZcashPczt(pczt_hex: Data) throws -> UREncoder {
        let pczt = handle_error(
            get_result: { generate_zcash_pczt($0, pczt_hex.hexEncodedString())}
        )
        return try super.urStringToEncoder(urString: pczt, ofError: KeystoneError.generatePSBTError)
    }
}
