//
//  SwapFormLayoutTests.swift
//  zodlTests
//
//  Switching the swap direction must not move the switch button and must keep the
//  amount keyboard up: one amount `TextField` stays in place and keeps first responder.
//

import ComposableArchitecture
import SwiftUI
import Testing
import UIKit
@testable import zodl_internal

@MainActor
@Suite(.serialized) struct SwapFormLayoutTests {
    @Test func switchingDirectionKeepsSwitchButtonAndAmountFocus() async throws {
        let store = Store(initialState: SwapAndPay.State.initial) {
            BindingReducer<SwapAndPay.State, SwapAndPay.Action, SwapAndPay.Action>()
            Reduce<SwapAndPay.State, SwapAndPay.Action> { state, action in
                switch action {
                case .enableSwapToZecExperience, .enableSwapExperience:
                    return SwapAndPay().reduce(into: &state, action: action)
                default:
                    return .none
                }
            }
        }
        setApplicationAccessibilityEnabled(true)
        defer { setApplicationAccessibilityEnabled(false) }
        let window = try await host(SwapAndPayForm(store: store, tokenName: "ZEC"))
        defer { window.isHidden = true }

        let amountField = try #require(decimalTextFields(in: window).first)
        #expect(decimalTextFields(in: window).count == 1)
        amountField.becomeFirstResponder()
        await settle(window)
        #expect(amountField.isFirstResponder)
        let fromZecButtonFrame = try #require(switchButtonFrame(in: window))

        store.send(.enableSwapToZecExperience)
        await settle(window)
        #expect(store.isSwapToZecExperienceEnabled)
        #expect(decimalTextFields(in: window).count == 1)
        #expect(decimalTextFields(in: window).first === amountField)
        #expect(amountField.isFirstResponder)
        let intoZecButtonFrame = try #require(switchButtonFrame(in: window))
        #expect(abs(intoZecButtonFrame.minY - fromZecButtonFrame.minY) < 1)

        store.send(.enableSwapToZecExperience)
        await settle(window)
        #expect(!store.isSwapToZecExperienceEnabled)
        #expect(decimalTextFields(in: window).first === amountField)
        #expect(amountField.isFirstResponder)
        let backFrame = try #require(switchButtonFrame(in: window))
        #expect(abs(backFrame.minY - fromZecButtonFrame.minY) < 1)
    }

    /// SwiftUI builds its accessibility tree only while app accessibility is on. This is the switch that
    /// accessibility snapshot tools use in unit tests; it lets the test find the switch button by identifier.
    private func setApplicationAccessibilityEnabled(_ enabled: Bool) {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled") else {
            return
        }
        typealias SetEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(enabled)
    }

    private func host(_ view: some View) async throws -> UIWindow {
        let controller = UIHostingController(rootView: view.transaction { $0.animation = nil })
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        await settle(window)
        return window
    }

    private func settle(_ window: UIWindow) async {
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
        }
    }

    private func decimalTextFields(in view: UIView) -> [UITextField] {
        let current = (view as? UITextField).flatMap { $0.keyboardType == .decimalPad ? [$0] : nil } ?? []
        return current + view.subviews.flatMap(decimalTextFields(in:))
    }

    private func switchButtonFrame(in window: UIWindow) -> CGRect? {
        accessibilityFrame(
            of: AccessibilityID.SwapForm.changeModeButton,
            in: window.rootViewController?.view as Any
        )
    }

    private func accessibilityFrame(of identifier: String, in element: Any, depth: Int = 0) -> CGRect? {
        guard depth < 64, let object = element as? NSObject else { return nil }
        if object.responds(to: #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)),
           object.value(forKey: "accessibilityIdentifier") as? String == identifier {
            return object.accessibilityFrame
        }
        var children = object.accessibilityElements ?? []
        if children.isEmpty {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) }
            }
        }
        if let view = object as? UIView {
            children += view.subviews
        }
        for child in children {
            if let frame = accessibilityFrame(of: identifier, in: child, depth: depth + 1) {
                return frame
            }
        }
        return nil
    }
}
