//
//  BackgroundTaskClientLiveKey.swift
//  Zashi
//

import BackgroundTasks
import ComposableArchitecture
import UIKit
import os

private let logger = Logger(subsystem: "co.zodl", category: "BackgroundTaskClient")

/// Tracks the active continued processing task (iOS 26+) so endContinuedProcessing can find it.
@available(iOS 26.0, *)
private final class ContinuedProcessingState: Sendable {
    private let storage = OSAllocatedUnfairLock<BGContinuedProcessingTask?>(initialState: nil)

    func set(_ task: BGContinuedProcessingTask?) {
        storage.withLock { $0 = task }
    }

    func take() -> BGContinuedProcessingTask? {
        storage.withLock { task in
            let t = task
            task = nil
            return t
        }
    }
}

extension BackgroundTaskClient: DependencyKey {
    static let liveValue: Self = {
        // iOS 26 continued processing state (lazy, only allocated on iOS 26+)
        let cpState: Any? = {
            if #available(iOS 26.0, *) { return ContinuedProcessingState() }
            return nil
        }()

        return Self(
            beginTask: { name in
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = true
                    var taskId: UIBackgroundTaskIdentifier = .invalid
                    taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
                        logger.warning("Background task '\(name)' expired by iOS — ending task")
                        UIApplication.shared.isIdleTimerDisabled = false
                        UIApplication.shared.endBackgroundTask(taskId)
                        taskId = .invalid
                    }
                    return taskId
                }
            },
            endTask: { id in
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = false
                    guard id != .invalid else { return }
                    UIApplication.shared.endBackgroundTask(id)
                }
            },
            beginContinuedProcessing: { identifier, title, subtitle in
                guard #available(iOS 26.0, *), let state = cpState as? ContinuedProcessingState else {
                    return false
                }
                let request = BGContinuedProcessingTaskRequest(
                    identifier: identifier,
                    title: title,
                    subtitle: subtitle
                )
                request.strategy = .queue

                do {
                    try BGTaskScheduler.shared.submit(request)
                    logger.info("Continued processing task submitted: \(identifier)")

                    // The task is delivered via the handler registered for this identifier.
                    // Register a one-shot handler to capture the task object.
                    BGTaskScheduler.shared.register(
                        forTaskWithIdentifier: identifier,
                        using: .main
                    ) { task in
                        if let cpTask = task as? BGContinuedProcessingTask {
                            state.set(cpTask)
                        }
                    }
                    return true
                } catch {
                    logger.warning("Continued processing submission failed: \(error)")
                    return false
                }
            },
            endContinuedProcessing: {
                guard #available(iOS 26.0, *), let state = cpState as? ContinuedProcessingState else {
                    return
                }
                if let task = state.take() {
                    task.setTaskCompleted(success: true)
                    logger.info("Continued processing task completed")
                }
            }
        )
    }()
}
