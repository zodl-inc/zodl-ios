//
//  EndpointSwitchCoordinatorTests.swift
//  secantTests
//
//  Created by Adam Tucker on 2026-05-20.
//

import XCTest
import ZcashLightClientKit
@testable import secant_testnet

final class EndpointSwitchCoordinatorTests: XCTestCase {
    func testConcurrentSwitchesRunSequentially() async throws {
        let coordinator = EndpointSwitchCoordinator()
        let probe = SwitchProbe()
        let first = makeEndpoint("first.example.com")
        let second = makeEndpoint("second.example.com")

        let firstTask = Task {
            try await coordinator.switchToEndpoint(first) { endpoint in
                try await probe.switchToEndpoint(endpoint)
            }
        }
        await probe.waitForStarted(first.host)

        let secondTask = Task {
            try await coordinator.switchToEndpoint(second) { endpoint in
                try await probe.switchToEndpoint(endpoint)
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(await probe.startedHosts(), [first.host])

        await probe.finish(first.host)
        try await firstTask.value

        await probe.waitForStarted(second.host)
        await probe.finish(second.host)
        try await secondTask.value

        XCTAssertEqual(
            await probe.snapshotEvents(),
            [
                .started(first.host),
                .finished(first.host),
                .started(second.host),
                .finished(second.host)
            ]
        )
        XCTAssertEqual(await probe.maximumActiveSwitches(), 1)
    }

    func testQueuedSwitchCancelledBeforeFrontDoesNotCallSDK() async throws {
        let coordinator = EndpointSwitchCoordinator()
        let probe = SwitchProbe()
        let first = makeEndpoint("first.example.com")
        let queued = makeEndpoint("queued.example.com")

        let firstTask = Task {
            try await coordinator.switchToEndpoint(first) { endpoint in
                try await probe.switchToEndpoint(endpoint)
            }
        }
        await probe.waitForStarted(first.host)

        let queuedTask = Task {
            try await coordinator.switchToEndpoint(queued) { endpoint in
                try await probe.switchToEndpoint(endpoint)
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        queuedTask.cancel()

        await probe.finish(first.host)
        try await firstTask.value

        do {
            try await queuedTask.value
            XCTFail("Expected queued switch to be cancelled.")
        } catch is CancellationError {
        }

        XCTAssertEqual(
            await probe.snapshotEvents(),
            [
                .started(first.host),
                .finished(first.host)
            ]
        )
    }

    func testQueuedSwitchChecksShouldProceedBeforeSDKCall() async throws {
        let coordinator = EndpointSwitchCoordinator()
        let probe = SwitchProbe()
        let proceedFlag = ProceedFlag(true)
        let first = makeEndpoint("first.example.com")
        let automatic = makeEndpoint("automatic.example.com")

        let firstTask = Task {
            try await coordinator.switchToEndpoint(first) { endpoint in
                try await probe.switchToEndpoint(endpoint)
            }
        }
        await probe.waitForStarted(first.host)

        let automaticTask = Task {
            try await coordinator.switchToEndpoint(
                automatic,
                shouldProceed: {
                    await proceedFlag.value()
                },
                switchToEndpoint: { endpoint in
                    try await probe.switchToEndpoint(endpoint)
                }
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await proceedFlag.setValue(false)
        await probe.finish(first.host)

        try await firstTask.value
        try await automaticTask.value

        XCTAssertEqual(
            await probe.snapshotEvents(),
            [
                .started(first.host),
                .finished(first.host)
            ]
        )
    }

    func testCancellationAfterSwitchRestoresPreviousEndpoint() async throws {
        let coordinator = EndpointSwitchCoordinator()
        let probe = SwitchProbe()
        let target = makeEndpoint("target.example.com")
        let previous = makeEndpoint("previous.example.com")

        let switchTask = Task {
            try await coordinator.switchToEndpoint(
                target,
                previousEndpoint: previous,
                switchToEndpoint: { endpoint in
                    try await probe.switchToEndpoint(endpoint)
                }
            )
        }

        await probe.waitForStarted(target.host)
        switchTask.cancel()
        await probe.finish(target.host)

        await probe.waitForStarted(previous.host)
        await probe.finish(previous.host)

        do {
            try await switchTask.value
            XCTFail("Expected switch to throw cancellation after restoring previous endpoint.")
        } catch is CancellationError {
        }

        XCTAssertEqual(
            await probe.snapshotEvents(),
            [
                .started(target.host),
                .finished(target.host),
                .started(previous.host),
                .finished(previous.host)
            ]
        )
        XCTAssertEqual(await probe.maximumActiveSwitches(), 1)
    }

    private func makeEndpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(
            address: host,
            port: 443,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        )
    }
}

private actor SwitchProbe {
    enum Event: Equatable {
        case started(String)
        case finished(String)
    }

    private var activeSwitches = 0
    private var maxActiveSwitches = 0
    private var events: [Event] = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finishWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func switchToEndpoint(_ endpoint: LightWalletEndpoint) async throws {
        let host = endpoint.host
        activeSwitches += 1
        maxActiveSwitches = max(maxActiveSwitches, activeSwitches)
        events.append(.started(host))
        resumeStartWaiters(for: host)

        await withCheckedContinuation { continuation in
            finishWaiters[host] = continuation
        }

        events.append(.finished(host))
        activeSwitches -= 1
    }

    func waitForStarted(_ host: String) async {
        if startedHosts().contains(host) {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters[host, default: []].append(continuation)
        }
    }

    func finish(_ host: String) {
        finishWaiters.removeValue(forKey: host)?.resume()
    }

    func startedHosts() -> [String] {
        events.compactMap { event in
            if case let .started(host) = event {
                return host
            }
            return nil
        }
    }

    func snapshotEvents() -> [Event] {
        events
    }

    func maximumActiveSwitches() -> Int {
        maxActiveSwitches
    }

    private func resumeStartWaiters(for host: String) {
        let waiters = startWaiters.removeValue(forKey: host) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ProceedFlag {
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    func value() -> Bool {
        storedValue
    }

    func setValue(_ value: Bool) {
        storedValue = value
    }
}
