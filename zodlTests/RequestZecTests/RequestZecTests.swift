//
//  RequestZecTests.swift
//  zodlTests
//
//  Batch 3 — payment requests. Covers RequestZec ZIP-321 URI generation
//  (Features/RequestZec/RequestZecStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized) struct RequestZecTests {
    private let testnetAddress =
        "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3"

    @MainActor @Test func generateQRCodeBuildsZip321RequestForAddressAndAmount() async {
        let store = makeStore(address: testnetAddress, requestedZec: Zatoshi(100_000_000))
        await store.send(.generateQRCode(false))
        let output = store.state.encryptedOutput
        #expect(output?.hasPrefix("zcash:") == true)
        #expect(output?.contains(testnetAddress) == true)
        #expect(output?.contains("amount=1") == true)
        await store.receive(\.rememberQR)
    }

    @MainActor @Test func generateEnlargedQRCodeIncludesMemoWhenPresent() async {
        let store = makeStore(address: testnetAddress, requestedZec: Zatoshi(100_000_000), memo: "hello")
        await store.send(.generateEnlargedQRCode)
        #expect(store.state.encryptedOutput?.contains("memo=") == true)
        await store.receive(\.rememberEnlargedQR)
    }

    @MainActor @Test func generateQRCodeWithInvalidAddressProducesNoOutput() async {
        let store = makeStore(address: "not-a-valid-address", requestedZec: Zatoshi(100_000_000))
        await store.send(.generateQRCode(false))
        #expect(store.state.encryptedOutput == nil)
    }

    @MainActor @Test func shareQRCopiesAndClearsEncryptedOutput() async {
        let store = makeStore(address: testnetAddress, requestedZec: Zatoshi(100_000_000))
        await store.send(.generateQRCode(false))
        await store.receive(\.rememberQR)
        await store.send(.shareQR)
        #expect(store.state.encryptedOutputToBeShared == store.state.encryptedOutput)
        await store.send(.shareFinished)
        #expect(store.state.encryptedOutputToBeShared == nil)
    }

    @MainActor
    private func makeStore(address: String, requestedZec: Zatoshi, memo: String = "") -> TestStoreOf<RequestZec> {
        var state = RequestZec.State()
        state.address = address.redacted
        state.requestedZec = requestedZec
        state.memoState.text = memo
        let store = TestStore(initialState: state) {
            RequestZec()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.zcashSDKEnvironment.memoCharLimit = { 512 }
        }
        store.exhaustivity = .off
        return store
    }
}
