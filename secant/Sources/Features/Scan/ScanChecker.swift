//
//  ScanChecker.swift
//  modules
//
//  Created by Lukáš Korba on 2024-11-20.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import Foundation
import ZcashPaymentURI

@preconcurrency import KeystoneSDK

protocol ScanChecker: Sendable, Equatable {
    var id: Int { get }
    
    func checkQRCode(_ qrCode: String) -> Scan.Action?
}

struct ZcashAddressScanChecker: ScanChecker, Equatable {
    let id = 0
    
    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        @Dependency(\.uriParser) var uriParser
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        
        if uriParser.isValidURI(qrCode, zcashSDKEnvironment.network().networkType) {
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
        
        if let parserResult = uriParser.checkRP(qrCode, zcashSDKEnvironment.network().networkType) {
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

#if VOTING_ENABLED
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
#endif

/// PHASE 7 — migration Keystone batch signing. Unlike every other checker in this file, this one
/// does NOT run the accumulate-with-progress dance itself: the batch-signing bridge
/// (`Synchronizer.decodeKeystoneSignBatchPart(_:expectedRequestId:)`) owns its OWN multi-part decode
/// session over the raw scanned frame strings, so `keystoneHandler`'s BC-UR fountain decoder (used
/// by every other Keystone checker above) plays no part here. `checkQRCode` cannot await that call
/// (`ScanChecker.checkQRCode` is a synchronous, dependency-only, `state`-free function), so it hands
/// the raw frame straight back as `.keystoneBatchPartScanned` — `Scan.body` runs the decode as an
/// effect and reports progress/completion/failure from there.
///
/// Always matches (never `nil`): every scanned string during this ceremony is a candidate frame, and
/// the decode call itself is what validates it.
struct KeystoneMigrationBatchScanChecker: ScanChecker, Equatable {
    let id = 6

    func checkQRCode(_ qrCode: String) -> Scan.Action? {
        .keystoneBatchPartScanned(qrCode)
    }
}

struct ScanCheckerWrapper: Equatable, Sendable {
    let checker: any ScanChecker

    static let zcashAddressScanChecker = ScanCheckerWrapper(ZcashAddressScanChecker())
    static let requestZecScanChecker = ScanCheckerWrapper(RequestZecScanChecker())
    static let keystoneScanChecker = ScanCheckerWrapper(KeystoneScanChecker())
    static let keystonePCZTScanChecker = ScanCheckerWrapper(KeystonePcztScanChecker())
    static let swapStringScanChecker = ScanCheckerWrapper(SwapStringScanChecker())
    #if VOTING_ENABLED
    static let keystoneVotingDelegationPCZTScanChecker = ScanCheckerWrapper(KeystoneVotingDelegationPcztScanChecker())
    #endif
    static let keystoneMigrationBatchScanChecker = ScanCheckerWrapper(KeystoneMigrationBatchScanChecker())

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
