//
//  AboutTests.swift
//  zodlTests
//
//  More tests — settings. Covers the About reducer (Features/About/AboutStore.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct AboutTests {
    @MainActor @Test func onAppearLoadsVersionAndBuild() async {
        let store = TestStore(initialState: About.State()) {
            About()
        } withDependencies: {
            $0.appVersion.appVersion = { "1.2.3" }
            $0.appVersion.appBuild = { "42" }
        }
        await store.send(.onAppear) {
            $0.appVersion = "1.2.3"
            $0.appBuild = "42"
        }
    }

    @MainActor @Test func privacyPolicyTappedOpensBrowser() async {
        let store = TestStore(initialState: About.State()) { About() }
        await store.send(.privacyPolicyButtonTapped) {
            $0.isInAppBrowserPolicyOn = true
        }
    }

    @MainActor @Test func termsOfUseTappedOpensBrowser() async {
        let store = TestStore(initialState: About.State()) { About() }
        await store.send(.termsOfUseButtonTapped) {
            $0.isInAppBrowserTermsOn = true
        }
    }
}
