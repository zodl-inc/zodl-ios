import XCTest

@testable import BridgeCore

final class NativeMessagingTests: XCTestCase {
    private func reader(_ data: Data) -> (Int) -> Data {
        var cursor = 0
        return { count in
            let end = min(cursor + count, data.count)
            defer { cursor = end }
            return data.subdata(in: cursor..<end)
        }
    }

    func testRoundTrip() throws {
        let payload = Data(#"{"hello":"zodl"}"#.utf8)
        let framed = NativeMessaging.frame(payload)
        let decoded = try NativeMessaging.readMessage(read: reader(framed))
        XCTAssertEqual(decoded, payload)
    }

    func testEmptyInputIsEOF() {
        XCTAssertThrowsError(try NativeMessaging.readMessage(read: reader(Data()))) {
            XCTAssertEqual($0 as? NativeMessaging.ReadError, .eof)
        }
    }

    func testOversizeRejectedBeforeBodyRead() {
        var header = UInt32(NativeMessaging.maxMessageBytes + 1).littleEndian
        let framed = Data(bytes: &header, count: 4)
        XCTAssertThrowsError(try NativeMessaging.readMessage(read: reader(framed))) {
            XCTAssertEqual($0 as? NativeMessaging.ReadError, .oversize(NativeMessaging.maxMessageBytes + 1))
        }
    }

    func testTruncatedBodyRejected() {
        let payload = Data(#"{"hello":"zodl"}"#.utf8)
        let framed = NativeMessaging.frame(payload).dropLast(3)
        XCTAssertThrowsError(try NativeMessaging.readMessage(read: reader(Data(framed)))) {
            XCTAssertEqual($0 as? NativeMessaging.ReadError, .truncated(expected: payload.count, got: payload.count - 3))
        }
    }
}

final class BridgeMessageTests: XCTestCase {
    private func message(
        v: Int = 1,
        id: String = "A3F0C2D1-0000-4000-8000-000000000001",
        type: String = "payRequest",
        uri: String = "zcash:u1qxyz?amount=1.5",
        origin: String = "https://shop.example",
        requestSrc: String? = nil
    ) -> BridgeMessage {
        BridgeMessage(v: v, id: id, type: type, uri: uri, origin: origin, requestSrc: requestSrc)
    }

    func testDecisionTable() {
        XCTAssertNil(message().validate())
        XCTAssertNil(message(origin: BridgeMessage.popupOrigin).validate())
        XCTAssertNil(message(origin: "http://localhost:8873").validate())
        XCTAssertNil(message(requestSrc: "https://shop.example/invoice/123").validate())
        XCTAssertNil(message(requestSrc: "http://localhost:8873/invoice.txt").validate())

        XCTAssertEqual(message(v: 2).validate(), .badVersion)
        XCTAssertEqual(message(type: "balance").validate(), .badType)
        XCTAssertEqual(message(id: "").validate(), .badID)
        XCTAssertEqual(message(uri: "bitcoin:xyz").validate(), .badURI)
        XCTAssertEqual(message(uri: "zcash:" + String(repeating: "a", count: 3000)).validate(), .uriTooLong)
        XCTAssertEqual(message(origin: "http://shop.example").validate(), .badOrigin)
        XCTAssertEqual(message(origin: "chrome-extension://abc/").validate(), .badOrigin)
        XCTAssertEqual(message(requestSrc: "http://shop.example/invoice").validate(), .badRequestSrc)
        XCTAssertEqual(message(requestSrc: "https://x/" + String(repeating: "a", count: 1100)).validate(), .badRequestSrc)
    }
}

final class AllowlistTests: XCTestCase {
    private let ourID = "abcdefghijklmnopabcdefghijklmnop"

    func testDecisionTable() {
        let allowlist = Allowlist(allowedExtensionIDs: [ourID])
        XCTAssertTrue(allowlist.permits(callerOrigin: "chrome-extension://\(ourID)/"))
        XCTAssertTrue(allowlist.permits(callerOrigin: "chrome-extension://\(ourID)"))

        XCTAssertFalse(allowlist.permits(callerOrigin: "chrome-extension://ppppppppppppppppppppppppppppppp p/"))
        XCTAssertFalse(allowlist.permits(callerOrigin: "chrome-extension://qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq/"))
        XCTAssertFalse(allowlist.permits(callerOrigin: "chrome-extension://short/"))
        XCTAssertFalse(allowlist.permits(callerOrigin: "https://\(ourID)/"))
        XCTAssertFalse(allowlist.permits(callerOrigin: ""))
        XCTAssertFalse(Allowlist(allowedExtensionIDs: []).permits(callerOrigin: "chrome-extension://\(ourID)/"))
    }
}
