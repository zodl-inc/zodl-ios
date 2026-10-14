//
//  QRCodeGeneratorTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import Testing
import UIKit
import CoreImage
@testable import zodl_internal

@Suite struct QRCodeGeneratorTests {
    @Test func generateCodeValidString() {
        let image = QRCodeGenerator.generateCode(
            from: "zcash:t1testaddress123",
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeValidString` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeEmptyString() {
        let image = QRCodeGenerator.generateCode(
            from: "",
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeEmptyString` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeLongString() {
        // Unified addresses can be very long (~300+ chars)
        let longAddress = String(repeating: "a", count: 500)
        let image = QRCodeGenerator.generateCode(
            from: longAddress,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeLongString` is expected to produce a non-nil image for long unified addresses"
        )
    }

    @Test func generateCodeUnicodeString() {
        let unicodeMemo = "zcash:t1addr?memo=Gracias%20por%20tu%20compra%20🎉"
        let image = QRCodeGenerator.generateCode(
            from: unicodeMemo,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeUnicodeString` is expected to produce a non-nil image for unicode content"
        )
    }

    @Test func generateCodeProducesSquareImage() throws {
        let image = try #require(
            QRCodeGenerator.generateCode(from: "test-data", overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testGenerateCodeProducesSquareImage` image is expected to be non-nil"
        )

        #expect(
            image.width == image.height,
            "QRCodeGenerator tests: `testGenerateCodeProducesSquareImage` width is expected to equal height but got \(image.width) x \(image.height)"
        )
    }

    @Test func generateCodeRespectsScaleParameter() throws {
        let smallImage = try #require(
            QRCodeGenerator.generateCode(from: "test", scale: 5, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testGenerateCodeRespectsScaleParameter` small image is expected to be non-nil"
        )
        let largeImage = try #require(
            QRCodeGenerator.generateCode(from: "test", scale: 20, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testGenerateCodeRespectsScaleParameter` large image is expected to be non-nil"
        )

        #expect(
            largeImage.width > smallImage.width,
            "QRCodeGenerator tests: `testGenerateCodeRespectsScaleParameter` larger scale is expected to produce larger image but got \(largeImage.width) vs \(smallImage.width)"
        )
    }

    @Test func generateCodeSameInputProducesSameDimensions() throws {
        let input = "zcash:t1deterministic123"
        let image1 = try #require(
            QRCodeGenerator.generateCode(from: input, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` first image is expected to be non-nil"
        )
        let image2 = try #require(
            QRCodeGenerator.generateCode(from: input, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` second image is expected to be non-nil"
        )

        #expect(
            image1.width == image2.width,
            "QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` widths are expected to match but got \(image1.width) vs \(image2.width)"
        )
        #expect(
            image1.height == image2.height,
            "QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` heights are expected to match but got \(image1.height) vs \(image2.height)"
        )
    }

    @Test func generateCodeDifferentInputsBothSucceed() {
        let image1 = QRCodeGenerator.generateCode(from: "zcash:t1address_one", overlayedWithZcashLogo: false)
        let image2 = QRCodeGenerator.generateCode(from: "zcash:t1address_two", overlayedWithZcashLogo: false)

        #expect(image1 != nil, "QRCodeGenerator tests: `testGenerateCodeDifferentInputsBothSucceed` first image is expected to be non-nil")
        #expect(image2 != nil, "QRCodeGenerator tests: `testGenerateCodeDifferentInputsBothSucceed` second image is expected to be non-nil")
    }

    @Test func generateCodeKeystoneVendor() {
        let image = QRCodeGenerator.generateCode(
            from: "keystone-data",
            vendor: .keystone,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeKeystoneVendor` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeZashiVendor() {
        let image = QRCodeGenerator.generateCode(
            from: "zashi-data",
            vendor: .zashi,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeZashiVendor` is expected to produce a non-nil image"
        )
    }

    /// MOB-2020: no Ledger-specific overlay asset exists yet, so `.ledger` reuses the plain,
    /// unprefixed overlay — the same asset the `.zashi` vendor test above resolves, so this must
    /// succeed exactly like it does.
    @Test func generateCodeLedgerVendor() {
        let image = QRCodeGenerator.generateCode(
            from: "ledger-data",
            vendor: .ledger,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeLedgerVendor` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeMaxPrivacyTrue() {
        let image = QRCodeGenerator.generateCode(
            from: "privacy-test",
            maxPrivacy: true,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeMaxPrivacyTrue` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeMaxPrivacyFalse() {
        let image = QRCodeGenerator.generateCode(
            from: "privacy-test",
            maxPrivacy: false,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeMaxPrivacyFalse` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeWithBlackColor() {
        let image = QRCodeGenerator.generateCode(
            from: "color-test",
            color: .black,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeWithBlackColor` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeWithCustomColor() {
        let image = QRCodeGenerator.generateCode(
            from: "color-test",
            color: .blue,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeWithCustomColor` is expected to produce a non-nil image"
        )
    }

    @Test func generateAsyncFutureCompletesSuccessfully() async {
        let image = await QRCodeGenerator.generate(
            from: "async-test",
            overlayedWithZcashLogo: false
        )

        #expect(image != nil, "QRCodeGenerator tests: `testGenerateAsyncFutureCompletesSuccessfully` is expected to produce a non-nil image")
    }

    @Test func generateCodeWithZIP321URI() {
        let zip321URI = "zcash:t1testaddr?amount=1.5&memo=Test%20memo"
        let image = QRCodeGenerator.generateCode(
            from: zip321URI,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeWithZIP321URI` is expected to produce a non-nil image"
        )
    }

    @Test func generateCodeWithZIP321URIMultipleParams() {
        let zip321URI = "zcash:t1testaddr?amount=0.001&memo=Payment%20for%20coffee&message=Thanks"
        let image = QRCodeGenerator.generateCode(
            from: zip321URI,
            overlayedWithZcashLogo: false
        )

        #expect(
            image != nil,
            "QRCodeGenerator tests: `testGenerateCodeWithZIP321URIMultipleParams` is expected to produce a non-nil image"
        )
    }

    @Test func roundTripSimpleAddress() throws {
        let input = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po"
        let image = try #require(
            QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testRoundTripSimpleAddress` image is expected to be non-nil"
        )

        let decoded = decodeQRCode(image)
        #expect(
            decoded == input,
            "QRCodeGenerator tests: `testRoundTripSimpleAddress` decoded QR is expected to be \(input) but it is \(decoded ?? "nil")"
        )
    }

    @Test func roundTripZIP321URI() throws {
        let input = "zcash:t1testaddr?amount=1.5&memo=Test%20memo"
        let image = try #require(
            QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testRoundTripZIP321URI` image is expected to be non-nil"
        )

        let decoded = decodeQRCode(image)
        #expect(
            decoded == input,
            "QRCodeGenerator tests: `testRoundTripZIP321URI` decoded QR is expected to match input but it is \(decoded ?? "nil")"
        )
    }

    @Test func roundTripZIP321URIWithMemo() throws {
        let input = "zcash:t1addr?amount=0.001&memo=Payment%20for%20coffee&message=Thanks"
        let image = try #require(
            QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testRoundTripZIP321URIWithMemo` image is expected to be non-nil"
        )

        let decoded = decodeQRCode(image)
        #expect(
            decoded == input,
            "QRCodeGenerator tests: `testRoundTripZIP321URIWithMemo` decoded QR is expected to preserve all params but it is \(decoded ?? "nil")"
        )
    }

    @Test func roundTripUnicodeContent() throws {
        let input = "zcash:t1addr?memo=Gracias%20🎉"
        let image = try #require(
            QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testRoundTripUnicodeContent` image is expected to be non-nil"
        )

        let decoded = decodeQRCode(image)
        #expect(
            decoded == input,
            "QRCodeGenerator tests: `testRoundTripUnicodeContent` decoded QR is expected to preserve unicode but it is \(decoded ?? "nil")"
        )
    }

    @Test func roundTripLongUnifiedAddress() throws {
        let input = "u1" + String(repeating: "abcdef1234", count: 30)
        let image = try #require(
            QRCodeGenerator.generateCode(from: input, scale: 20, color: .black, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testRoundTripLongUnifiedAddress` image is expected to be non-nil"
        )

        let decoded = decodeQRCode(image)
        #expect(
            decoded == input,
            "QRCodeGenerator tests: `testRoundTripLongUnifiedAddress` decoded QR is expected to match long address but it is \(decoded ?? "nil")"
        )
    }

    @Test func roundTripEmptyString() throws {
        let input = ""
        let image = try #require(
            QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false),
            "QRCodeGenerator tests: `testRoundTripEmptyString` image is expected to be non-nil"
        )

        let decoded = decodeQRCode(image)
        #expect(
            decoded == input,
            "QRCodeGenerator tests: `testRoundTripEmptyString` decoded QR is expected to be empty but it is \(decoded ?? "nil")"
        )
    }
}

private extension QRCodeGeneratorTests {
    func decodeQRCode(_ cgImage: CGImage) -> String? {
        let ciImage = CIImage(cgImage: cgImage)
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        return (features.first as? CIQRCodeFeature)?.messageString
    }
}
