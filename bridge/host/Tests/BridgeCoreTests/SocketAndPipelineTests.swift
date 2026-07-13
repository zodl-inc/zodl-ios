import XCTest

@testable import BridgeCore

final class UDSTests: XCTestCase {
    private func tempSocketPath() -> String {
        // sun_path caps at ~104 bytes — keep it short.
        "/tmp/zodl-bridge-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    func testSendLineReceivesAck() throws {
        let path = tempSocketPath()
        let listener = UDSListener(path: path) { line in
            XCTAssertEqual(String(data: line, encoding: .utf8), #"{"ping":true}"#)
            return Data(#"{"status":"received"}"#.utf8)
        }
        try listener.start()
        defer { listener.stop() }

        let ack = try UDSClient(path: path).sendLine(Data(#"{"ping":true}"#.utf8))
        XCTAssertEqual(String(data: ack, encoding: .utf8), #"{"status":"received"}"#)
    }

    func testConnectToMissingSocketFails() {
        let client = UDSClient(path: tempSocketPath())
        XCTAssertFalse(client.canConnect())
        XCTAssertThrowsError(try client.sendLine(Data("x".utf8))) {
            XCTAssertEqual($0 as? UDSError, .connectFailed)
        }
    }

    func testSilentListenerTimesOut() throws {
        let path = tempSocketPath()
        let listener = UDSListener(path: path) { _ in nil }
        try listener.start()
        defer { listener.stop() }

        XCTAssertThrowsError(try UDSClient(path: path).sendLine(Data("x".utf8), timeout: 0.2))
    }

    func testOverlongPathRejected() {
        let client = UDSClient(path: "/tmp/" + String(repeating: "a", count: 200) + ".sock")
        XCTAssertThrowsError(try client.sendLine(Data("x".utf8))) {
            XCTAssertEqual($0 as? UDSError, .pathTooLong)
        }
    }
}

final class WakerTests: XCTestCase {
    func testAlreadyListeningNeverLaunches() {
        var launches = 0
        let waker = Waker(probe: { true }, launch: { _ in launches += 1; return true }, sleepMs: { _ in })
        XCTAssertTrue(waker.ensureListening(bundleID: "co.zodl.test"))
        XCTAssertEqual(launches, 0)
    }

    func testLaunchesOnceThenPollsUntilUp() {
        var probes = 0
        var launches = 0
        var sleeps = 0
        let waker = Waker(
            probe: { probes += 1; return probes > 3 },
            launch: { _ in launches += 1; return true },
            sleepMs: { _ in sleeps += 1 }
        )
        XCTAssertTrue(waker.ensureListening(bundleID: "co.zodl.test", attempts: 10, delayMs: 1))
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(sleeps, 3)
    }

    func testGivesUpAfterAttempts() {
        let waker = Waker(probe: { false }, launch: { _ in true }, sleepMs: { _ in })
        XCTAssertFalse(waker.ensureListening(bundleID: "co.zodl.test", attempts: 5, delayMs: 1))
    }

    func testNoBundleIDMeansNoLaunch() {
        var launches = 0
        let waker = Waker(probe: { false }, launch: { _ in launches += 1; return true }, sleepMs: { _ in })
        XCTAssertFalse(waker.ensureListening(bundleID: nil))
        XCTAssertEqual(launches, 0)
    }
}

final class HostPipelineTests: XCTestCase {
    private let ourID = "abcdefghijklmnopabcdefghijklmnop"
    private var caller: String { "chrome-extension://\(ourID)/" }

    private func environment(
        deliver: @escaping (Data) throws -> Data = { _ in Data(#"{"status":"received"}"#.utf8) },
        listening: Bool = true
    ) -> HostPipeline.Environment {
        HostPipeline.Environment(
            allowlist: Allowlist(allowedExtensionIDs: [ourID]),
            deliver: deliver,
            ensureListening: { listening }
        )
    }

    private func framedValidMessage() -> Data {
        let message = BridgeMessage(
            v: 1,
            id: "A3F0C2D1-0000-4000-8000-000000000001",
            type: "payRequest",
            uri: "zcash:u1qxyz?amount=1.5",
            origin: "https://shop.example"
        )
        return NativeMessaging.frame(try! JSONEncoder().encode(message))
    }

    private func reader(_ data: Data) -> (Int) -> Data {
        var cursor = 0
        return { count in
            let end = min(cursor + count, data.count)
            defer { cursor = end }
            return data.subdata(in: cursor..<end)
        }
    }

    private func ack(from framed: Data) -> HostPipeline.Ack {
        try! JSONDecoder().decode(HostPipeline.Ack.self, from: framed.dropFirst(4))
    }

    func testHappyPathDeliversOriginalBodyAndAcksReceived() {
        var delivered: Data?
        let out = HostPipeline.handle(
            framedInput: reader(framedValidMessage()),
            callerOrigin: caller,
            env: environment(deliver: { delivered = $0; return Data(#"{"status":"received"}"#.utf8) })
        )
        XCTAssertEqual(ack(from: out), .received)
        let roundTripped = try! JSONDecoder().decode(BridgeMessage.self, from: delivered!)
        XCTAssertEqual(roundTripped.uri, "zcash:u1qxyz?amount=1.5")
    }

    func testForeignCallerRejectedWithoutReadingOrDelivering() {
        var delivered = false
        let out = HostPipeline.handle(
            framedInput: reader(framedValidMessage()),
            callerOrigin: "chrome-extension://qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq/",
            env: environment(deliver: { _ in delivered = true; return Data() })
        )
        XCTAssertEqual(ack(from: out).status, "rejected")
        XCTAssertEqual(ack(from: out).reason, "caller-not-allowed")
        XCTAssertFalse(delivered)
    }

    func testInvalidMessageRejected() {
        let bad = BridgeMessage(v: 1, id: "x", type: "payRequest", uri: "bitcoin:x", origin: "https://a.example")
        let framed = NativeMessaging.frame(try! JSONEncoder().encode(bad))
        let out = HostPipeline.handle(framedInput: reader(framed), callerOrigin: caller, env: environment())
        XCTAssertEqual(ack(from: out).status, "rejected")
        XCTAssertTrue(ack(from: out).reason?.hasPrefix("invalid:") ?? false)
    }

    func testGarbageJSONRejected() {
        let framed = NativeMessaging.frame(Data("not json".utf8))
        let out = HostPipeline.handle(framedInput: reader(framed), callerOrigin: caller, env: environment())
        XCTAssertEqual(ack(from: out).reason, "bad-json")
    }

    func testUnreachableZodlRejected() {
        let out = HostPipeline.handle(
            framedInput: reader(framedValidMessage()),
            callerOrigin: caller,
            env: environment(listening: false)
        )
        XCTAssertEqual(ack(from: out).reason, "zodl-unreachable")
    }

    func testDeliveryFailureRejected() {
        let out = HostPipeline.handle(
            framedInput: reader(framedValidMessage()),
            callerOrigin: caller,
            env: environment(deliver: { _ in throw UDSError.timeout })
        )
        XCTAssertEqual(ack(from: out).reason, "delivery-failed")
    }
}
