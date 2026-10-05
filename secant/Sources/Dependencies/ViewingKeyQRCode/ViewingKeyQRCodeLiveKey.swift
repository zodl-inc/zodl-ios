import ComposableArchitecture
import CoreGraphics
import UIKit

extension ViewingKeyQRCodeClient: DependencyKey {
    static let liveValue = ViewingKeyQRCodeClient(
        png: { key in
            try await Task.detached(priority: .userInitiated) {
                try makePNG(for: key)
            }.value
        }
    )

    private static func makePNG(for key: ViewingKeyMaterial) throws -> ViewingKeyPNG {
        let scale = 12
        let quietZone = 4 * scale

        guard
            let code = QRCodeGenerator.generateCode(
                from: key.rawValue,
                scale: CGFloat(scale),
                color: .black,
                overlayedWithZcashLogo: false
            )
        else {
            throw ViewingKeyQRCodeError.generationFailed
        }

        let width = code.width + 2 * quietZone
        let height = code.height + 2 * quietZone
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ViewingKeyQRCodeError.generationFailed
        }

        context.setFillColor(Asset.Colors.ZDesign.Base.bone.systemColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(
            code,
            in: CGRect(
                x: quietZone,
                y: quietZone,
                width: code.width,
                height: code.height
            )
        )

        guard
            let image = context.makeImage(),
            let data = UIImage(cgImage: image).pngData()
        else {
            throw ViewingKeyQRCodeError.generationFailed
        }

        return ViewingKeyPNG(data: data)
    }
}
