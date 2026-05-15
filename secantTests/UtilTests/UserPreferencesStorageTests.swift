//
//  UserPreferencesStorageTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 22.03.2022.
//

import XCTest
@testable import secant_testnet

class UserPreferencesStorageTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    var storage: UserPreferencesStorage!

    override func setUp() {
        super.setUp()
        
        guard let userDefaults = UserDefaults.init(suiteName: "test") else {
            XCTFail("UserPreferencesStorageTests: UserDefaults.init(suiteName: \"test\") failed to initialize")
            return
        }
        
        storage = UserPreferencesStorage(
            defaultExchangeRate: Data(),
            defaultServer: Data(),
            userDefaults: .live(userDefaults: userDefaults)
        )
        storage.removeAll()
    }
    
    override func tearDown() {
        super.tearDown()
        storage.removeAll()
        storage = nil
    }
    
    // MARK: - Default values in the live UserDefaults environment
    
    func testDefaultServer_defaultValue() throws {
        XCTAssertEqual(nil, storage.server, "User Preferences: `defaultServer` default doesn't match.")
    }

    // MARK: - Set new values in the live UserDefaults environment

    func testDefaultServer_setNewValue() throws {
        let serverConfig = UserPreferencesStorage.ServerConfig(host: "host", port: 13, isCustom: true)
        try storage.setServer(serverConfig)

        XCTAssertEqual(serverConfig, storage.server, "User Preferences: `server` default doesn't match.")
    }

    // MARK: - Mocked user defaults vs. default values

    func testDefaultServer_mocked() throws {
        let mockedUD = UserDefaultsClient(
            objectForKey: { _ in Data() },
            remove: { _ in },
            setValue: { _, _ in }
        )
        
        let mockedStorage = UserPreferencesStorage(
            defaultExchangeRate: Data(),
            defaultServer: Data(),
            userDefaults: mockedUD
        )

        XCTAssertEqual(nil, mockedStorage.server, "User Preferences: `server` default doesn't match.")
    }

    // MARK: - Remove all keys from the live UD environment
    
    func testRemoveAll() throws {
        guard let userDefaults = UserDefaults.init(suiteName: "test") else {
            XCTFail("User Preferences: UserDefaults.init(suiteName: \"test\") failed to initialize")
            return
        }

        // fill in the data
        UserPreferencesStorage.Constants.allCases.forEach {
            userDefaults.set("anyValue", forKey: $0.rawValue)
        }

        // remove it
        storage?.removeAll()

        // check the presence
        UserPreferencesStorage.Constants.allCases.forEach {
            XCTAssertNil(
                userDefaults.object(forKey: $0.rawValue),
                "User Preferences: key \($0.rawValue) should be removed but it's still present in User Defaults"
            )
        }
    }
}
