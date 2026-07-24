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

    // Owned strongly so it outlives this method scope — `UNUserNotificationCenter.current()`
    // only holds its delegate weakly.
    private let notificationDelegate = MigrationNotificationCenterDelegate()

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

        // Synchronous, before anything else touches notifications — required to catch cold-start
        // taps (the app can be launched directly by a notification tap).
        notificationDelegate.rootStore = rootStore
        UNUserNotificationCenter.current().delegate = notificationDelegate

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

        let bcgMigrationTaskResult = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: MigrationBGTask.identifier,
            using: DispatchQueue.main
        ) { [self] task in
            LoggerProxy.event("BGTask BGTaskScheduler.shared.register MIGRATION called")
            guard let task = task as? BGProcessingTask else {
                return
            }

            startMigrationBackgroundTask(task)
        }

        LoggerProxy.event("BGTask MIGRATION registered \(bcgMigrationTaskResult)")
    }

    /// Unlike `startBackgroundTask` (the `power_wifi_sync` handler above), there is deliberately
    /// NO WiFi gate here: migration's `BGProcessingTaskRequest.requiresNetworkConnectivity` already
    /// covers the network requirement, and migration must not additionally demand WiFi/power.
    private func startMigrationBackgroundTask(_ task: BGProcessingTask) {
        LoggerProxy.event("BGTask startMigrationBackgroundTask called")

        rootStore.send(.initialization(.appDelegate(.migrationBackgroundTask(task))))

        task.expirationHandler = { [rootStore] in
            LoggerProxy.event("BGTask startMigrationBackgroundTask expirationHandler called")
            DispatchQueue.main.async {
                rootStore.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            }
        }
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

// MARK: - UNUserNotificationCenterDelegate (MOB-1467)

/// Routes migration notification taps into the app (`.migrationNotificationTapped`) and controls
/// foreground presentation of migration notifications (the SmartBanner already covers live state,
/// so migration notifications present nothing while the app is in the foreground). `rootStore` is
/// injected by `AppDelegate` rather than held here at construction time, since this delegate is
/// set on `UNUserNotificationCenter.current()` synchronously in `didFinishLaunching`, before
/// `AppDelegate`'s own `rootStore` would otherwise be considered "ready" — it's a stored property
/// on `AppDelegate` either way, so both are initialized together in practice.
final class MigrationNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    var rootStore: StoreOf<Root>?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier.hasPrefix(MigrationNotification.identifierPrefix) {
            let rootStore = self.rootStore
            // R8-T5 (S4): the account this notification was composed for (see
            // `UserNotificationsLiveKey.scheduleMigrationNotification`'s `userInfo` write) — `nil`
            // for a legacy/no-account payload, in which case routing falls back to today's
            // behavior (resolves whatever's currently selected).
            let accountUUID = response.notification.request.content.userInfo["accountUUID"] as? String
            // MOB-1511 (W3): the Tor-failure notification routes to the failure sheet, not the flow.
            // MOB-1513 (gap 1): `hasPrefix`, not `==` — the delivered identifier now carries the
            // per-account suffix (`MigrationNotification.requestIdentifier(accountUUID:)`), so an
            // exact match against the bare case identifier would never hit. Still an exact CASE
            // match: no other case's bare identifier is itself a prefix of another's
            // (`MigrationNotificationTests.identifierTable` pins every case's bare form), so
            // `hasPrefix` against `"migration.torFailure"` can only match a `.migrationTorFailure`
            // request, suffixed or not.
            let isTorFailure = response.notification.request.identifier.hasPrefix(MigrationNotification.migrationTorFailure.identifier)
            DispatchQueue.main.async {
                rootStore?.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: accountUUID, isTorFailure: isTorFailure))))
            }
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix(MigrationNotification.identifierPrefix) {
            // The SmartBanner already covers live migration state while the app is foregrounded.
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }
}
