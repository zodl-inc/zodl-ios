//
//  ZashiBack.swift
//
//
//  Created by Lukáš Korba on 04.10.2023.
//

import SwiftUI
import UIKit

struct ZashiBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    let disabled: Bool
    let hidden: Bool
    let invertedColors: Bool
    let customDismiss: (() -> Void)?
    
    func body(content: Content) -> some View {
        if hidden {
            content
                .navigationBarBackButtonHidden(true)
        } else {
            content
                .navigationBarBackButtonHidden(true)
                .enableSwipeBackGesture()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            if let customDismiss {
                                customDismiss()
                            } else {
                                dismiss()
                            }
                        } label: {
                            if #available(iOS 26.0, *) {
                                backIcon()
                            } else {
                                backIcon()
                                    .padding(.trailing, 24)
                                    .padding(8)
                            }
                        }
                        .disabled(disabled)
                    }
                }
        }
    }
    
    @ViewBuilder private func backIcon() -> some View {
        HStack {
            Asset.Assets.Icons.arrowNarrowLeft.image
                .zImage(size: 24,
                        color: invertedColors ? Asset.Colors.secondary.color : Asset.Colors.primary.color
                )
        }
    }
}

extension View {
    func zashiBack(
        _ disabled: Bool = false,
        hidden: Bool = false,
        invertedColors: Bool = false,
        customDismiss: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ZashiBackModifier(
                disabled: disabled,
                hidden: hidden,
                invertedColors: invertedColors,
                customDismiss: customDismiss
            )
        )
    }

    /// Restores the system edge-swipe-back gesture, which iOS disables when
    /// `.navigationBarBackButtonHidden(true)` is set. Safe to use on the root of
    /// a `NavigationStack` — the gesture only fires when the stack has > 1 view.
    func enableSwipeBackGesture() -> some View {
        background(
            EnableSwipeBackGesture()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

private struct EnableSwipeBackGesture: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { [weak view] in
            view?.attachSwipeBack(coordinator: context.coordinator)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { [weak uiView] in
            uiView?.attachSwipeBack(coordinator: context.coordinator)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

private extension UIView {
    func attachSwipeBack(coordinator: EnableSwipeBackGesture.Coordinator) {
        guard let nav = findNavigationController() else { return }
        coordinator.navigationController = nav
        nav.interactivePopGestureRecognizer?.delegate = coordinator
        nav.interactivePopGestureRecognizer?.isEnabled = true
    }

    func findNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let nav = next as? UINavigationController { return nav }
            responder = next
        }
        return nil
    }
}
