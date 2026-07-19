//
//  SendFormOrchardDisclaimerTests.swift
//  zodlTests
//
//  Covers SendForm's Orchard-spend disclaimer (MOB-1487 R3): Features/SendForm/SendFormStore.swift.
//  Detection hooks `.zecAmountUpdated` — whenever the entered ZEC amount changes, if Ironwood is
//  active (`migrationManager.isIronwoodActivated()`), a wallet account is selected, and the text
//  parses to a positive amount, a `sdkSynchronizer.sendRequiresOrchardFunds` dry-run runs and its
//  result drives `isOrchardSpendDisclaimerVisible`; otherwise the flag drops to false and any
//  in-flight dry-run is cancelled, without ever calling the stub. MOB-1496: the dry-run now hits
//  the real per-account SDK surface, so the guard additionally requires a resolvable `AccountUUID`.
//
//  NOTE: the detection parses `zecAmountText` via the `numberFormatter` dependency directly rather
//  than `state.amount`/`state.isValidAmount` — those computed properties are hardcoded under
//  `_XCTIsTesting` (see SendFormAddressValidationTests.swift's note) and would make this
//  untestable, always reporting `.zero`/`true` regardless of what's typed. `.serialized`: every
//  case drives the process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct SendFormOrchardDisclaimerTests {
    @MainActor @Test func defaultStateHasDisclaimerHidden() async {
        let state = SendForm.State.initial

        #expect(state.isOrchardSpendDisclaimerVisible == false)
    }

    @MainActor @Test func activatedWithPositiveAmountAndStubTrueShowsDisclaimer() async {
        let store = makeStore(isActivated: true, requiresOrchardFunds: { _, _ in true })

        await store.send(.zecAmountUpdated("1".redacted))
        await store.receive(\.orchardSpendCheckResult) {
            $0.isOrchardSpendDisclaimerVisible = true
        }
    }

    @MainActor @Test func activatedWithPositiveAmountAndStubFalseHidesDisclaimer() async {
        var initialState = SendForm.State.initial
        initialState.isOrchardSpendDisclaimerVisible = true
        let store = makeStore(initialState: initialState, isActivated: true, requiresOrchardFunds: { _, _ in false })

        await store.send(.zecAmountUpdated("1".redacted))
        await store.receive(\.orchardSpendCheckResult) {
            $0.isOrchardSpendDisclaimerVisible = false
        }
    }

    @MainActor @Test func notActivatedNeverCallsTheStubAndStaysHidden() async {
        let callCount = LockIsolated<Int>(0)
        let store = makeStore(isActivated: false, requiresOrchardFunds: { _, _ in
            callCount.withValue { $0 += 1 }
            return true
        })

        await store.send(.zecAmountUpdated("1".redacted))

        #expect(store.state.isOrchardSpendDisclaimerVisible == false)
        #expect(callCount.value == 0)
    }

    @MainActor @Test func clearingTheAmountHidesDisclaimerWithoutCallingTheStub() async {
        let callCount = LockIsolated<Int>(0)
        var initialState = SendForm.State.initial
        initialState.isOrchardSpendDisclaimerVisible = true
        let store = makeStore(initialState: initialState, isActivated: true, requiresOrchardFunds: { _, _ in
            callCount.withValue { $0 += 1 }
            return true
        })

        await store.send(.zecAmountUpdated(.empty)) {
            $0.isOrchardSpendDisclaimerVisible = false
        }

        #expect(callCount.value == 0)
    }

    /// MOB-1496: no selected account -> the guard short-circuits before the dry-run, same as the
    /// Ironwood-not-activated / non-positive-amount branches above.
    @MainActor @Test func noSelectedAccountNeverCallsTheStubAndStaysHidden() async {
        let callCount = LockIsolated<Int>(0)
        let store = makeStore(isActivated: true, hasSelectedAccount: false, requiresOrchardFunds: { _, _ in
            callCount.withValue { $0 += 1 }
            return true
        })

        await store.send(.zecAmountUpdated("1".redacted))

        #expect(store.state.isOrchardSpendDisclaimerVisible == false)
        #expect(callCount.value == 0)
    }

    // MARK: - MOB-1496: SDKSynchronizerClient.requiresOrchardFunds(amount:balance:) — pure, table-testable

    @Test func requiresOrchardFundsTable() {
        struct Row {
            let name: String
            let balance: AccountBalance
            let amount: Zatoshi
            let expected: Bool
        }

        let rows: [Row] = [
            Row(
                name: "non-Orchard alone covers the amount -> false",
                balance: Self.balance(sapling: 1_000, orchard: 500),
                amount: Zatoshi(800),
                expected: false
            ),
            Row(
                name: "non-Orchard short, Orchard covers the gap -> true",
                balance: Self.balance(sapling: 300, orchard: 700),
                amount: Zatoshi(800),
                expected: true
            ),
            Row(
                name: "non-Orchard short, Orchard still not enough -> false",
                balance: Self.balance(sapling: 300, orchard: 200),
                amount: Zatoshi(800),
                expected: false
            ),
            Row(
                name: "non-Orchard exactly equals the amount -> false (boundary: strictly-less guard)",
                balance: Self.balance(sapling: 800, orchard: 1_000),
                amount: Zatoshi(800),
                expected: false
            ),
            Row(
                name: "total (non-Orchard + Orchard) exactly equals the amount -> true (inclusive boundary)",
                balance: Self.balance(sapling: 300, orchard: 500),
                amount: Zatoshi(800),
                expected: true
            ),
            Row(
                name: "Ironwood alone already covers the amount -> false",
                balance: Self.balance(orchard: 500, ironwood: 1_000),
                amount: Zatoshi(800),
                expected: false
            ),
            Row(
                name: "unshielded (transparent) alone already covers the amount -> false",
                balance: Self.balance(orchard: 500, unshielded: 1_000),
                amount: Zatoshi(800),
                expected: false
            ),
            Row(
                name: "everything zero, positive amount -> false (can't afford at all, not an Orchard-specific gap)",
                balance: Self.balance(),
                amount: Zatoshi(800),
                expected: false
            )
        ]

        for row in rows {
            let result = SDKSynchronizerClient.requiresOrchardFunds(amount: row.amount, balance: row.balance)
            #expect(result == row.expected, "Row '\(row.name)' expected \(row.expected) but got \(result)")
        }
    }

    private static func balance(sapling: Int64 = 0, orchard: Int64 = 0, ironwood: Int64 = 0, unshielded: Int64 = 0) -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(sapling), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(orchard), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(ironwood), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: Zatoshi(unshielded)
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        initialState: SendForm.State = .initial,
        isActivated: Bool,
        hasSelectedAccount: Bool = true,
        requiresOrchardFunds: @escaping @Sendable (AccountUUID, Zatoshi) async -> Bool = { _, _ in false }
    ) -> TestStoreOf<SendForm> {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { current in
            current = hasSelectedAccount
                ? WalletAccount(
                    Account(
                        id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                        name: "Zodl",
                        keySource: nil,
                        seedFingerprint: nil,
                        hdAccountIndex: Zip32AccountIndex(0),
                        ufvk: nil,
                        uivk: nil
                    )
                )
                : nil
        }

        let store = TestStore(initialState: initialState) {
            SendForm()
        } withDependencies: {
            $0.migrationManager.isIronwoodActivated = { isActivated }
            $0.sdkSynchronizer.sendRequiresOrchardFunds = requiresOrchardFunds
            $0.numberFormatter.number = { text in
                Double(text).map { value in NSNumber(value: value) }
            }
        }
        store.exhaustivity = .off
        return store
    }
}
