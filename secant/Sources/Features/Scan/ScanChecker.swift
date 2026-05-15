//
//  ScanChecker.swift
//  modules
//
//  Created by Lukáš Korba on 2024-11-20.
//

import ComposableArchitecture
import ZcashPaymentURI

@preconcurrency import KeystoneSDK

protocol ScanChecker: Equatable {
    var id: Int { get }
    
    func checkQRCode(_ qrCode: String) -> Scan.Action?
}

struct ZcashAddressScanChecker: ScanChecker, Equatable {
    let id = 0
    
    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        @Dependency(\.uriParser) var uriParser
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        
        if uriParser.isValidURI(qrCode, zcashSDKEnvironment.network.networkType) {
            return .foundAddress(qrCode.redacted)
        } else {
            return nil
        }
    }
}

struct RequestZecScanChecker: ScanChecker, Equatable {
    let id = 1
    
    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        @Dependency(\.uriParser) var uriParser
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        
        if let parserResult = uriParser.checkRP(qrCode, zcashSDKEnvironment.network.networkType) {
            return .foundRequestZec(parserResult)
        } else {
            return nil
        }
    }
}

struct KeystoneScanChecker: ScanChecker, Equatable {
    let id = 2
    
    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        @Dependency(\.keystoneHandler) var keystoneHandler
        
        if let result = keystoneHandler.decodeQR(qrCode) {
            if result.progress < 100 {
                return ScanCheckerWrapper.reportCheck(qrCode, progress: result.progress)
            }

            if let resultUR = result.ur, result.progress == 100 {
                if let zcashAccounts = try? KeystoneSDK().parseZcashAccounts(ur: resultUR) {
                    return .foundAccounts(zcashAccounts)
                } else {
                    return nil
                }
            }
        }
        
        return nil
    }
}

struct KeystonePcztScanChecker: ScanChecker, Equatable {
    let id = 3
    
    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        @Dependency(\.keystoneHandler) var keystoneHandler
        
        if let result = keystoneHandler.decodeQR(qrCode) {
            if result.progress < 100 {
                return ScanCheckerWrapper.reportCheck(qrCode, progress: result.progress)
            }
            
            if let resultUR = result.ur, result.progress == 100 {
                if let zcashPCZT = try? KeystoneZcashSDK().parseZcashPczt(ur: resultUR) {
                    return .foundPCZT(zcashPCZT)
                } else {
                    return nil
                }
            }
        }
        
        return nil
    }
}

struct SwapStringScanChecker: ScanChecker, Equatable {
    let id = 4
    
    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        .foundString(qrCode)
    }
}

struct KeystoneVotingDelegationPcztScanChecker: ScanChecker, Equatable {
    let id = 5

    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        @Dependency(\.keystoneHandler) var keystoneHandler

        if let result = keystoneHandler.decodeQR(qrCode) {
            if result.progress < 100 {
                return ScanCheckerWrapper.reportCheck(qrCode, progress: result.progress)
            }

            if let resultUR = result.ur, result.progress == 100 {
                if let zcashPCZT = try? KeystoneZcashSDK().parseZcashPczt(ur: resultUR) {
                    return .foundVotingDelegationPCZT(zcashPCZT)
                }
            }
        }

        return nil
    }
}

struct ScanCheckerWrapper: Equatable {
    let checker: any ScanChecker

    static let zcashAddressScanChecker = ScanCheckerWrapper(ZcashAddressScanChecker())
    static let requestZecScanChecker = ScanCheckerWrapper(RequestZecScanChecker())
    static let keystoneScanChecker = ScanCheckerWrapper(KeystoneScanChecker())
    static let keystonePCZTScanChecker = ScanCheckerWrapper(KeystonePcztScanChecker())
    static let swapStringScanChecker = ScanCheckerWrapper(SwapStringScanChecker())
    static let keystoneVotingDelegationPCZTScanChecker = ScanCheckerWrapper(KeystoneVotingDelegationPcztScanChecker())

    static func == (lhs: ScanCheckerWrapper, rhs: ScanCheckerWrapper) -> Bool {
        return lhs.checker.id == rhs.checker.id
    }
    
    init(_ checker: any ScanChecker) {
        self.checker = checker
    }
    
    static func reportCheck(_ qrCode: String, progress: Int) -> Scan.Action {
        var firstNumber: Int?
        var secondNumber: Int?
        let pattern = #"/\d+-(\d+)/"#
        if let match = qrCode.range(of: pattern, options: .regularExpression) {
            let substring = qrCode[match]
            if let secNumber = substring.split(separator: "-").last?.split(separator: "/").first {
                secondNumber = Int(secNumber)
            }
            if let firNumber = substring.split(separator: "-").first?.split(separator: "/").last {
                firstNumber = Int(firNumber)
            }
        }
        
        return .animatedQRProgress(progress, firstNumber, secondNumber)
    }
}
