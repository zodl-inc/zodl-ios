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

    var onQRScanningDidFail: (() -> Void)?
    var onQRScanningSucceededWithCode: ((String) -> Void)?

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

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onQRScanningDidFail?()
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            onQRScanningDidFail?()
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        previewLayer.session = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
}

extension ScanNSView: @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        onQRScanningSucceededWithCode?(value)
    }
}
#endif
