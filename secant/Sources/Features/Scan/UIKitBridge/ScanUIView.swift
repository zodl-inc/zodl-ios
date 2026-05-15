//
//  ScanUIView.swift
//  Zashi
//
//  Created by Lukáš Korba on 16.05.2022.
//

import Foundation
import UIKit
@preconcurrency import AVFoundation

class ScanUIView: UIView {
    var captureSession: AVCaptureSession?
    var metadataOutput: AVCaptureMetadataOutput?
    
    /// Rect of interest = area of the camera view used to try to recognize the qr codes.
    private var internalRectOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    var rectOfInterest: CGRect {
        get {
            internalRectOfInterest
        }
        set {
            internalRectOfInterest = newValue
            metadataOutput?.rectOfInterest = internalRectOfInterest
            self.layer.metadataOutputRectConverted(fromLayerRect: newValue)
        }
    }

    var onQRScanningDidFail: (() -> Void)?
    var onQRScanningSucceededWithCode: ((String) -> Void)?

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        doInitialSetup()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        doInitialSetup()
    }
    
    deinit {
        captureSession?.stopRunning()
    }

    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    override var layer: AVCaptureVideoPreviewLayer {
        return super.layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
    }
}

extension ScanUIView {
    private func doInitialSetup() {
        clipsToBounds = true
        captureSession = AVCaptureSession()

        let deviceHasUltraWideCamera = !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: .back
        ).devices.isEmpty
        
        let captureDevice = deviceHasUltraWideCamera
        ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        : AVCaptureDevice.default(for: .video)

        guard let videoCaptureDevice = captureDevice else {
            scanningDidFail()
            return
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            scanningDidFail()
            return
        }
        
        if captureSession?.canAddInput(videoInput) ?? false {
            captureSession?.addInput(videoInput)
        } else {
            scanningDidFail()
            return
        }
        
        metadataOutput = AVCaptureMetadataOutput()
        
        if let metadataOutput = metadataOutput, captureSession?.canAddOutput(metadataOutput) ?? false {
            captureSession?.addOutput(metadataOutput)
            
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            scanningDidFail()
            return
        }
        
        self.layer.session = captureSession
        self.layer.videoGravity = .resizeAspectFill
        
        self.layer.connection?.videoOrientation = .portrait
        
        captureSession?.commitConfiguration()
        captureSession?.startRunning()
    }
    
    func scanningDidFail() {
        onQRScanningDidFail?()
        captureSession = nil
    }
    
    func found(code: String) {
        onQRScanningSucceededWithCode?(code)
    }
}

extension ScanUIView: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }
            found(code: stringValue)
        }
    }
}
