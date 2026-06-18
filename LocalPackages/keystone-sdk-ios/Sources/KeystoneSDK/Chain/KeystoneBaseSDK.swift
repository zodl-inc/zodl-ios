//
//  BaseSDK.swift
//  
//
//  Created by LiYan on 3/27/23.
//

import Foundation
import URRegistryFFI
import URKit

func handle_error(
    get_result: (UnsafeMutablePointer<ExternError>) -> Optional<UnsafePointer<CChar>>
) -> String {
    var err = ExternError()
    let err_ptr: UnsafeMutablePointer<ExternError> = UnsafeMutablePointer(&err)
    let res: Optional<UnsafePointer<CChar>> = get_result(err_ptr)
    if err_ptr.pointee.code == 0 {
        let responseInJSONStr = String(cString: res!)
        keystone_sdk_destroy_string(res!)
        return responseInJSONStr
    } else {
        let errorMessage = String(cString: err_ptr.pointee.message)
        keystone_sdk_destroy_string(err_ptr.pointee.message)
        return "{\"error\":\"\(errorMessage)\"}"
    }
}

extension String {
    var hexadecimal: Data {
        var data = Data(capacity: count / 2)

        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: self, range: NSRange(startIndex..., in: self)) { match, _, _ in
            let byteString = (self as NSString).substring(with: match!.range)
            let num = UInt8(byteString, radix: 16)!
            data.append(num)
        }
        guard data.count > 0 else { return Data() }
        return data
    }
}

public class KeystoneBaseSDK {
    let jsonDecoder: JSONDecoder
    let jsonEncoder: JSONEncoder

    public init() {
        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        jsonEncoder = JSONEncoder()
        jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func urStringToEncoder(urString: String, ofError: (String) -> KeystoneError) throws -> UREncoder {
        do {
            let txUR = try jsonDecoder.decode(NativeUR.self, from: Data(urString.utf8))
            let encodeUR = try URKit.UR(type: txUR.type, cbor: CBOR(txUR.cbor.hexadecimal) )
            return UREncoder(encodeUR, maxFragmentLen: KeystoneSDK.maxFragmentLen)
        } catch {
            do {
                let err = try jsonDecoder.decode(NativeError.self, from: Data(urString.utf8))
                throw ofError(err.error)
            } catch DecodingError.dataCorrupted {
                throw KeystoneError.internalError
            }
        }
    }

    func parseUR<T: Codable>(urString: String, ofType type: T.Type, ofError: (String) -> KeystoneError) throws -> T {
        do {
            return try jsonDecoder.decode(T.self, from: Data(urString.utf8))
        } catch {
            do {
                let err = try jsonDecoder.decode(NativeError.self, from: Data(urString.utf8))
                if err.error == "type not match" {
                    throw QRCodeError.unexpectedQRCode
                } else {
                    throw ofError(err.error)
                }
            } catch DecodingError.dataCorrupted {
                throw KeystoneError.internalError
            }
        }
    }

    func parseSignature(signResult: String) throws -> Signature {
        return try parseUR(urString: signResult, ofType: Signature.self, ofError: KeystoneError.parseSignatureError)
    }

    func generateSignRequest(signRequest: String) throws -> UREncoder {
        return try urStringToEncoder(urString: signRequest, ofError: KeystoneError.generateSignRequestError)
    }
}
