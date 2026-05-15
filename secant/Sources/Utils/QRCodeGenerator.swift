//
//  QRCodeGenerator.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.07.2022.
//

import Foundation
@preconcurrency import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCodeGenerator {
    enum QRCodeError: Error {
        case failedToGenerate
    }
    
    enum Vendor: Equatable {
        case keystone
        case zashi
    }

    static func generate(
        from string: String,
        maxPrivacy: Bool = true,
        vendor: Vendor = .zashi,
        color: UIColor = Asset.Colors.primary.systemColor,
        overlayedWithZcashLogo: Bool = true
    ) -> Future<CGImage?, Never> {
        Future<CGImage?, Never> { promise in
            DispatchQueue.global().async {
                let image = generateCode(
                    from: string,
                    maxPrivacy: maxPrivacy,
                    vendor: vendor,
                    color: color,
                    overlayedWithZcashLogo: overlayedWithZcashLogo
                )
                
                return promise(.success(image))
            }
        }
    }

    static func generateCode(
        from string: String,
        scale: CGFloat = 15,
        maxPrivacy: Bool = true,
        vendor: Vendor = .zashi,
        color: UIColor = Asset.Colors.primary.systemColor,
        overlayedWithZcashLogo: Bool = true
    ) -> CGImage? {
        let data = string.data(using: String.Encoding.utf8)
        
        let context = CIContext()
        let filter = CoreImage.CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        
        if color == .black {
            guard let baseImage = filter.outputImage?.transformed(by: transform) else {
                return nil
            }

            return QRCodeGenerator.overlayWithZecLogo(
                baseImage,
                context: context,
                maxPrivacy: maxPrivacy,
                vendor: vendor,
                overlayedWithZcashLogo: overlayedWithZcashLogo
            )
        } else {
            guard let baseImage = filter.outputImage?.transformed(by: transform).tinted(using: color) else {
                return nil
            }

            return QRCodeGenerator.overlayWithZecLogo(
                baseImage,
                context: context,
                maxPrivacy: maxPrivacy,
                vendor : vendor,
                export: false,
                overlayedWithZcashLogo: overlayedWithZcashLogo
            )
        }
    }
    
    static func overlayWithZecLogo(
        _ baseImage: CIImage,
        context: CIContext,
        maxPrivacy: Bool,
        vendor: Vendor,
        export: Bool = true,
        overlayedWithZcashLogo: Bool = true
    ) -> CGImage? {
        let maxPrivacyPostfix = vendor == .zashi ? maxPrivacy ? "Max" : "Low" : ""
        let vendorPrefix = vendor == .zashi ? "" : "KS_"
        let filename = export ? "QROverlay" : "QRDynamicOverlay"
        let overlayImageName = "\(vendorPrefix)\(filename)\(maxPrivacyPostfix)"
        
        guard let overlayImage = UIImage(named: overlayImageName) else {
            return nil
        }

        guard let iconCIImage = CIImage(image: overlayImage) else {
            return nil
        }
        
        let ratio = 0.25
        let size = baseImage.extent.width * ratio
        let halfSize = size * 0.5
        let iconRect = CGRect(x: baseImage.extent.width * 0.5 - halfSize, y: baseImage.extent.height * 0.5 - halfSize, width: size, height: size)
        let scaleTransform = CGAffineTransform(scaleX: iconRect.size.width / iconCIImage.extent.width, y: iconRect.size.height / iconCIImage.extent.height)
        let translationTransform = CGAffineTransform(translationX: iconRect.origin.x, y: iconRect.origin.y)
        let transformedIconCIImage = iconCIImage.transformed(by: scaleTransform.concatenating(translationTransform))
        
        if overlayedWithZcashLogo {
            let combinedImage = transformedIconCIImage.composited(over: baseImage)
            
            return context.createCGImage(combinedImage, from: combinedImage.extent)
        } else {
            return context.createCGImage(baseImage, from: baseImage.extent)
        }
    }
}

extension CIImage {
    var transparent: CIImage? {
        inverted?.blackTransparent
    }

    var inverted: CIImage? {
        guard let invertedColorFilter = CIFilter(name: "CIColorInvert") else { return nil }

        invertedColorFilter.setValue(self, forKey: "inputImage")
        return invertedColorFilter.outputImage
    }

    var blackTransparent: CIImage? {
        guard let blackTransparentFilter = CIFilter(name: "CIMaskToAlpha") else { return nil }
        blackTransparentFilter.setValue(self, forKey: "inputImage")
        return blackTransparentFilter.outputImage
    }

    func tinted(using color: UIColor) -> CIImage?
    {
        guard
            let transparentQRImage = transparent,
            let filter = CIFilter(name: "CIMultiplyCompositing"),
            let colorFilter = CIFilter(name: "CIConstantColorGenerator") else { return nil }

        let ciColor = CIColor(color: color)
        colorFilter.setValue(ciColor, forKey: kCIInputColorKey)
        let colorImage = colorFilter.outputImage

        filter.setValue(colorImage, forKey: kCIInputImageKey)
        filter.setValue(transparentQRImage, forKey: kCIInputBackgroundImageKey)

        return filter.outputImage!
    }
}
