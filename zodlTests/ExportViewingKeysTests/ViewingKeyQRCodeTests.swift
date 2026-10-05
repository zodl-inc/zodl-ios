//
//  ViewingKeyQRCodeTests.swift
//  zodlTests
//

import CoreImage
import Foundation
import Testing
import UIKit
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized)
struct ViewingKeyQRCodeTests {
    @Test(arguments: [NetworkType.mainnet, .testnet], ViewingKeyKind.allCases)
    func exportedPNGDecodesExactly(network: NetworkType, kind: ViewingKeyKind) async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash, network: network)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: network)
        let key = try #require(session.key(for: kind))

        let output = try await ViewingKeyQRCodeClient.liveValue.png(key)
        let hasPNGSignature = Array(output.data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10]
        let image = try #require(UIImage(data: output.data)?.cgImage)
        let decoded = try decodeViewingKeyQRCode(image)
        let decodedExactly = decoded == key.rawValue

        #expect(hasPNGSignature)
        #expect(decodedExactly)
    }

    @Test
    func outputIsOpaqueMonochromeAndHasAnAdequateQuietZone() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .full))
        let output = try await ViewingKeyQRCodeClient.liveValue.png(key)
        let image = try #require(UIImage(data: output.data)?.cgImage)
        let pixels = try rgbaPixels(for: image)

        var minimumX = image.width
        var minimumY = image.height
        var maximumX = 0
        var maximumY = 0
        var isOpaque = true
        var isMonochrome = true

        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let alpha = pixels[offset + 3]
                isOpaque = isOpaque && alpha == 255
                isMonochrome = isMonochrome
                    && red == green
                    && green == blue
                    && (red == 0 || red == 255)

                if red == 0 {
                    minimumX = min(minimumX, x)
                    minimumY = min(minimumY, y)
                    maximumX = max(maximumX, x)
                    maximumY = max(maximumY, y)
                }
            }
        }

        let margins = [minimumX, minimumY, image.width - maximumX - 1, image.height - maximumY - 1]
        let hasFourModuleQuietZone = margins.allSatisfy { $0 >= 32 }

        #expect(isOpaque)
        #expect(isMonochrome)
        #expect(hasFourModuleQuietZone)
    }

    @Test(arguments: [2, 3])
    func fullKeySurvivesNearestNeighborCardDownsampling(displayScale: Int) async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let key = try #require(session.key(for: .full))
        let output = try await ViewingKeyQRCodeClient.liveValue.png(key)
        let image = try #require(UIImage(data: output.data)?.cgImage)
        let cardPixels = 297 * displayScale
        let downsampled = try downsample(image, side: cardPixels)
        let decoded = try decodeViewingKeyQRCode(downsampled)
        let decodedExactly = decoded == key.rawValue

        #expect(decodedExactly)
    }

    @Test
    func oversizedPayloadThrowsTheTypedGenericError() async {
        let oversized = ViewingKeyMaterial(String(repeating: "x", count: 10_000))
        var receivedTypedError = false

        do {
            _ = try await ViewingKeyQRCodeClient.liveValue.png(oversized)
        } catch let error as ViewingKeyQRCodeError {
            receivedTypedError = error == .generationFailed
        } catch {
            receivedTypedError = false
        }

        #expect(receivedTypedError)
    }
}

private func decodeViewingKeyQRCode(_ image: CGImage) throws -> String {
    let detector = try #require(
        CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
    )
    let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
    let feature = try #require(features.count == 1 ? features.first : nil)
    return try #require(feature.messageString)
}

private func downsample(_ image: CGImage, side: Int) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.interpolationQuality = .none
    context.setFillColor(UIColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return try #require(context.makeImage())
}

private func rgbaPixels(for image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let didRender = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let baseAddress = bytes.baseAddress else { return false }
        guard let context = CGContext(
            data: baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return try #require(didRender ? pixels : nil)
}
