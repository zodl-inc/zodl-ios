//
//  RestoreWalletPasteSeedTests.swift
//  zodlTests
//
//  The paste-seed shortcut — long-pressing the "Secret Recovery Phrase" title on the
//  seed-entry screen sends `.debugPasteSeed`, which fills the 24 word fields from the
//  pasteboard, falling back to `PartnerKeys.testSeed` when the pasteboard is empty or its
//  content is not a valid mnemonic. These tests characterize that reducer path; they
//  guard it while its compile-time gate moves from `#if DEBUG` to `#if !SECANT_DISTRIB`.
//  The gate itself cannot be unit-tested from a Debug test build — it is proven by
//  building the Release-AppStore configuration (feature compiled out) and the
//  Release-Testflight configuration (feature compiled in).
//
//  RestoreWalletCoordFlow.State is not Equatable (it holds a non-Equatable StackState and
//  an Action-typed AlertState), so TestStore will not compile against it. These tests
//  drive a plain Store and read state directly after sending actions — the same approach
//  as RestoreWalletAnnouncementFlagTests in this directory. Initial state is set up
//  before Store creation (store.state is get-only on a plain Store).
//
//  PartnerKeys is a static bundle-plist lookup that cannot be injected and
//  PartnerKeys.plist is gitignored, so which fallback branch is reachable depends on the
//  machine — the testSeed-application test runs only where a testSeed exists
//  (`.enabled(if:)`), the untouched-fields tests only where it does not
//  (`.disabled(if:)`); a skipped test is visible in the report, unlike a silently-taken
//  default branch.
//
//  .debugPasteSeed does all its work synchronously inside the reducer body and returns
//  .none, so no waiting is needed after `send`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@MainActor struct RestoreWalletPasteSeedTests {
    struct InvalidSeed: Error { }

    @Test func pasteValidSeedFillsAllWordFields() {
        let seedWords = (1...24).map { "word\($0)" }
        var initialState = RestoreWalletCoordFlow.State()
        initialState.isKeyboardVisible = true

        let store = Store(initialState: initialState) {
            RestoreWalletCoordFlow()
        } withDependencies: {
            $0.pasteboard.getString = { seedWords.joined(separator: " ").redacted }
            $0.mnemonic.isValid = { _ in }
        }

        store.send(.debugPasteSeed)

        #expect(store.state.words == seedWords)
        #expect(store.state.isValidSeed == true)
        #expect(store.state.isKeyboardVisible == false)
    }

    @Test(.enabled(if: PartnerKeys.testSeed != nil))
    func pasteInvalidSeedAppliesTestSeed() {
        let store = Store(initialState: RestoreWalletCoordFlow.State()) {
            RestoreWalletCoordFlow()
        } withDependencies: {
            $0.pasteboard.getString = { "definitely not a seed".redacted }
            $0.mnemonic.isValid = { _ in throw InvalidSeed() }
        }

        store.send(.debugPasteSeed)

        let testSeed = PartnerKeys.testSeed ?? ""
        #expect(store.state.words == testSeed.components(separatedBy: " "))
        #expect(store.state.isValidSeed == true)
    }

    @Test(.disabled(if: PartnerKeys.testSeed != nil))
    func pasteInvalidSeedWithoutTestSeedLeavesWordsAndMarksInvalid() {
        var initialState = RestoreWalletCoordFlow.State()
        initialState.words[3] = "hello"
        initialState.isValidSeed = true

        let store = Store(initialState: initialState) {
            RestoreWalletCoordFlow()
        } withDependencies: {
            $0.pasteboard.getString = { "definitely not a seed".redacted }
            $0.mnemonic.isValid = { _ in throw InvalidSeed() }
        }

        store.send(.debugPasteSeed)

        #expect(store.state.words[3] == "hello")
        #expect(store.state.isValidSeed == false)
    }

    @Test(.disabled(if: PartnerKeys.testSeed != nil))
    func emptyPasteboardWithoutTestSeedLeavesWordsAndMarksInvalid() {
        var initialState = RestoreWalletCoordFlow.State()
        initialState.words[3] = "hello"
        initialState.isValidSeed = true

        let store = Store(initialState: initialState) {
            RestoreWalletCoordFlow()
        } withDependencies: {
            $0.pasteboard.getString = { nil }
            $0.mnemonic.isValid = { _ in throw InvalidSeed() }
        }

        store.send(.debugPasteSeed)

        #expect(store.state.words[3] == "hello")
        #expect(store.state.isValidSeed == false)
    }
}
