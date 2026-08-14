//
//  ScanStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 16.05.2022.
//

import SwiftUI
import Combine
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
        /// PHASE 7 (migration Keystone batch): the batch decoder (`decodeKeystoneSignBatchPart`)
        /// reports an authoritative 0-100 completion percentage directly, unlike the BC-UR fountain
        /// checkers above, which reconstruct a monotonic count from raw QR-string part indices
        /// (`reportedParts`/`expectedParts`) because their decoder's own figure isn't trusted for
        /// display. `countedProgress` prefers this when set.
        var keystoneBatchDirectProgress: Int?
        /// PHASE 7: this ceremony's correlation token for `decodeKeystoneSignBatchPart` — set by
        /// `MigrationCoordFlowCoordinator` when it pushes this scan session for the migration-batch
        /// checker (copied off the `keystoneSign` element's own `requestId`).
        var keystoneBatchRequestId = Data()
        /// PHASE 7: armed by `MigrationCoordFlowCoordinator` while a Keystone migration ceremony's
        /// post-scan leg runs (immediate lane: proofs + broadcast; batch lanes: apply + store) — the
        /// scan screen stays on top the whole time, so this drives the visible "Signing…" hold: the
        /// progress bar pins at 100% and the Cancel pill becomes a disabled spinner pill. Pure UI
        /// state: no reducer case touches it, and it dies with the popped `scan` element.
        var isKeystoneSigningInProgress = false

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
        case libraryImage(PlatformImage?)
        case onAppear
        case onDisappear
        case foundAddress(RedactableString)
        case foundString(String)
        case foundRequestZec(ParserResult)
        case foundAccounts(ZcashAccounts)
        case foundPCZT(Data)
        #if VOTING_ENABLED
        case foundVotingDelegationPCZT(Data)
        #endif
        /// PHASE 7: one scanned QR frame for the Keystone migration-batch signing ceremony.
        /// `KeystoneMigrationBatchScanChecker` cannot await `decodeKeystoneSignBatchPart` itself
        /// (`ScanChecker.checkQRCode` is synchronous), so it hands the raw frame back here and this
        /// reducer runs the decode as an effect.
        case keystoneBatchPartScanned(String)
        /// Internal: `decodeKeystoneSignBatchPart` returned `complete == false` — more frames needed.
        case keystoneBatchDecodeProgress(Int)
        /// PHASE 7: the migration-batch decode session completed — `data` is the batch-signature
        /// response to apply (`applyKeystoneBatchSignatures`), `firmwareVersion` is the signing
        /// device's reported firmware (`nil` when the envelope carried none). Additive to this
        /// shared Scan feature; whichever coordinator requested the scan consumes it.
        case foundKeystoneBatchSignatures(data: Data, firmwareVersion: ZcashLightClientKit.KeystoneFirmwareVersion?)
        /// PHASE 7: `decodeKeystoneSignBatchPart` threw on a frame (including a request-id mismatch
        /// at completion) — treated like a rejected scan: the coordinator abandons the ceremony.
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

            #if VOTING_ENABLED
            case .foundVotingDelegationPCZT:
                state.isAnythingFound = true
                state.progress = nil
                return .none
            #endif

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
                        // Log before reporting: the coordinator abandons the ceremony on this action,
                        // and a silently-discarded decode error (request-id mismatch vs malformed
                        // envelope vs missing firmware field) is undiagnosable from QA logs.
                        LoggerProxy.error("[MOB-1466] Keystone batch scan decode failed: \(error)")
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
                // No local state to unwind — the initiating `MigrationCoordFlowCoordinator` owns the
                // ceremony and abandons it (`keystoneScanAbandoned` semantics) on observing this.
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

    // MARK: - PHASE 7: Keystone migration-batch decoder reset (entry/retry/exit)

    /// Resets the SDK's process-wide Keystone sign-batch-response decode session — called on
    /// scan-screen entry and exit, so a fresh attempt always starts clean regardless of how a
    /// previous one ended. "Retry" is covered by "entry": this screen never re-enters mid-ceremony
    /// (an abandon/reject pops the whole `scan` + `keystoneSign` pair, so re-initiating pushes a
    /// brand-new `Scan.State` and fires `.onAppear` again).
    ///
    /// Gated on the migration-batch checker being configured for THIS session: every other scan use
    /// case (address, request-zec, the single-PCZT Keystone flows, swap, voting) never touches this
    /// decoder, so resetting unconditionally would be pure noise for them.
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
