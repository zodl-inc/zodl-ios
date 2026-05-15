//
//  AppDelegate.swift
//  secant
//
//  Created by Lukáš Korba on 30.12.2023.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import Network
import Atomics

import BackgroundTasks
import UserNotifications

// swiftlint:disable indentation_width
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let bcgTaskId = "co.electriccoin.power_wifi_sync"
    private let bcgSchedulerTaskId = "co.electriccoin.scheduler"
    private var monitor: NWPathMonitor?
    private let workerQueue = DispatchQueue(label: "Monitor")
    private let isConnectedToWifi = ManagedAtomic(false)

    let rootStore = StoreOf<Root>(
        initialState: .initial
    ) {
        Root()
            .logging()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG
        // Short-circuit if running unit tests to avoid side-effects from the app running.
        guard !_XCTIsTesting else { return true }
        walletLogger = OSLogger(logLevel: .debug, category: LoggerConstants.walletLogs)
#endif
        handleBackgroundTask()

        // set the default behavior for the NSDecimalNumber
        NSDecimalNumber.defaultBehavior = Zatoshi.decimalHandler
        
        rootStore.send(.initialization(.appDelegate(.didFinishLaunching)))

        return true
    }

    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        return extensionPointIdentifier != UIApplication.ExtensionPointIdentifier.keyboard
    }
}

// MARK: - BackgroundTasks

extension AppDelegate {
    private func handleBackgroundTask() {
        // We require the background task to run when connected to the power and wifi
        monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor?.pathUpdateHandler = { [weak self] path in
            self?.isConnectedToWifi.store(path.status == .satisfied, ordering: .relaxed)
            LoggerProxy.event("BGTask isConnectedToWifi \(path.status == .satisfied)")
        }
        monitor?.start(queue: workerQueue)
        
        registerTasks()
    }
    
    private func registerTasks() {
        let bcgSyncTaskResult = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bcgTaskId,
            using: DispatchQueue.main
        ) { [self] task in
            LoggerProxy.event("BGTask BGTaskScheduler.shared.register SYNC called")
            guard let task = task as? BGProcessingTask else {
                return
            }
            
            startBackgroundTask(task)
        }

        LoggerProxy.event("BGTask SYNC registered \(bcgSyncTaskResult)")

        let bcgSchedulerTaskResult = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bcgSchedulerTaskId,
            using: DispatchQueue.main
        ) { [self] task in
            LoggerProxy.event("BGTask BGTaskScheduler.shared.register SCHEDULER called")
            guard let task = task as? BGProcessingTask else {
                return
            }

            scheduleSchedulerBackgroundTask()
            scheduleBackgroundTask()
            
            task.setTaskCompleted(success: true)
        }
        
        LoggerProxy.event("BGTask SCHEDULER registered \(bcgSchedulerTaskResult)")
    }
    
    private func startBackgroundTask(_ task: BGProcessingTask) {
        LoggerProxy.event("BGTask startBackgroundTask called")
        
        // schedule tasks for the next time
        scheduleBackgroundTask()
        scheduleSchedulerBackgroundTask()

        guard isConnectedToWifi.load(ordering: .relaxed) else {
            LoggerProxy.event("BGTask startBackgroundTask: not connected to the wifi")
            task.setTaskCompleted(success: false)
            return
        }
        
        // start the syncing
        rootStore.send(.initialization(.appDelegate(.backgroundTask(task))))
        
        task.expirationHandler = { [rootStore] in
            LoggerProxy.event("BGTask startBackgroundTask expirationHandler called")
            // stop the syncing because the allocated time is about to expire
            DispatchQueue.main.async {
                rootStore.send(.initialization(.appDelegate(.didEnterBackground)))
            }
        }
    }
    
    func scheduleBackgroundTask() {
        // This method can be called as many times as needed, the previously submitted
        // request will be overridden by the new one.
        LoggerProxy.event("BGTask scheduleBackgroundTask called")
        
        let request = BGProcessingTaskRequest(identifier: bcgTaskId)
        
        let today = Calendar.current.startOfDay(for: .now)
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            LoggerProxy.event("BGTask scheduleBackgroundTask failed to schedule time")
            return
        }
        
        let earlyMorningComponent = DateComponents(hour: 3, minute: Int.random(in: 0...60))
        let earlyMorning = Calendar.current.date(byAdding: earlyMorningComponent, to: tomorrow)
        request.earliestBeginDate = earlyMorning
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        
        do {
            try BGTaskScheduler.shared.submit(request)
            LoggerProxy.event("BGTask scheduleBackgroundTask succeeded to submit")
        } catch {
            LoggerProxy.event("BGTask scheduleBackgroundTask failed to submit, error: \(error)")
        }
    }
    
    func scheduleSchedulerBackgroundTask() {
        // This method can be called as many times as needed, the previously submitted
        // request will be overridden by the new one.
        LoggerProxy.event("BGTask scheduleSchedulerBackgroundTask called")
        
        let request = BGProcessingTaskRequest(identifier: bcgSchedulerTaskId)
        
        let today = Calendar.current.startOfDay(for: .now)
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            LoggerProxy.event("BGTask scheduleSchedulerBackgroundTask failed to schedule time")
            return
        }
        
        let afternoonComponent = DateComponents(hour: 14, minute: Int.random(in: 0...60))
        let afternoon = Calendar.current.date(byAdding: afternoonComponent, to: tomorrow)
        request.earliestBeginDate = afternoon
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
            LoggerProxy.event("BGTask scheduleSchedulerBackgroundTask succeeded to submit")
        } catch {
            LoggerProxy.event("BGTask scheduleSchedulerBackgroundTask failed to submit, error: \(error)")
        }
    }
}
