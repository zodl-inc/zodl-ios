import Foundation

/// The whole helper as a pure-ish function: framed request bytes in, framed ack bytes
/// out. `main.swift` is only stdin/stdout plumbing around this — everything here is
/// unit-tested without processes or sockets.
public enum HostPipeline {
    public struct Ack: Codable, Equatable {
        public let status: String
        public let reason: String?

        public static let received = Ack(status: "received", reason: nil)
        public static func rejected(_ reason: String) -> Ack { Ack(status: "rejected", reason: reason) }
    }

    public struct Environment {
        public var allowlist: Allowlist
        public var deliver: (Data) throws -> Data
        public var ensureListening: () -> Bool

        public init(allowlist: Allowlist, deliver: @escaping (Data) throws -> Data, ensureListening: @escaping () -> Bool) {
            self.allowlist = allowlist
            self.deliver = deliver
            self.ensureListening = ensureListening
        }
    }

    /// Processes exactly one message (the helper is one-shot by design).
    public static func handle(framedInput read: (Int) -> Data, callerOrigin: String, env: Environment) -> Data {
        let ack = process(read: read, callerOrigin: callerOrigin, env: env)
        let payload = (try? JSONEncoder().encode(ack)) ?? Data("{\"status\":\"rejected\"}".utf8)
        return NativeMessaging.frame(payload)
    }

    static func process(read: (Int) -> Data, callerOrigin: String, env: Environment) -> Ack {
        guard env.allowlist.permits(callerOrigin: callerOrigin) else {
            return .rejected("caller-not-allowed")
        }
        let body: Data
        do {
            body = try NativeMessaging.readMessage(read: read)
        } catch {
            return .rejected("bad-frame")
        }
        guard let message = try? JSONDecoder().decode(BridgeMessage.self, from: body) else {
            return .rejected("bad-json")
        }
        if let error = message.validate() {
            return .rejected("invalid:\(error)")
        }
        guard env.ensureListening() else {
            return .rejected("zodl-unreachable")
        }
        // Forward the ORIGINAL validated body — the helper never rewrites requests.
        guard let ackLine = try? env.deliver(body),
            let ack = try? JSONDecoder().decode(Ack.self, from: ackLine),
            ack.status == "received"
        else {
            return .rejected("delivery-failed")
        }
        return .received
    }
}
