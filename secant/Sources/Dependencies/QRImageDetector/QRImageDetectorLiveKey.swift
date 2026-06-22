//
//  QRImageDetectorLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-04-18.
//

import ComposableArchitecture
import CoreImage
#if !canImport(UIKit)
import AppKit
import Vision
#endif

extension QRImageDetectorClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            check: { image in
#if canImport(UIKit)
                guard let image else { return nil }
                guard let ciImage = CIImage(image: image) else { return nil }

                let detectorOptions = [CIDetectorAccuracy: CIDetectorAccuracyHigh]
                let qrDetector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: detectorOptions)
                let decoderOptions = [CIDetectorImageOrientation: ciImage.properties[(kCGImagePropertyOrientation as String)] ?? 1]
                let features = qrDetector?.features(in: ciImage, options: decoderOptions)

                return features?.compactMap {
                    ($0 as? CIQRCodeFeature)?.messageString
                }
#else
                guard let image,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return nil
                }
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                let codes = ((request.results as? [VNBarcodeObservation]) ?? [])
                    .filter { $0.symbology == .qr }
                    .compactMap { $0.payloadStringValue }
                return codes.isEmpty ? nil : codes
#endif
            }
        )
    }
}
