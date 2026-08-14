#if os(iOS)
//
//  AppDelegate.swift
//  secant
//
//  Created by Lukáš Korba on 30.12.2023.
//

import SwiftUI
import ComposableArchitecture
import os
@preconcurrency import ZcashLightClientKit
import Network
import Atomics

import BackgroundTasks
import UserNotifications

// [#1755] slipstream: boot evidence logger
private let slipstreamBootLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.ecc.zashi", category: "slipstream")

// swiftlint:disable indentation_width
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let bcgTaskId = "co.electriccoin.power_wifi_sync"
    private let bcgSchedulerTaskId = "co.electriccoin.scheduler"
    private var monitor: NWPathMonitor?
    private let workerQueue = DispatchQueue(label: "Monitor")
    private let isConnectedToWifi = ManagedAtomic(false)

    private let migrationNotificationDelegate = MigrationNotificationCenterDelegate()

    let rootStore = StoreOf<Root>(
        initialState: .initial
    ) {
        Root()
//            .logging()
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

        // PHASE 4: migration notifications are the app's only local notifications, and their taps
        // must reach Root. Set synchronously here — a tap that COLD-STARTS the app is delivered as
        // soon as the delegate exists, so a later assignment would drop it.
        migrationNotificationDelegate.rootStore = rootStore
        UNUserNotificationCenter.current().delegate = migrationNotificationDelegate

        // set the default behavior for the NSDecimalNumber
        NSDecimalNumber.defaultBehavior = Zatoshi.decimalHandler

        // [#1755] slipstream: log engine selection at boot (before wallet init, always fires)
        let useSlipstreamAtBoot = UserDefaultsWalletConfigStorage.cachedFlag(.useSlipstreamSynchronizer)
        if useSlipstreamAtBoot {
            slipstreamBootLogger.info("[#1755] ENGINE=SlipstreamSynchronizer (flag=true)")
        } else {
            slipstreamBootLogger.info("[#1755] ENGINE=SDKSynchronizer (flag=false)")
        }

        rootStore.send(.initialization(.appDelegate(.didFinishLaunching)))

        // MOB-1466: pre-pay the Migration Progress screen's one-time render-metadata cost
        // off-screen (see `MigrationStatusPrewarm`) — shortly after launch, past the first frames,
        // so the burn lands while the user is still looking at the freshly launched app instead of
        // inside their first push animation.
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.75) {
            MigrationStatusPrewarm.run()
        }

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

// MARK: - UNUserNotificationCenterDelegate (PHASE 4)

/// Routes migration notification taps into the app and controls foreground presentation.
/// `rootStore` is injected by `AppDelegate` rather than held at construction: this delegate is set
/// on `UNUserNotificationCenter.current()` synchronously in `didFinishLaunching`, before the store
/// would otherwise be considered ready.
final class MigrationNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    var rootStore: StoreOf<Root>?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier.hasPrefix(MigrationNotification.identifierPrefix) {
            let rootStore = self.rootStore
            // The account this notification was composed FOR, so a tap opens that account's run
            // rather than whichever is selected now. `nil` = legacy payload, falls back to selected.
            let accountUUID = response.notification.request.content.userInfo["accountUUID"] as? String
            // `hasPrefix`, not `==`: the delivered identifier carries the per-account suffix
            // (`requestIdentifier(accountUUID:)`), so an exact match against the bare case id would
            // never hit. Still an exact CASE match — no case's bare id is a prefix of another's.
            let isTorFailure = response.notification.request.identifier
                .hasPrefix(MigrationNotification.migrationTorFailure.identifier)
            DispatchQueue.main.async {
                rootStore?.send(
                    .initialization(.appDelegate(.migrationNotificationTapped(accountUUID: accountUUID, isTorFailure: isTorFailure)))
                )
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
            // D9 foreground policy: the SmartBanner already carries live migration state on screen,
            // so a migration notification presents NOTHING while the app is foregrounded.
            //
            // F-C9-4 companion (campaign 9, 2026-08-05): presenting nothing must not mean DOING
            // nothing. This delivery instant is the send/prove window the arming lane itself
            // computed, and with no banner there is no tap to answer it — so the landing drives
            // the tick belt once. Same store-injection caveat as `didReceive` above.
            let rootStore = self.rootStore
            let accountUUID = notification.request.content.userInfo["accountUUID"] as? String
            DispatchQueue.main.async {
                rootStore?.send(
                    .initialization(.appDelegate(.migrationPokeLandedInForeground(accountUUID: accountUUID)))
                )
            }
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }
}
#endif
