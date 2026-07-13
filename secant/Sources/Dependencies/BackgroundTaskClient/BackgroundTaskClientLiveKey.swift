//
//  BackgroundTaskClientLiveKey.swift
//  Zashi
//

#if canImport(UIKit)
// @preconcurrency: BGContinuedProcessingTask is an Apple framework class (BackgroundTasks)
// not yet annotated Sendable. The compiler itself recommends this import in its hint.
@preconcurrency import BackgroundTasks
import ComposableArchitecture
import UIKit
import os

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
        // iOS 26 continued processing state (lazy, only allocated on iOS 26+).
        // Typed as `(any Sendable)?` rather than `Any?` so it can be captured by the
        // @Sendable closures below; ContinuedProcessingState is declared Sendable.
        let cpState: (any Sendable)? = {
            if #available(iOS 26.0, *) { return ContinuedProcessingState() }
            return nil
        }()

        return Self(
            beginTask: { name in
                await MainActor.run {
                    PlatformIdleTimer.disabled = true
                    var taskId: UIBackgroundTaskIdentifier = .invalid
                    taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
                        LoggerProxy.warn("Background task '\(name)' expired by iOS — ending task")
                        PlatformIdleTimer.disabled = false
                        UIApplication.shared.endBackgroundTask(taskId)
                        taskId = .invalid
                    }
                    return taskId
                }
            },
            endTask: { id in
                await MainActor.run {
                    PlatformIdleTimer.disabled = false
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
                    LoggerProxy.info("Continued processing task submitted: \(identifier)")

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
                    LoggerProxy.warn("Continued processing submission failed: \(error)")
                    return false
                }
            },
            endContinuedProcessing: {
                guard #available(iOS 26.0, *), let state = cpState as? ContinuedProcessingState else {
                    return
                }
                if let task = state.take() {
                    task.setTaskCompleted(success: true)
                    LoggerProxy.info("Continued processing task completed")
                }
            }
        )
    }()
}
#else
import ComposableArchitecture

extension BackgroundTaskClient: DependencyKey {
    // macOS: no UIKit background tasks; a Mac syncs while the app is open.
    static let liveValue = Self.noOp
}
#endif
