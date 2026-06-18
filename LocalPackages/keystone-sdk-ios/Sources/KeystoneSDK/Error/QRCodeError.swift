//
//  QRCodeError.swift
//  
//
//  Created by LiYan on 3/30/23.
//

import Foundation

public enum QRCodeError: Swift.Error, Equatable {
    case unexpectedQRCode
    case invalidQRCode
}
