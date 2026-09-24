import XCTest
import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

final class AutomaticServerSelectionMigrationTests: XCTestCase {
    /// In-memory stand-in for the parts of `userStoredPreferences` the migration touches.
    private final class Box: @unchecked Sendable {
        var server: UserPreferencesStorage.ServerConfig?
        var flag: Bool?
        init(server: UserPreferencesStorage.ServerConfig?) { self.server = server }
    }

    private func runMigration(network: NetworkType, server: UserPreferencesStorage.ServerConfig?) -> Bool? {
        let box = Box(server: server)
        withDependencies {
            $0.userStoredPreferences.server = { box.server }
            $0.userStoredPreferences.automaticServerSelection = { box.flag }
            $0.userStoredPreferences.setAutomaticServerSelection = { box.flag = $0 }
        } operation: {
            ZcashSDKEnvironment.initializeAutomaticServerSelectionIfNeeded(for: network)
        }
        return box.flag
    }

    func testNoStoredServerEnablesAutomatic() {
        XCTAssertEqual(runMigration(network: .mainnet, server: nil), true)
    }

    func testDefaultServerEnablesAutomatic() {
        let def = ZcashSDKEnvironment.defaultEndpoint(for: .mainnet)
        let config = UserPreferencesStorage.ServerConfig(host: def.host, port: def.port, isCustom: false)
        XCTAssertEqual(runMigration(network: .mainnet, server: config), true)
    }

    func testCustomServerSelectsManual() {
        let config = UserPreferencesStorage.ServerConfig(host: "my.server.example", port: 9067, isCustom: true)
        XCTAssertEqual(runMigration(network: .mainnet, server: config), false)
    }

    func testNonDefaultKnownServerEnablesAutomatic() {
        // A known server picked from the old server list is stored as non-custom; with no
        // user-entered custom server, the user migrates to Automatic.
        let config = UserPreferencesStorage.ServerConfig(host: "na.zec.rocks", port: 443, isCustom: false)
        XCTAssertEqual(runMigration(network: .mainnet, server: config), true)
    }

    func testLegacyBuiltInServerEnablesAutomatic() {
        // A legacy built-in host (e.g. *.zcash-infra.com) was never a user-typed custom server: it is
        // stored non-custom, so it migrates to Automatic even though it no longer appears in the list
        // and is display-normalized to "custom" elsewhere.
        let config = UserPreferencesStorage.ServerConfig(host: "lwd1.zcash-infra.com", port: 443, isCustom: false)
        XCTAssertEqual(runMigration(network: .mainnet, server: config), true)
    }

    func testRunsOnlyOnce() {
        let box = Box(server: nil)
        box.flag = false // pretend the user already chose Manual
        withDependencies {
            $0.userStoredPreferences.server = { box.server }
            $0.userStoredPreferences.automaticServerSelection = { box.flag }
            $0.userStoredPreferences.setAutomaticServerSelection = { box.flag = $0 }
        } operation: {
            ZcashSDKEnvironment.initializeAutomaticServerSelectionIfNeeded(for: .mainnet)
        }
        XCTAssertEqual(box.flag, false, "Migration must not overwrite an already-set flag")
    }
}
