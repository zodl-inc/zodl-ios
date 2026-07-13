//
//  KeystoneWallet.swift
//  
//
//  Created by LiYan on 3/27/23.
//

import Foundation
import URRegistryFFI
import URKit

public class KeystoneWallet: KeystoneBaseSDK {
    func parseMultiAccounts(ur: UR) throws -> MultiAccounts {
        let multiAccounts = handle_error(
            get_result: { parse_crypto_multi_accounts($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: multiAccounts, ofType: MultiAccounts.self, ofError: KeystoneError.syncAccountsError)
    }
    
    func parseZcashAccounts(ur: UR) throws -> ZcashAccounts {
        let zcashAccounts = handle_error(
            get_result: { parse_zcash_accounts($0, ur.type, ur.cbor.cborData.hexEncodedString()) }
        )
        return try super.parseUR(urString: zcashAccounts, ofType: ZcashAccounts.self, ofError: KeystoneError.syncAccountsError)
    }
}
