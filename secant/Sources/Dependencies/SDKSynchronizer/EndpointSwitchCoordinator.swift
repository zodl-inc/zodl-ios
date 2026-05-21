//
//  EndpointSwitchCoordinator.swift
//  Zashi
//
//  Created by Adam Tucker on 2026-05-21.
//

import Foundation
@preconcurrency import ZcashLightClientKit

actor EndpointSwitchCoordinator {
    private var pendingTask: Task<Void, Error>?
    private var pendingTaskID: UUID?

    /// Serializes endpoint switches so only one SDK switch runs at a time.
    func switchToEndpoint(
        _ endpoint: LightWalletEndpoint,
        previousEndpoint: (@Sendable () async -> LightWalletEndpoint)? = nil,
        shouldProceed: @escaping @Sendable () async -> Bool = { true },
        performSwitch: @escaping @Sendable (LightWalletEndpoint) async throws -> Void
    ) async throws {
        try Task.checkCancellation()

        let previous = pendingTask
        let taskID = UUID()
        let task = Task {
            _ = try? await previous?.value

            var didSwitch = false
            do {
                try Task.checkCancellation()
                guard await shouldProceed() else { return }
                try Task.checkCancellation()
                try await performSwitch(endpoint)
                didSwitch = true
                try Task.checkCancellation()
            } catch {
                if didSwitch, let resolved = await previousEndpoint?() {
                    do {
                        try await performSwitch(resolved)
                    } catch {
                        LoggerProxy.error("[EndpointSwitch] Failed to restore endpoint after cancellation: \(error)")
                    }
                }
                throw error
            }
        }

        pendingTask = task
        pendingTaskID = taskID
        defer { clearPendingTask(id: taskID) }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func clearPendingTask(id: UUID) {
        guard pendingTaskID == id else { return }
        pendingTask = nil
        pendingTaskID = nil
    }
}

enum EndpointSwitching {
    static let coordinator = EndpointSwitchCoordinator()
}
