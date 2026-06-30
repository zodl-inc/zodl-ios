//
//  WalletBirthdayTests.swift
//  zodlTests
//
//  More reducers — covers WalletBirthday computed strings, birthday validation, month list
//  derivation, height estimation and copy-to-pasteboard
//  (Features/WalletBirthday/WalletBirthdayStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct WalletBirthdayTests {
    // MARK: - Computed properties

    @Test func heightStringPrefersBirthdayOverEstimatedHeight() {
        var state = WalletBirthday.State()
        state.estimatedHeight = 2_500_000
        #expect(state.heightString == "2500000")

        state.birthday = "2600000"
        #expect(state.heightString == "2600000")
    }

    @Test func selectedDateStringJoinsMonthAndYear() {
        var state = WalletBirthday.State()
        state.selectedMonth = "October"
        state.selectedYear = 2018
        #expect(state.selectedDateString == "October 2018")
    }

    @Test func estimatedHeightStringFormatsHeightAsZatoshi() {
        var state = WalletBirthday.State()
        state.estimatedHeight = 1
        #expect(state.estimatedHeightString == Zatoshi(Int64(1 * 100_000_000)).decimalString())
    }

    // MARK: - Birthday binding validation

    @MainActor @Test func birthdayAtOrAboveSaplingActivationIsValid() async {
        let store = TestStore(initialState: WalletBirthday.State()) { WalletBirthday() } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
        }

        await store.send(.binding(.set(\.birthday, "300000"))) {
            $0.birthday = "300000"
            $0.estimatedHeight = 300_000
            $0.isValidBirthday = true
        }
    }

    @MainActor @Test func birthdayBelowSaplingActivationIsInvalid() async {
        let store = TestStore(initialState: WalletBirthday.State()) { WalletBirthday() } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
        }

        await store.send(.binding(.set(\.birthday, "1000"))) {
            $0.birthday = "1000"
            $0.isValidBirthday = false
        }
    }

    // MARK: - copyBirthdayTapped

    @MainActor @Test func copyBirthdayTappedCopiesHeightStringAndShowsToast() async {
        let copied = LockIsolated<RedactableString?>(nil)
        var state = WalletBirthday.State()
        state.estimatedHeight = 2_500_000
        let store = TestStore(initialState: state) { WalletBirthday() } withDependencies: {
            $0.pasteboard.setString = { copied.setValue($0) }
        }
        store.exhaustivity = .off

        await store.send(.copyBirthdayTapped)

        #expect(copied.value == "2500000".redacted)
        #expect(store.state.toast == .top(String(localizable: .generalCopiedToTheClipboard)))
    }

    // MARK: - updateMonths

    @MainActor @Test func updateMonthsForStartYearShowsTrailingMonthsAndPicksFirst() async {
        var state = WalletBirthday.State()
        state.selectedYear = WalletBirthday.Constants.startYear
        let store = TestStore(initialState: state) { WalletBirthday() }
        store.exhaustivity = .off

        await store.send(.updateMonths)

        // Sapling launched in October 2018, so only the final 3 months of that year are valid.
        #expect(store.state.months.count == 13 - WalletBirthday.Constants.startMonth)
        #expect(store.state.selectedMonth == store.state.months.first)
    }

    // MARK: - estimateHeightRequested

    @MainActor @Test func estimateHeightRequestedValidDateUsesSDKEstimate() async {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        var state = WalletBirthday.State()
        state.selectedMonth = formatter.monthSymbols[9] // October, locale-aware
        state.selectedYear = 2018
        let store = TestStore(initialState: state) { WalletBirthday() } withDependencies: {
            $0.sdkSynchronizer.estimateBirthdayHeight = { _ in 1_700_000 }
        }
        store.exhaustivity = .off

        await store.send(.estimateHeightRequested)

        #expect(store.state.estimatedHeight == 1_700_000)
        #expect(store.state.isValidBirthday)
    }

    @MainActor @Test func estimateHeightRequestedInvalidDateResetsHeight() async {
        var state = WalletBirthday.State()
        state.selectedMonth = "" // " 2018" cannot be parsed as "MMMM yyyy"
        state.selectedYear = 2018
        state.estimatedHeight = 999
        state.isValidBirthday = true
        let store = TestStore(initialState: state) { WalletBirthday() }

        await store.send(.estimateHeightRequested) {
            $0.estimatedHeight = 0
            $0.isValidBirthday = false
        }
    }
}
