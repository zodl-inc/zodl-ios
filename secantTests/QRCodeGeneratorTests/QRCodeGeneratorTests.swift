//
//  QRCodeGeneratorTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import XCTest
import CoreImage
@testable import zashi_internal


class QRCodeGeneratorTests: XCTestCase {
    func testGenerateCodeValidString() {
        let image = QRCodeGenerator.generateCode(
            from: "zcash:t1testaddress123",
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeValidString` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeEmptyString() {
        let image = QRCodeGenerator.generateCode(
            from: "",
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeEmptyString` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeLongString() {
        // Unified addresses can be very long (~300+ chars)
        let longAddress = String(repeating: "a", count: 500)
        let image = QRCodeGenerator.generateCode(
            from: longAddress,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeLongString` is expected to produce a non-nil image for long unified addresses"
        )
    }

    func testGenerateCodeUnicodeString() {
        let unicodeMemo = "zcash:t1addr?memo=Gracias%20por%20tu%20compra%20🎉"
        let image = QRCodeGenerator.generateCode(
            from: unicodeMemo,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeUnicodeString` is expected to produce a non-nil image for unicode content"
        )
    }

    func testGenerateCodeProducesSquareImage() {
        let image = QRCodeGenerator.generateCode(
            from: "test-data",
            overlayedWithZcashLogo: false
        )

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testGenerateCodeProducesSquareImage` image is expected to be non-nil")
            return
        }

        XCTAssertEqual(
            image.width,
            image.height,
            "QRCodeGenerator tests: `testGenerateCodeProducesSquareImage` width is expected to equal height but got \(image.width) x \(image.height)"
        )
    }

    func testGenerateCodeRespectsScaleParameter() {
        let smallImage = QRCodeGenerator.generateCode(
            from: "test",
            scale: 5,
            overlayedWithZcashLogo: false
        )
        let largeImage = QRCodeGenerator.generateCode(
            from: "test",
            scale: 20,
            overlayedWithZcashLogo: false
        )

        guard let smallImage, let largeImage else {
            XCTFail("QRCodeGenerator tests: `testGenerateCodeRespectsScaleParameter` both images are expected to be non-nil")
            return
        }

        XCTAssertGreaterThan(
            largeImage.width,
            smallImage.width,
            "QRCodeGenerator tests: `testGenerateCodeRespectsScaleParameter` larger scale is expected to produce larger image but got \(largeImage.width) vs \(smallImage.width)"
        )
    }

    func testGenerateCodeSameInputProducesSameDimensions() {
        let input = "zcash:t1deterministic123"
        let image1 = QRCodeGenerator.generateCode(from: input, overlayedWithZcashLogo: false)
        let image2 = QRCodeGenerator.generateCode(from: input, overlayedWithZcashLogo: false)

        guard let image1, let image2 else {
            XCTFail("QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` both images are expected to be non-nil")
            return
        }

        XCTAssertEqual(
            image1.width,
            image2.width,
            "QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` widths are expected to match but got \(image1.width) vs \(image2.width)"
        )
        XCTAssertEqual(
            image1.height,
            image2.height,
            "QRCodeGenerator tests: `testGenerateCodeSameInputProducesSameDimensions` heights are expected to match but got \(image1.height) vs \(image2.height)"
        )
    }

    func testGenerateCodeDifferentInputsBothSucceed() {
        let image1 = QRCodeGenerator.generateCode(from: "zcash:t1address_one", overlayedWithZcashLogo: false)
        let image2 = QRCodeGenerator.generateCode(from: "zcash:t1address_two", overlayedWithZcashLogo: false)

        XCTAssertNotNil(image1, "QRCodeGenerator tests: `testGenerateCodeDifferentInputsBothSucceed` first image is expected to be non-nil")
        XCTAssertNotNil(image2, "QRCodeGenerator tests: `testGenerateCodeDifferentInputsBothSucceed` second image is expected to be non-nil")
    }

    func testGenerateCodeKeystoneVendor() {
        let image = QRCodeGenerator.generateCode(
            from: "keystone-data",
            vendor: .keystone,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeKeystoneVendor` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeZashiVendor() {
        let image = QRCodeGenerator.generateCode(
            from: "zashi-data",
            vendor: .zashi,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeZashiVendor` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeMaxPrivacyTrue() {
        let image = QRCodeGenerator.generateCode(
            from: "privacy-test",
            maxPrivacy: true,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeMaxPrivacyTrue` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeMaxPrivacyFalse() {
        let image = QRCodeGenerator.generateCode(
            from: "privacy-test",
            maxPrivacy: false,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeMaxPrivacyFalse` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeWithBlackColor() {
        let image = QRCodeGenerator.generateCode(
            from: "color-test",
            color: .black,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeWithBlackColor` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeWithCustomColor() {
        let image = QRCodeGenerator.generateCode(
            from: "color-test",
            color: .blue,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeWithCustomColor` is expected to produce a non-nil image"
        )
    }

    func testGenerateAsyncFutureCompletesSuccessfully() async {
        let expectation = XCTestExpectation(description: "QR code future completes")

        let future = QRCodeGenerator.generate(
            from: "async-test",
            overlayedWithZcashLogo: false
        )

        let cancellable = future.sink { image in
            XCTAssertNotNil(image, "QRCodeGenerator tests: `testGenerateAsyncFutureCompletesSuccessfully` is expected to produce a non-nil image")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        cancellable.cancel()
    }

    func testGenerateCodeWithZIP321URI() {
        let zip321URI = "zcash:t1testaddr?amount=1.5&memo=Test%20memo"
        let image = QRCodeGenerator.generateCode(
            from: zip321URI,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeWithZIP321URI` is expected to produce a non-nil image"
        )
    }

    func testGenerateCodeWithZIP321URIMultipleParams() {
        let zip321URI = "zcash:t1testaddr?amount=0.001&memo=Payment%20for%20coffee&message=Thanks"
        let image = QRCodeGenerator.generateCode(
            from: zip321URI,
            overlayedWithZcashLogo: false
        )

        XCTAssertNotNil(
            image,
            "QRCodeGenerator tests: `testGenerateCodeWithZIP321URIMultipleParams` is expected to produce a non-nil image"
        )
    }

    func testRoundTripSimpleAddress() {
        let input = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po"
        let image = QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false)

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testRoundTripSimpleAddress` image is expected to be non-nil")
            return
        }

        let decoded = decodeQRCode(image)
        XCTAssertEqual(
            decoded,
            input,
            "QRCodeGenerator tests: `testRoundTripSimpleAddress` decoded QR is expected to be \(input) but it is \(decoded ?? "nil")"
        )
    }

    func testRoundTripZIP321URI() {
        let input = "zcash:t1testaddr?amount=1.5&memo=Test%20memo"
        let image = QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false)

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testRoundTripZIP321URI` image is expected to be non-nil")
            return
        }

        let decoded = decodeQRCode(image)
        XCTAssertEqual(
            decoded,
            input,
            "QRCodeGenerator tests: `testRoundTripZIP321URI` decoded QR is expected to match input but it is \(decoded ?? "nil")"
        )
    }

    func testRoundTripZIP321URIWithMemo() {
        let input = "zcash:t1addr?amount=0.001&memo=Payment%20for%20coffee&message=Thanks"
        let image = QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false)

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testRoundTripZIP321URIWithMemo` image is expected to be non-nil")
            return
        }

        let decoded = decodeQRCode(image)
        XCTAssertEqual(
            decoded,
            input,
            "QRCodeGenerator tests: `testRoundTripZIP321URIWithMemo` decoded QR is expected to preserve all params but it is \(decoded ?? "nil")"
        )
    }

    func testRoundTripUnicodeContent() {
        let input = "zcash:t1addr?memo=Gracias%20🎉"
        let image = QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false)

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testRoundTripUnicodeContent` image is expected to be non-nil")
            return
        }

        let decoded = decodeQRCode(image)
        XCTAssertEqual(
            decoded,
            input,
            "QRCodeGenerator tests: `testRoundTripUnicodeContent` decoded QR is expected to preserve unicode but it is \(decoded ?? "nil")"
        )
    }

    func testRoundTripLongUnifiedAddress() {
        let input = "u1" + String(repeating: "abcdef1234", count: 30)
        let image = QRCodeGenerator.generateCode(from: input, scale: 20, color: .black, overlayedWithZcashLogo: false)

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testRoundTripLongUnifiedAddress` image is expected to be non-nil")
            return
        }

        let decoded = decodeQRCode(image)
        XCTAssertEqual(
            decoded,
            input,
            "QRCodeGenerator tests: `testRoundTripLongUnifiedAddress` decoded QR is expected to match long address but it is \(decoded ?? "nil")"
        )
    }

    func testRoundTripEmptyString() {
        let input = ""
        let image = QRCodeGenerator.generateCode(from: input, color: .black, overlayedWithZcashLogo: false)

        guard let image else {
            XCTFail("QRCodeGenerator tests: `testRoundTripEmptyString` image is expected to be non-nil")
            return
        }

        let decoded = decodeQRCode(image)
        XCTAssertEqual(
            decoded,
            input,
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
