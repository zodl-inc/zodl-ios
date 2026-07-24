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

@preconcurrency import ZcashLightClientKit
import ZcashPaymentURI
@preconcurrency import KeystoneSDK

@Reducer
struct Scan {
    enum ScanImageResult: Equatable {
        case invalidQRCode
        case noQRCodeFound
        case severalQRCodesFound
        case keystoneCheckOnly
    }
    
    @ObservableState
    struct State: Equatable {
        var cancelId = UUID()
        
        var checkers: [ScanCheckerWrapper] = []
        var forceLibraryToHide = false
        var info = ""
        var instructions: String?
        var isAnythingFound = false
        var isCameraEnabled = true
        var isTorchAvailable = false
        var isTorchOn = false
        var isRPFound = false
        var progress: Int?
        var expectedParts = 0
        var reportedParts = 0
        var reportedPart = -1
        /// MOB-1513: the Keystone migration-batch decoder (`decodeKeystoneSignBatchPart`) reports an
        /// authoritative 0-100 completion percentage directly, unlike the BC-UR fountain checkers
        /// above (which reconstruct a monotonic count from raw QR-string part indices via
        /// `reportedParts`/`expectedParts`, since their underlying decoder's own progress figure
        /// isn't trusted for display). `countedProgress` prefers this when set.
        var keystoneBatchDirectProgress: Int?
        /// MOB-1513: this ceremony's correlation token for `decodeKeystoneSignBatchPart` — set by
        /// `MigrationCoordFlowCoordinator` when it pushes this scan session for the Keystone
        /// migration-batch checker (copied from the `keystoneSign` element's own `requestId`).
        var keystoneBatchRequestId = Data()

        var countedProgress: Int {
            if let keystoneBatchDirectProgress {
                return min(99, max(0, keystoneBatchDirectProgress))
            }
            guard expectedParts > 0 else { return 0 }

            return min(99, Int(Float(reportedParts) / Float(expectedParts) * 100))
        }

        init(
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
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.uriParser) var uriParser
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    enum Action: Equatable {
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
        case foundVotingDelegationPCZT(Data)
        /// MOB-1513: one scanned QR frame for the Keystone migration-batch signing ceremony —
        /// `KeystoneMigrationBatchScanChecker` can't await `decodeKeystoneSignBatchPart` itself
        /// (`ScanChecker.checkQRCode` is synchronous), so it hands the raw frame back here and this
        /// reducer runs the decode as an effect.
        case keystoneBatchPartScanned(String)
        /// Internal: `decodeKeystoneSignBatchPart` returned `complete == false` — more frames needed.
        case keystoneBatchDecodeProgress(Int)
        /// MOB-1513: the Keystone migration-batch decode session completed — `data` is the
        /// batch-signature response to apply (`Synchronizer.applyKeystoneBatchSignatures`),
        /// `firmwareVersion` is the signing device's reported firmware (`nil` if the envelope didn't
        /// carry one). Additive to this shared Scan feature; the coordinator that requested the scan
        /// is responsible for consuming it. Replaces the old (never-real) `foundPCZTBatch([Pczt])`
        /// shape from before the real SDK bridge landed — the device's response is signatures-only,
        /// no PCZT is echoed back.
        case foundKeystoneBatchSignatures(data: Data, firmwareVersion: ZcashLightClientKit.KeystoneFirmwareVersion?)
        /// `decodeKeystoneSignBatchPart` threw on a frame (including a request-id mismatch at
        /// completion) — treated like a rejected scan: the coordinator abandons the ceremony.
        case keystoneBatchDecodeFailed
        case animatedQRProgress(Int, Int?, Int?)
        case scanFailed(ScanImageResult)
        case scan(RedactableString)
        case torchTapped
    }
    
    init() { }

    // swiftlint:disable:next cyclomatic_complexity
    var body: some ReducerOf<Self> {
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
                state.keystoneBatchDirectProgress = nil
                state.isTorchOn = false
                state.isRPFound = false
                state.info = ""
                // check the torch availability
                state.isTorchAvailable = captureDevice.isTorchAvailable()
                return .merge(
                    .send(.checkCameraPermission),
                    Self.resetKeystoneBatchDecoderIfNeeded(state: state, sdkSynchronizer: sdkSynchronizer)
                )

            case .onDisappear:
                // __LD2 TESTing
                return .merge(
                    .cancel(id: state.cancelId),
                    Self.resetKeystoneBatchDecoderIfNeeded(state: state, sdkSynchronizer: sdkSynchronizer)
                )

            case .checkCameraPermission:
                if !captureDevice.isAuthorized() {
                    state.isCameraEnabled = false
                    state.info = String(localizable: .scanCameraSettings)
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

            case .foundVotingDelegationPCZT:
                state.isAnythingFound = true
                state.progress = nil
                return .none

            case .keystoneBatchPartScanned(let part):
                return .run { [sdkSynchronizer, requestId = state.keystoneBatchRequestId] send in
                    do {
                        let result = try await sdkSynchronizer.decodeKeystoneSignBatchPart(part, requestId)
                        if result.complete {
                            await send(.foundKeystoneBatchSignatures(data: result.data ?? Data(), firmwareVersion: result.firmwareVersion))
                        } else {
                            await send(.keystoneBatchDecodeProgress(result.progress))
                        }
                    } catch {
                        await send(.keystoneBatchDecodeFailed)
                    }
                }

            case .keystoneBatchDecodeProgress(let progress):
                state.keystoneBatchDirectProgress = progress
                state.progress = progress
                return .none

            case .foundKeystoneBatchSignatures:
                state.isAnythingFound = true
                state.progress = nil
                state.keystoneBatchDirectProgress = nil
                return .none

            case .keystoneBatchDecodeFailed:
                // No local state to unwind here — the initiating `MigrationCoordFlowCoordinator`
                // owns the ceremony and abandons it (`keystoneScanAbandoned` semantics) on observing
                // this action.
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
                    state.info = String(localizable: .scanInvalidQR)
                case .noQRCodeFound:
                    state.info = String(localizable: .scanInvalidImage)
                case .severalQRCodesFound:
                    state.info = String(localizable: .scanSeveralCodesFound)
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

    // MARK: - MOB-1513: Keystone migration-batch decoder reset (entry/retry/exit)

    /// Resets the SDK's process-wide Keystone sign-batch-response decode session — call on
    /// scan-screen entry, retry, and exit (see `resetKeystoneSignBatchDecoder`'s own doc), so a
    /// fresh attempt always starts from a clean slate regardless of how a previous attempt ended.
    /// "Retry" is covered by "entry": this screen never re-enters mid-ceremony (an abandon/reject
    /// pops the whole `scan` + `keystoneSign` pair, so re-initiating pushes a brand-new `Scan.State`
    /// and fires `.onAppear` again). Gated on the migration-batch checker actually being configured
    /// for THIS session — every other scan use case (address, request-zec, the single-PCZT Keystone
    /// flows, swap, voting) never touches this decoder, so resetting unconditionally on every
    /// scan-screen open/close would be pure noise for them.
    private static func resetKeystoneBatchDecoderIfNeeded(
        state: State,
        sdkSynchronizer: SDKSynchronizerClient
    ) -> Effect<Action> {
        guard state.checkers.contains(.keystoneMigrationBatchScanChecker) else { return .none }
        return .run { _ in
            await sdkSynchronizer.resetKeystoneSignBatchDecoder()
        }
    }
}
