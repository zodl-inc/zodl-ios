import ComposableArchitecture
import SwiftUI
import Testing
import UIKit
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ViewingKeyNavigationPresentationTests {
    private struct Host {
        let store: StoreOf<Settings>
        let window: UIWindow
    }

    @Test(arguments: ViewingKeyKind.allCases)
    func realSettingsStackAnimatesChooserDetailAndReturn(kind: ViewingKeyKind) async throws {
        let host = try await makeHost()
        defer { host.window.isHidden = true }
        #expect(UIView.areAnimationsEnabled)
        #expect(!UIAccessibility.isReduceMotionEnabled)

        let rootDepth = try #require(navigationController(in: host.window)?.viewControllers.count)
        _ = withAnimation {
            host.store.send(.advancedSettingsTapped)
        }
        let advancedNavigation = try await observeTransition(in: host.window, reaching: rootDepth + 1, requireCoordinator: false)
        print("Advanced push duration: \(advancedNavigation.duration)")
        let advancedID = try #require(host.store.path.ids.last)

        host.store.send(.path(.element(
            id: advancedID,
            action: .advancedSettings(.operationAccessCheck(.exportViewingKey))
        )))
        let chooserNavigation = try await observeTransition(in: host.window, reaching: rootDepth + 2, requireCoordinator: false)
        print("Chooser push duration: \(chooserNavigation.duration)")
        let chooserID = try #require(host.store.path.ids.last)
        #expect(host.store.path[id: chooserID]?.exportViewingKeys != nil)

        host.store.send(.path(.element(id: chooserID, action: .exportViewingKeys(.selectKind(kind)))))
        _ = withAnimation {
            host.store.send(.path(.element(id: chooserID, action: .exportViewingKeys(.continueTapped))))
        }
        if kind == .full {
            let sheet = try await waitForSheet(in: host.window)
            #expect(host.store.path.count == 2)
            #expect(host.store.path[id: chooserID]?.exportViewingKeys?.consent.isEmpty == true)
            await probeConsentAccessibility(in: sheet.view, store: host.store, chooserID: chooserID)
            for item in ViewingKeyConsent.allCases {
                host.store.send(.path(.element(id: chooserID, action: .exportViewingKeys(.consentChanged(item, true)))))
            }
            #expect(host.store.path[id: chooserID]?.exportViewingKeys?.canExportFull == true)
            _ = withAnimation {
                host.store.send(.path(.element(id: chooserID, action: .exportViewingKeys(.exportFullTapped))))
            }
            #expect(host.store.path.count == 2)
        }

        let detailNavigation = try await observeTransition(in: host.window, reaching: rootDepth + 3)
        #expect(detailNavigation.duration > 0)
        #expect(!detailNavigation.sheetPresented)
        let detailID = try #require(host.store.path.ids.last)
        let detail = try #require(host.store.path[id: detailID]?.viewingKeyDetail)
        #expect(detail.detail.kind == kind)
        #expect(!detail.detail.isRevealed)
        #expect(detail.detail.tab == .qrCode)
        #expect(host.store.path[id: chooserID]?.exportViewingKeys?.selectedKind == kind)
        let expectedTitle = String(localizable: .viewing_key_export)
        #expect(detailNavigation.title == expectedTitle)

        if kind == .incoming {
            _ = withAnimation {
                host.store.send(.path(.element(id: detailID, action: .viewingKeyDetail(.backTapped))))
            }
        } else {
            _ = withAnimation {
                host.store.send(.path(.popFrom(id: detailID)))
            }
        }
        let returnNavigation = try await observeTransition(in: host.window, reaching: rootDepth + 2)
        #expect(returnNavigation.duration > 0)
        #expect(host.store.path.ids.last == chooserID)
        #expect(host.store.path[id: chooserID]?.exportViewingKeys?.selectedKind == kind)
    }

    private func makeHost() async throws -> Host {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let state = Settings.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        let store = Store(initialState: state) {
            Settings()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.appVersion.appVersion = { "hosted" }
            $0.appVersion.appBuild = { "1" }
            $0.localAuthentication.authenticate = { true }
            $0.walletStorage.exportTorSetupFlag = { false }
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
        }
        let scene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: SettingsView(store: store))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        for _ in 0..<128 {
            await nextMainRunLoopTurn()
            window.layoutIfNeeded()
            if store.appVersion == "hosted" {
                break
            }
        }
        #expect(store.appVersion == "hosted")
        #expect(store.path.isEmpty)
        return Host(store: store, window: window)
    }

    private func observeTransition(
        in window: UIWindow,
        reaching depth: Int,
        requireCoordinator: Bool = true
    ) async throws -> (duration: TimeInterval, title: String?, sheetPresented: Bool) {
        var observedCoordinator: UIViewControllerTransitionCoordinator?
        var observedDepth = 0
        var observedTitle: String?
        var sheetPresentedAtTransition = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await nextMainRunLoopTurn()
            window.layoutIfNeeded()
            guard let nav = navigationController(in: window) else { continue }
            observedDepth = nav.viewControllers.count
            observedTitle = nav.navigationBar.topItem?.title
            if observedDepth == depth,
               let coordinator = ([nav] + nav.viewControllers)
                .compactMap({ $0.transitionCoordinator })
                .first(where: { $0.transitionDuration > 0 }) {
                observedCoordinator = coordinator
            }
            if observedDepth == depth, (!requireCoordinator || observedCoordinator != nil) {
                sheetPresentedAtTransition = window.rootViewController?.presentedViewController != nil
                break
            }
        }
        print("Native navigation: target=\(depth), observed=\(observedDepth), title=\(observedTitle ?? "<nil>"), transition=\(observedCoordinator?.transitionDuration ?? 0)")
        if observedCoordinator != nil {
            for _ in 0..<4096 {
                await nextMainRunLoopTurn()
                window.layoutIfNeeded()
                let isTransitioning = controllers(in: window.rootViewController ?? UIViewController())
                    .contains { $0.transitionCoordinator != nil }
                if !isTransitioning {
                    break
                }
            }
        } else if requireCoordinator {
            Issue.record("No nonzero native transition coordinator for depth \(depth)")
        }
        let nav = try #require(navigationController(in: window))
        #expect(nav.viewControllers.count == depth)
        return (observedCoordinator?.transitionDuration ?? 0, nav.navigationBar.topItem?.title, sheetPresentedAtTransition)
    }

    private func waitForSheet(in window: UIWindow) async throws -> UIViewController {
        for _ in 0..<512 {
            await nextMainRunLoopTurn()
            window.layoutIfNeeded()
            if let presented = window.rootViewController?.presentedViewController {
                return presented
            }
        }
        Issue.record("Native consent sheet was not presented")
        return try #require(window.rootViewController?.presentedViewController)
    }

    private func navigationController(in window: UIWindow) -> UINavigationController? {
        guard let root = window.rootViewController else { return nil }
        return controllers(in: root)
            .compactMap { $0 as? UINavigationController }
            .max { $0.viewControllers.count < $1.viewControllers.count }
    }

    private func controllers(in controller: UIViewController) -> [UIViewController] {
        [controller]
            + controller.children.flatMap(controllers(in:))
            + (controller.presentedViewController.map { controllers(in: $0) } ?? [])
    }

    private func probeConsentAccessibility(
        in view: UIView,
        store: StoreOf<Settings>,
        chooserID: StackElementID
    ) async {
        let elements = accessibilityElements(in: view)
        let accessibleViews = accessibilityViews(in: view)
        print("Real Settings consent AX elements: \(elements.count), labeled views: \(accessibleViews.count)")
        for item in ViewingKeyConsent.allCases {
            let label: String
            switch item {
            case .history: label = String(localizable: .viewing_key_acknowledge_history)
            case .recipient: label = String(localizable: .viewing_key_acknowledge_recipient)
            case .irreversible: label = String(localizable: .viewing_key_acknowledge_irreversible)
            }
            if let target = elements.first(where: { $0.accessibilityLabel == label }) {
                let previousValue = target.accessibilityValue
                let activated = target.accessibilityActivate()
                await nextMainRunLoopTurn()
                print("Consent AX element activation: \(item), activated=\(activated), checked=\(store.path[id: chooserID]?.exportViewingKeys?.consent.contains(item) == true), before=\(previousValue ?? "<nil>"), after=\(target.accessibilityValue ?? "<nil>")")
            } else if let target = accessibleViews.first(where: { $0.accessibilityLabel == label }) {
                let previousValue = target.accessibilityValue
                let activated = target.accessibilityActivate()
                await nextMainRunLoopTurn()
                print("Consent AX view activation: \(item), activated=\(activated), checked=\(store.path[id: chooserID]?.exportViewingKeys?.consent.contains(item) == true), before=\(previousValue ?? "<nil>"), after=\(target.accessibilityValue ?? "<nil>")")
            }
        }
    }

    private func accessibilityViews(in view: UIView) -> [UIView] {
        let own = view.isAccessibilityElement && view.accessibilityLabel != nil ? [view] : []
        return own + view.subviews.flatMap(accessibilityViews(in:))
    }

    private func accessibilityElements(in view: UIView) -> [UIAccessibilityElement] {
        let direct = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        let count = max(0, min(view.accessibilityElementCount(), 100))
        let indexed = (0..<count).compactMap { view.accessibilityElement(at: $0) as? UIAccessibilityElement }
        return direct + indexed + view.subviews.flatMap(accessibilityElements(in:))
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
