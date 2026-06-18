//
//  KeystoneBchSDK.swift
//
//
//  Created by LiYan on 4/21/23.
//

import Foundation
import URRegistryFFI
import URKit

public class KeystoneBchSDK: KeystoneCommonSDK {
    public func generateSignRequest(keystoneSignRequest: KeystoneSignRequest<UtxoBaseTransaction>) throws -> UREncoder {
        return try super.genSignRequest(coinType: .bch, keystoneSignRequest: keystoneSignRequest)
    }
}
