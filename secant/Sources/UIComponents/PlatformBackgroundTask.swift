//
//  PlatformBackgroundTask.swift
//  Zashi
//
//  Cross-platform alias for the background-task handle. iOS uses `BGProcessingTask`; macOS has no
//  BackgroundTasks framework, so a no-op placeholder lets the (iOS-only-fired) background-task flow
//  type-check. Native macOS background processing is a separate follow-up.
//

#if os(iOS)
import BackgroundTasks
typealias PlatformBackgroundTask = BGProcessingTask
#else
struct PlatformBackgroundTask: Equatable {
    func setTaskCompleted(success: Bool) {}
}
#endif
