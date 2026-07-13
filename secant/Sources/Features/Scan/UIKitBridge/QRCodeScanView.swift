#if canImport(UIKit)
//
//  QRCodeScanView.swift
//  Zashi
//
//  Created by Lukáš Korba on 16.05.2022.
//

import Foundation
import UIKit
import SwiftUI

struct QRCodeScanView: UIViewRepresentable {
    let rectOfInterest: CGRect
    let onQRScanningDidFail: () -> Void
    let onQRScanningSucceededWithCode: (String) -> Void

    func makeUIView(context: UIViewRepresentableContext<QRCodeScanView>) -> ScanUIView {
        let view = ScanUIView()
        view.rectOfInterest = rectOfInterest
        view.onQRScanningDidFail = onQRScanningDidFail
        view.onQRScanningSucceededWithCode = onQRScanningSucceededWithCode
        return view
    }
    
    func updateUIView(_ uiView: ScanUIView, context: UIViewRepresentableContext<QRCodeScanView>) { }
    
    typealias UIViewType = ScanUIView
}

#else
import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import Vision

/// macOS camera QR scanner — the AppKit/AVFoundation counterpart of the iOS `ScanUIView`. Hosts an
/// `AVCaptureVideoPreviewLayer` in an `NSView` and reports decoded QR strings via the same callbacks
/// the iOS path uses, so the Keystone UR-decode + flow logic above is unchanged.
struct QRCodeScanView: NSViewRepresentable {
    let rectOfInterest: CGRect
    let onQRScanningDidFail: () -> Void
    let onQRScanningSucceededWithCode: (String) -> Void

    func makeNSView(context: Context) -> ScanNSView {
        let view = ScanNSView()
        view.onQRScanningDidFail = onQRScanningDidFail
        view.onQRScanningSucceededWithCode = onQRScanningSucceededWithCode
        view.start()
        return view
    }

    func updateNSView(_ nsView: ScanNSView, context: Context) { }
}

final class ScanNSView: NSView {
    private var captureSession: AVCaptureSession?
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "zodl.scan.video")
    private let sampleDelegate = ScanSampleBufferDelegate()

    var onQRScanningDidFail: (() -> Void)?
    var onQRScanningSucceededWithCode: ((String) -> Void)? {
        didSet {
            // Bridge the background Vision callback to the main-actor SwiftUI/store callback. The
            // closure is @Sendable; it captures only `self` weakly (an NSView is @MainActor, hence
            // Sendable) and reads the callback back on the main actor.
            sampleDelegate.onQR = { [weak self] payload in
                Task { @MainActor in self?.onQRScanningSucceededWithCode?(payload) }
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
        wantsLayer = true
    }

    deinit { captureSession?.stopRunning() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    /// Request camera access (first-run prompt), then configure + start the session.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndRun()
                    } else {
                        self?.onQRScanningDidFail?()
                    }
                }
            }
        default:
            onQRScanningDidFail?()
        }
    }

    private func configureAndRun() {
        let session = AVCaptureSession()
        captureSession = session

        // Prefer the BUILT-IN camera. `AVCaptureDevice.default(for: .video)` often resolves to the
        // Continuity Camera (iPhone-as-webcam), which exposes face/body/pet detection but NOT `.qr`
        // barcode metadata — so QR scanning silently fails on it.
        let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first ?? AVCaptureDevice.default(for: .video)

        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            onQRScanningDidFail?()
            return
        }

        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onQRScanningDidFail?()
            return
        }
        session.addInput(input)

        // QR detection runs via Vision over the raw frames. AVCaptureMetadataOutput on macOS only
        // surfaces the camera's hardware detections (face/body/pet) and does NOT offer `.qr` barcode
        // metadata — so metadata scanning silently never arms. VNDetectBarcodesRequest is the
        // reliable macOS path.
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            onQRScanningDidFail?()
            return
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(sampleDelegate, queue: videoQueue)
        session.addOutput(videoOutput)

        session.commitConfiguration()

        previewLayer.session = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
}

/// Sample-buffer delegate kept OFF the main actor (a plain NSObject, not the `@MainActor` NSView):
/// the camera delivers frames on a background queue, and a `@MainActor` delegate method invoked there
/// trips a main-actor runtime assertion (EXC_BREAKPOINT). Vision runs here; the decoded payload is
/// marshaled back to the main thread before reaching the SwiftUI/store callback.
private final class ScanSampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onQR: (@Sendable (String) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let onQR = self.onQR
        let request = VNDetectBarcodesRequest { request, _ in
            guard let results = request.results as? [VNBarcodeObservation] else { return }
            for result in results where result.symbology == .qr {
                guard let payload = result.payloadStringValue else { continue }
                onQR?(payload)
            }
        }
        request.symbologies = [.qr]

        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }
}
#endif
