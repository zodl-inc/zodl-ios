//
//  ScanStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 16.05.2022.
//

import SwiftUI
import CoreImage
import ComposableArchitecture
import Foundation

import CaptureDevice
import QRImageDetector
import Utils
import URIParser
import ZcashLightClientKit
import Generated
import ZcashSDKEnvironment
import Models
import ZcashPaymentURI
import KeystoneHandler
import KeystoneSDK

@Reducer
public struct Scan {
    public enum ScanImageResult: Equatable {
        case invalidQRCode
        case noQRCodeFound
        case severalQRCodesFound
        case keystoneCheckOnly
    }
    
    @ObservableState
    public struct State: Equatable {
        public var cancelId = UUID()
        
        public var checkers: [ScanCheckerWrapper] = []
        public var forceLibraryToHide = false
        public var info = ""
        public var instructions: String?
        public var isAnythingFound = false
        public var isCameraEnabled = true
        public var isTorchAvailable = false
        public var isTorchOn = false
        public var isRPFound = false
        public var progress: Int?
        public var expectedParts = 0
        public var reportedParts = 0
        public var reportedPart = -1

        var countedProgress: Int {
            guard expectedParts > 0 else { return 0 }
            
            return min(99, Int(Float(reportedParts) / Float(expectedParts) * 100))
        }
        
        public init(
            info: String = "",
            isTorchAvailable: Bool = false,
            isTorchOn: Bool = false,
            isCameraEnabled: Bool = true
        ) {
            self.info = info
            self.isTorchAvailable = isTorchAvailable
            self.isTorchOn = isTorchOn
        }
    }

    @Dependency(\.captureDevice) var captureDevice
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.qrImageDetector) var qrImageDetector
    @Dependency(\.uriParser) var uriParser
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public enum Action: Equatable {
        case cancelTapped
        case checkCameraPermission
        case clearInfo
        case libraryImage(UIImage?)
        case onAppear
        case onDisappear
        case foundAddress(RedactableString)
        case foundString(String)
        case foundRequestZec(ParserResult)
        case foundAccounts(ZcashAccounts)
        case foundPCZT(Data)
        case animatedQRProgress(Int, Int?, Int?)
        case scanFailed(ScanImageResult)
        case scan(RedactableString)
        case torchTapped
    }
    
    public init() { }

    // swiftlint:disable:next cyclomatic_complexity
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                // reset the values
                state.isAnythingFound = false
                state.reportedPart = -1
                state.reportedParts = 0
                state.expectedParts = 0
                state.progress = nil
                state.isTorchOn = false
                state.isRPFound = false
                state.info = ""
                // check the torch availability
                state.isTorchAvailable = captureDevice.isTorchAvailable()
                return .send(.checkCameraPermission)

            case .onDisappear:
                // __LD2 TESTing
                return .cancel(id: state.cancelId)
                
            case .checkCameraPermission:
                if !captureDevice.isAuthorized() {
                    state.isCameraEnabled = false
                    state.info = L10n.Scan.cameraSettings
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(1))
                        await send(.checkCameraPermission)
                    }
                } else {
                    state.isCameraEnabled = true
                    state.info = ""
                }
                return .none

            case .foundAddress:
                state.isAnythingFound = true
                return .none

            case .foundRequestZec:
                state.isAnythingFound = true
                return .none
                
            case .foundAccounts:
                state.isAnythingFound = true
                state.progress = nil
                return .none

            case .foundPCZT:
                state.isAnythingFound = true
                state.progress = nil
                return .none
                
            case .foundString:
                state.isAnythingFound = true
                return .none

            case .cancelTapped:
                return .none
                
            case .clearInfo:
                state.info = ""
                return .cancel(id: state.cancelId)

            case let .animatedQRProgress(progress, part, expectedParts):
                let partInt = part ?? -1
                if partInt != -1 && partInt != state.reportedPart {
                    state.reportedPart = partInt
                    state.reportedParts = state.reportedParts + 1
                }
                state.expectedParts = Int(Float(expectedParts ?? 0) * 1.75)
                state.progress = progress
                return .none

            case .libraryImage(let image):
                guard !state.isRPFound else {
                    return .none
                }

                guard let codes = qrImageDetector.check(image) else {
                    return .send(.scanFailed(.noQRCodeFound))
                }
                
                guard codes.count == 1 else {
                    return .send(.scanFailed(.severalQRCodesFound))
                }
                
                guard let code = codes.first else {
                    return .send(.scanFailed(.noQRCodeFound))
                }

                return .send(.scan(code.redacted))

            case .scanFailed(let result):
                switch result {
                case .invalidQRCode:
                    state.info = L10n.Scan.invalidQR
                case .noQRCodeFound:
                    state.info = L10n.Scan.invalidImage
                case .severalQRCodesFound:
                    state.info = L10n.Scan.severalCodesFound
                case .keystoneCheckOnly:
                    state.info = ""
                }
                return .concatenate(
                    .cancel(id: state.cancelId),
                    .run { send in
                        try await mainQueue.sleep(for: .seconds(1))
                        await send(.clearInfo)
                    }
                    .cancellable(id: state.cancelId, cancelInFlight: true)
                )

            case .scan(let code):
                guard !state.isAnythingFound else {
                    return .none
                }
                for checker in state.checkers {
                    if let action = checker.checker.checkQRCode(code.data) {
                        return .send(action)
                    }
                }

                if state.checkers.count == 2 && state.checkers[0] == .keystoneScanChecker && state.checkers[1] == .keystonePCZTScanChecker {
                    return .none
                }
                return .send(.scanFailed(.noQRCodeFound))

            case .torchTapped:
                do {
                    try captureDevice.torch(!state.isTorchOn)
                    state.isTorchOn.toggle()
                } catch { }
                return .none
            }
        }
    }
}
