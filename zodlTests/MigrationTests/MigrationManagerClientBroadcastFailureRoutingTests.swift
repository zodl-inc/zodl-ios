//
//  MigrationManagerClientBroadcastFailureRoutingTests.swift
//  zodlTests
//
//  Covers the R9-T2 (finding 13) single classify -> route entry point
//  (Dependencies/MigrationManager/MigrationManagerClient+BroadcastFailureRouting.swift) — the two
//  `routeBroadcastFailure(_:result:)`/`routeBroadcastFailure(_:error:)` overloads that replace the
//  hand-repeated `MigrationBroadcastFailureClass.classify` -> `guard let` -> `routeBroadcastFailure`
//  pairing previously duplicated at 8 call sites (`RootInitialization`, `MigrationSendingStore`,
//  `MigrationNoteSplitStore`). `MigrationBroadcastFailureClass.classify`'s own decision table is
//  separately pinned in `MigrationBroadcastFailureTests`; these tests don't re-litigate it, they only
//  confirm the entry point forwards through the stored `routeBroadcastFailure` closure member (or
//  skips it entirely) faithfully. `MigrationManagerClient` has no registered `testValue` — customizing
//  `routeBroadcastFailure` via `withDependencies` is what unlocks the client for these tests.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

struct MigrationManagerClientBroadcastFailureRoutingTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 1, count: 16))

    private struct UnderlyingRecordFailure: Error { }

    // MARK: - routeBroadcastFailure(_:result:)

    /// Every non-classifiable result (`.success`, `.invalidNote`, `.expired`,
    /// `.networkError(retryable: false)`) must return `nil` WITHOUT invoking the closure member at
    /// all — call sites rely on the manager call being skipped entirely (the live impl records a
    /// routing episode on every real call, so a nil class must never reach it).
    @Test func resultOverloadWithNonClassifiableResultReturnsNilWithoutInvokingTheClosure() async {
        let callCount = LockIsolated<Int>(0)

        let route = await withDependencies {
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                callCount.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
        } operation: {
            @Dependency(\.migrationManager) var migrationManager
            return await migrationManager.routeBroadcastFailure(Self.accountUUID, result: MigrationTransferResult.success(txId: "tx"))
        }

        #expect(route == nil)
        #expect(callCount.value == 0)
    }

    /// A classifiable result (`.networkError(retryable: true)`) invokes the closure member with the
    /// exact classified class and the same account, forwarding its returned route.
    @Test func resultOverloadWithClassifiableResultInvokesTheClosureWithTheExactClass() async {
        let capturedArgs = LockIsolated<[(AccountUUID?, MigrationBroadcastFailureClass)]>([])

        let route = await withDependencies {
            $0.migrationManager.routeBroadcastFailure = { accountUUID, failureClass in
                capturedArgs.withValue { $0.append((accountUUID, failureClass)) }
                return MigrationBroadcastFailureRoute.torFirstRunChoice
            }
        } operation: {
            @Dependency(\.migrationManager) var migrationManager
            return await migrationManager.routeBroadcastFailure(Self.accountUUID, result: MigrationTransferResult.networkError(retryable: true))
        }

        #expect(route == MigrationBroadcastFailureRoute.torFirstRunChoice)
        #expect(capturedArgs.value.count == 1)
        #expect(capturedArgs.value.first?.0 == Self.accountUUID)
        #expect(capturedArgs.value.first?.1 == MigrationBroadcastFailureClass.endpointUnreachable)
    }

    // MARK: - routeBroadcastFailure(_:error:)

    /// `ZcashError.migrationRecordFailedAfterBroadcast` — the broadcast landed and only the engine's
    /// own recording of it failed — must return `nil` WITHOUT invoking the closure member.
    @Test func errorOverloadWithRecordFailedAfterBroadcastReturnsNilWithoutInvokingTheClosure() async {
        let callCount = LockIsolated<Int>(0)

        let route = await withDependencies {
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                callCount.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
        } operation: {
            @Dependency(\.migrationManager) var migrationManager
            return await migrationManager.routeBroadcastFailure(
                Self.accountUUID,
                error: ZcashError.migrationRecordFailedAfterBroadcast(UnderlyingRecordFailure())
            )
        }

        #expect(route == nil)
        #expect(callCount.value == 0)
    }

    /// A classifiable thrown error (`ZcashError.migrationTorUnavailable`) invokes the closure member
    /// with the exact classified class, forwarding its returned route.
    @Test func errorOverloadWithClassifiableErrorInvokesTheClosureWithTheExactClass() async {
        let capturedArgs = LockIsolated<[(AccountUUID?, MigrationBroadcastFailureClass)]>([])

        let route = await withDependencies {
            $0.migrationManager.routeBroadcastFailure = { accountUUID, failureClass in
                capturedArgs.withValue { $0.append((accountUUID, failureClass)) }
                return MigrationBroadcastFailureRoute.torHold
            }
        } operation: {
            @Dependency(\.migrationManager) var migrationManager
            return await migrationManager.routeBroadcastFailure(Self.accountUUID, error: ZcashError.migrationTorUnavailable)
        }

        #expect(route == MigrationBroadcastFailureRoute.torHold)
        #expect(capturedArgs.value.count == 1)
        #expect(capturedArgs.value.first?.0 == Self.accountUUID)
        #expect(capturedArgs.value.first?.1 == MigrationBroadcastFailureClass.torUnavailable)
    }

    /// A non-Tor, non-record-failure thrown error classifies as `.endpointUnreachable` — every other
    /// throw from a broadcast call is, by construction, a post-Tor-bootstrap connect/submit failure.
    @Test func errorOverloadWithGenericErrorClassifiesAsEndpointUnreachable() async {
        struct GenericFailure: Error { }
        let capturedArgs = LockIsolated<[(AccountUUID?, MigrationBroadcastFailureClass)]>([])

        let route = await withDependencies {
            $0.migrationManager.routeBroadcastFailure = { accountUUID, failureClass in
                capturedArgs.withValue { $0.append((accountUUID, failureClass)) }
                return MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
            }
        } operation: {
            @Dependency(\.migrationManager) var migrationManager
            return await migrationManager.routeBroadcastFailure(Self.accountUUID, error: GenericFailure())
        }

        #expect(route == MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false))
        #expect(capturedArgs.value.first?.1 == MigrationBroadcastFailureClass.endpointUnreachable)
    }
}
