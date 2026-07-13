//
//  KeystoneDashSDK.swift
//  
//
//  Created by LiYan on 4/21/23.
//

import Foundation
import URRegistryFFI
import URKit

public class KeystoneDashSDK: KeystoneCommonSDK {
    public func generateSignRequest(keystoneSignRequest: KeystoneSignRequest<UtxoBaseTransaction>) throws -> UREncoder {
        return try super.genSignRequest(coinType: .dash, keystoneSignRequest: keystoneSignRequest)
    }
}
