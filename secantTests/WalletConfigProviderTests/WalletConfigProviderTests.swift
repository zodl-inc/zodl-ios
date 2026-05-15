//
//  WalletConfigProviderTests.swift
//  secantTests
//
//  Created by Michal Fousek on 23.02.2023.
//

@preconcurrency import Combine
import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class WalletConfigProviderTests: XCTestCase {
    var cancellables: [AnyCancellable] = []

    override func setUp() {
        super.setUp()
        UserDefaultsWalletConfigStorage().clearAll()
    }

    override func tearDown() {
        super.tearDown()
        cancellables = []
    }

    func testTestFlagsAreDisabledByDefault() {
        XCTAssertFalse(WalletConfig.initial.isEnabled(.testFlag1))
        XCTAssertFalse(WalletConfig.initial.isEnabled(.testFlag2))
    }

    func testLoadFlagsFromProvider() async {
        let sourceProvider = WalletConfigSourceProviderMock() {
            return WalletConfig(flags: [.testFlag1: true, .testFlag2: false])
        }

        let provider = WalletConfigProvider(configSourceProvider: sourceProvider, cache: UserDefaultsWalletConfigStorage())
        let configuration = await loadWalletConfig(provider)

        XCTAssertTrue(configuration.isEnabled(.testFlag1))
        XCTAssertFalse(configuration.isEnabled(.testFlag2))
    }

    func testLoadFlagsFromCache() async {
        let sourceProvider = WalletConfigSourceProviderMock() { throw NSError(domain: "whatever", code: 21) }
        let cache = WalletConfigProviderCacheMock(cachedFlags: [.testFlag1: false, .testFlag2: true])

        let provider = WalletConfigProvider(configSourceProvider: sourceProvider, cache: cache)
        let configuration = await loadWalletConfig(provider)

        XCTAssertFalse(configuration.isEnabled(.testFlag1))
        XCTAssertTrue(configuration.isEnabled(.testFlag2))
    }

    func testLoadDefaultFlags() async {
        let sourceProvider = WalletConfigSourceProviderMock() { throw NSError(domain: "whatever", code: 21) }
        let cache = WalletConfigProviderCacheMock(cachedFlags: [:])

        let provider = WalletConfigProvider(configSourceProvider: sourceProvider, cache: cache)
        let configuration = await loadWalletConfig(provider)

        XCTAssertFalse(configuration.isEnabled(.testFlag1))
        XCTAssertFalse(configuration.isEnabled(.testFlag2))
    }

    func testAllTheFlagsAreAlwaysReturned() async {
        let sourceProvider = WalletConfigSourceProviderMock() {
            return WalletConfig(flags: [.testFlag1: true])
        }

        let provider = WalletConfigProvider(configSourceProvider: sourceProvider, cache: UserDefaultsWalletConfigStorage())
        let configuration = await loadWalletConfig(provider)

        XCTAssertTrue(configuration.isEnabled(.testFlag1))
        XCTAssertFalse(configuration.isEnabled(.testFlag2))
    }

    func testProvidedFlagsAreCached() async {
        let sourceProvider = WalletConfigSourceProviderMock() {
            return WalletConfig(flags: [.testFlag1: true, .testFlag2: false])
        }
        let cache: WalletConfigProviderCache = UserDefaultsWalletConfigProviderCache()

        let provider = WalletConfigProvider(configSourceProvider: sourceProvider, cache: cache)
        _ = await loadWalletConfig(provider)

        guard let cachedConfiguration = await cache.load() else {
            return XCTFail("No cached configuration.")
        }

        XCTAssertTrue(cachedConfiguration.isEnabled(.testFlag1))
        XCTAssertFalse(cachedConfiguration.isEnabled(.testFlag2))
    }

    private func loadWalletConfig(_ provider: WalletConfigProvider) async -> WalletConfig {
        let expectation = XCTestExpectation()
        expectation.expectedFulfillmentCount = 2
        var configuration: WalletConfig!

        await withCheckedContinuation { continuation in
            provider.load()
                .sink(
                    receiveCompletion: { _ in
                        expectation.fulfill()
                        continuation.resume()
                    },
                    receiveValue: {
                        configuration = $0
                        expectation.fulfill()
                    }
                )
                .store(in: &cancellables)
        }

        await fulfillment(of: [expectation], timeout: 1)

        return configuration
    }
    
    @MainActor func testPropagationOfFlagUpdate() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        // Change any of the flags from the default value
        var defaultRawFlags = WalletConfig.initial.flags
        defaultRawFlags[.onboardingFlow] = true
        let flags = WalletConfig(flags: defaultRawFlags)
        
        await store.send(.debug(.walletConfigLoaded(flags)))
        
        // The new flag's value has to be propagated to all `walletConfig` instances
        await store.receive(.updateStateAfterConfigUpdate(flags)) { state in
            state.walletConfig = flags
            state.onboardingState.walletConfig = flags
//            state.tabsState.homeState.walletConfig = flags
        }
        
        await store.finish()
    }
}

struct WalletConfigSourceProviderMock: WalletConfigSourceProvider {
    let provider: () async throws -> WalletConfig

    func load() async throws -> WalletConfig {
        return try await provider()
    }
}

class WalletConfigProviderCacheMock: WalletConfigProviderCache {
    var cachedFlags: WalletConfig.RawFlags = [:]

    init(cachedFlags: WalletConfig.RawFlags) {
        self.cachedFlags = cachedFlags
    }

    func load() async -> WalletConfig? {
        guard !cachedFlags.isEmpty else { return nil }
        return WalletConfig(flags: cachedFlags)
    }

    func store(_ configuration: WalletConfig) async {
        cachedFlags = configuration.flags
    }
}

extension UserDefaultsWalletConfigStorage {
    func clearAll() {
        let userdef = UserDefaults.standard
        userdef.removeObject(forKey: Constants.cacheKey)
        userdef.removeObject(forKey: Constants.providerKey)
        userdef.synchronize()
    }
}
