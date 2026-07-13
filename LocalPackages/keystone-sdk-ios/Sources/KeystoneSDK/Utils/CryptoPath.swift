//
//  CryptoPath.swift
//  
//
//  Created by LiYan on 8/21/23.
//

import Foundation
import URRegistryFFI

public class CryptoPath {
    public static func parseHDPath(hdPath: String) -> HDPath {
        let parseHDPath = handle_error(
            get_result: { parse_hd_path($0, hdPath) }
        )
        return try! KeystoneBaseSDK().jsonDecoder.decode(HDPath.self, from: Data(parseHDPath.utf8))
    }
}
