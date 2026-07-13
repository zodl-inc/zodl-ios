//
//  KeystoneError.swift
//  
//
//  Created by LiYan on 3/22/23.
//

import Foundation

public enum KeystoneError: Swift.Error, Equatable {
    case internalError
    case syncAccountsError(String)
    case parseSignatureError(String)
    case generateSignRequestError(String)
    case parsePSBTError(String)
    case generatePSBTError(String)
}

extension KeystoneError: LocalizedError {
    public var errorDescription: String? {
        switch self {
            case .internalError:
                return NSLocalizedString("internalError", comment: "Keystone SDK internal Error")
            case .syncAccountsError(let reason):
                return NSLocalizedString("InvalidAccounts(\(reason))", comment: "InvalidAccounts")
            case .parseSignatureError(let reason):
                return NSLocalizedString("InvalidSignature(\(reason))", comment: "InvalidSignature")
            case .parsePSBTError(let reason):
                return NSLocalizedString("InvalidPSBT(\(reason))", comment: "InvalidPSBT")
            case .generateSignRequestError(let reason):
                return NSLocalizedString("SignRequestError(\(reason))", comment: "SignRequestError")
            case .generatePSBTError(let reason):
                return NSLocalizedString("PSBTError(\(reason))", comment: "PSBTError")
        }
    }
}
