import Foundation

public struct SpendabilityPIRConfig: Sendable {
    /// Base URL of the spendability PIR server.
    public let serverUrl: String

    public init(serverUrl: String) {
        self.serverUrl = serverUrl
    }

    /// Default config. Debug builds connect to a local spend-server;
    /// distribution builds use the production endpoint.
    #if SECANT_DISTRIB
    public static let `default` = SpendabilityPIRConfig(serverUrl: "https://pir.zashi.app")
    #else
    public static let `default` = SpendabilityPIRConfig(serverUrl: "http://localhost:8080")
    #endif
}
