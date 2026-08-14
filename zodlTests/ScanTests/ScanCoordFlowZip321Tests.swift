//
//  ScanCoordFlowZip321Tests.swift
//  zodlTests
//
//  MOB-1348 — ZIP-321 multi-recipient guard. Confirms the scan → proposal chokepoint
//  (ScanCoordFlow.getProposal) signs only a single explicit recipient and fails closed on a
//  multi-payment ZIP-321 request, so a crafted multi-recipient QR can never hide a signed payment
//  (the Android dossier-#37 / MOB-1341 bug). The raw URI is never handed to the SDK.
//

import Foundation
import Testing
import ComposableArchitecture
import ZcashPaymentURI
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: drives a TCA coordinator that touches the process-global `selectedWalletAccount`
// @Shared state. `ScanCoordFlow.State` is not Equatable, so these tests drive a plain `Store` and
// poll for the expected outcome (same approach as the Swap/Flexa CoordFlow suites). Each test also
// binds `@Shared` to a fresh in-memory store so parallel suites can't clobber the selected account.
@Suite(.serialized) @MainActor struct ScanCoordFlowZip321Tests {
    private let testnetAddress =
        "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3"

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makePayment(amount: Double) throws -> Payment {
        let recipient = try #require(
            RecipientAddress(value: testnetAddress, context: ParserContext.from(networkType: .testnet))
        )
        return try Payment(
            recipientAddress: recipient,
            amount: try Amount(value: amount),
            memo: nil,
            label: nil,
            message: nil,
            otherParams: nil
        )
    }

    private func makeStore(
        proposeCalls: LockIsolated<[Recipient]>,
        initialPath: [ScanCoordFlow.Path.State] = []
    ) -> StoreOf<ScanCoordFlow> {
        var initialState = ScanCoordFlow.State()
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        for element in initialPath {
            initialState.path.append(element)
        }

        return Store(initialState: initialState) {
            ScanCoordFlow()
        } withDependencies: {
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.derivationTool = .liveValue
            $0.mainQueue = .immediate
            $0.mnemonic = .liveValue
            $0.numberFormatter = .liveValue
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeTransfer = { _, recipient, _, _ in
                proposeCalls.withValue { $0.append(recipient) }
                return .testOnlyFakeProposal(totalFee: 10_000)
            }
        }
    }

    /// A crafted two-recipient ZIP-321 request must fail closed: no proposal is built, nothing is
    /// signed, and the flow bounces back to the (empty) send form.
    @Test func multiPaymentRequestFailsClosedAndNeverProposes() async throws {
        let payment = try makePayment(amount: 0.001)
        let multiRequest = try PaymentRequest(payments: [payment, payment])
        let proposeCalls = LockIsolated<[Recipient]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(proposeCalls: proposeCalls)
            store.send(.getProposal(multiRequest))

            await waitForScanStore {
                if case .sendForm = store.state.path.last { return true }
                return false
            }

            #expect(proposeCalls.withValue { $0.isEmpty })
        }
    }

    /// A normal single-recipient request is unaffected by the guard: it proposes exactly once for
    /// that recipient (regression — the guard must not break ordinary payment-request QRs).
    @Test func singlePaymentRequestProposesFirstPayment() async throws {
        let payment = try makePayment(amount: 0.001)
        let singleRequest = PaymentRequest(singlePayment: payment)
        let proposeCalls = LockIsolated<[Recipient]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(proposeCalls: proposeCalls)
            store.send(.getProposal(singleRequest))

            await waitForScanStore {
                proposeCalls.withValue { $0.count == 1 }
            }

            let recipients = proposeCalls.withValue { $0 }
            #expect(recipients.count == 1)
            #expect(recipients.first?.stringEncoded == testnetAddress)
        }
    }

    /// Regression (MOB-1348): a multi-recipient request rejected *after* a prior successful
    /// single-payment scan must not leave that earlier scan's recipient/amount/memo behind. The guard
    /// fails closed before parsing, and those fields are only ever written when parsing succeeds, so
    /// without an explicit reset the rejection's bounce-back re-pre-fills the send form with stale
    /// payment data the user never re-scanned.
    @Test func multiPaymentRejectionClearsStalePaymentDetails() async throws {
        let singlePayment = try makePayment(amount: 0.001)
        let singleRequest = PaymentRequest(singlePayment: singlePayment)
        let multiRequest = try PaymentRequest(payments: [singlePayment, singlePayment])
        let proposeCalls = LockIsolated<[Recipient]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(proposeCalls: proposeCalls)

            // First scan: a valid single-payment QR populates recipient/amount/memo and builds a form.
            store.send(.getProposal(singleRequest))
            await waitForScanStore {
                proposeCalls.withValue { $0.count == 1 } && store.state.path.count == 2
            }
            #expect(store.state.recipient != nil)

            // Second scan: a crafted multi-recipient QR is rejected and bounces back to the send form.
            store.send(.getProposal(multiRequest))
            await waitForScanStore {
                store.state.path.count == 1
            }

            // The rejected scan must leave nothing of the previous payment behind.
            #expect(store.state.recipient == nil)
            #expect(store.state.amount == Zatoshi(0))
            #expect(store.state.memo == nil)
            // ...and it must never have proposed a transfer for the multi-recipient request.
            #expect(proposeCalls.withValue { $0.count == 1 })
        }
    }

    /// Cancelling the Orchard-spend warning sheet sends `.requestZecConfirmation(.cancelTapped)`,
    /// which must pop back to `sendForm` exactly like the screen's own back button
    /// (`.goBackTappedFromRequestZec`) — even when a stale `.scan` element is still sitting on the
    /// path underneath `requestZecConfirmation`. That shape is reproduced here: the send form's
    /// own Scan button pushes a second `.scan` on top of an existing `.sendForm`, and resolving
    /// that scan to a full payment request pushes `requestZecConfirmation` without first popping
    /// `.scan` (`.proposalResolvedExistingSendForm`) — so a naive single `popLast()` on cancel
    /// would strand the user on the stale scan/camera screen instead of the send form.
    @Test func cancelFromRequestZecConfirmationPopsPastStaleScanToSendForm() async throws {
        let payment = try makePayment(amount: 0.001)
        let singleRequest = PaymentRequest(singlePayment: payment)
        let proposeCalls = LockIsolated<[Recipient]>([])

        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                proposeCalls: proposeCalls,
                initialPath: [.sendForm(SendForm.State.initial), .scan(Scan.State.initial)]
            )

            store.send(.getProposal(singleRequest))

            // Confirms the bug's precondition actually reproduces: `requestZecConfirmation` lands
            // on top of a path that still has the stale `.scan` on it, both above `sendForm`.
            await waitForScanStore {
                store.state.path.count == 3
            }
            let requestZecId = try #require(store.state.path.ids.last)
            #expect(store.state.path[id: requestZecId]?.is(\.requestZecConfirmation) == true)

            // The pop itself is verified below; the known issue documents a pre-existing
            // composition wart rather than a defect of the cancel wiring: `coordinatorReduce()`
            // sits BEFORE the path `forEach` in the flow's `body`, so any handler that pops in
            // response to a path-element action (this one, and equally the screen's own
            // `.goBackTappedFromRequestZec` back button) removes the element before its child
            // reducer runs, and TCA reports "received an action for a missing element".
            withKnownIssue("pre-existing: coordinatorReduce() runs before .forEach, so the pop precedes the child reducer") {
                store.send(.path(.element(id: requestZecId, action: .requestZecConfirmation(.cancelTapped))))
            }

            await waitForScanStore {
                store.state.path.count == 1
            }
            #expect(store.state.path.last?.is(\.sendForm) == true)
        }
    }
}

@MainActor
private func waitForScanStore(
    timeoutNanoseconds: UInt64 = 60_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for ScanCoordFlow store state", sourceLocation: sourceLocation)
}
