//
//  ZecKeyboardTests.swift
//  zodlTests
//
//  Batch 3 — amount entry. Covers the ZecKeyboard reducer's input/validation/conversion logic
//  (Features/ZecKeyboard/ZecKeyboardStore.swift). Assertions use integer inputs (locale-independent).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized) struct ZecKeyboardTests {
    @Test func isNextButtonDisabledReflectsAmountAndZeroAllowed() {
        var state = ZecKeyboard.State()
        state.amount = .zero
        #expect(state.isNextButtonDisabled)

        state.isZeroOutputAllowed = true
        #expect(!state.isNextButtonDisabled)

        state.isZeroOutputAllowed = false
        state.amount = Zatoshi(1)
        #expect(!state.isNextButtonDisabled)
    }

    @MainActor @Test func tappingDigitReplacesLeadingZeroAndComputesZecAmount() async {
        let store = makeStore()
        await store.send(.keyTapped(4)) // "5"
        await store.receive(\.validateInputs)
        await store.receive(\.resolveHumanReadableStrings)
        #expect(store.state.input == "5")
        #expect(store.state.amount == Zatoshi(500_000_000)) // 5 ZEC
    }

    @MainActor @Test func eightFractionDigitsCapBlocksFurtherDigits() async {
        let store = makeStore(input: "1.12345678") // already 8 fraction digits
        await store.send(.keyTapped(0)) // "1" — must be ignored
        #expect(store.state.input == "1.12345678")
    }

    @MainActor @Test func backspaceViaLongKeyResetsToZero() async {
        let store = makeStore(input: "123")
        await store.send(.longKeyTapped(11))
        await store.receive(\.validateInputs)
        await store.receive(\.resolveHumanReadableStrings)
        #expect(store.state.input == "0")
    }

    @MainActor @Test func validateInputsExceedingMaxRevertsLastInput() async {
        let store = makeStore(input: "100000000") // 1e8 ZEC -> exceeds max supply
        await store.send(.validateInputs)
        await store.receive(\.revertLastInput)
        await store.receive(\.resolveHumanReadableStrings)
        #expect(store.state.input == "10000000") // reverted to 1e7 ZEC
        #expect(store.state.amount == Zatoshi(1_000_000_000_000_000))
    }

    @MainActor @Test func swapCurrenciesTogglesInputMode() async {
        let store = makeStore()
        #expect(store.state.isInputInZec)
        await store.send(.swapCurrenciesTapped)
        await store.receive(\.resolveHumanReadableStrings)
        #expect(!store.state.isInputInZec)
    }

    @MainActor @Test func zecInputConvertsToFiatUsingConversionRatio() async {
        let store = makeStore(currencyConversion: CurrencyConversion(.usd, ratio: 30, timestamp: 0), input: "1")
        await store.send(.validateInputs)
        await store.receive(\.resolveHumanReadableStrings)
        #expect(store.state.amount == Zatoshi(100_000_000)) // 1 ZEC
        #expect(store.state.currencyValue == 30) // 1 ZEC * $30
    }

    @MainActor
    private func makeStore(
        currencyConversion: CurrencyConversion? = nil,
        input: String = "0",
        isInputInZec: Bool = true,
        decimalSeparator: String = "."
    ) -> TestStoreOf<ZecKeyboard> {
        var state = ZecKeyboard.State()
        state.decimalSeparator = decimalSeparator
        state.keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", decimalSeparator, "0", "x"]
        state.input = input
        state.isInputInZec = isInputInZec
        state.$currencyConversion.withLock { $0 = currencyConversion }
        let store = TestStore(initialState: state) { ZecKeyboard() }
        store.exhaustivity = .off
        return store
    }
}
