#if canImport(UIKit)
//
//  UIShareDialog.swift
//  Zashi
//
//  Created by Lukáš Korba on 30.01.2023.
//

import Foundation
import UIKit
import SwiftUI
import LinkPresentation

final class ShareableImage: NSObject, UIActivityItemSource {
    private let image: UIImage
    let title: String
    let reason: String

    init(image: UIImage, title: String, reason: String) {
        self.image = image
        self.title = title
        self.reason = reason
        
        super.init()
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.iconProvider = NSItemProvider(object: UIImage(named: "ZashiLogo") ?? image)
        metadata.title = title
        metadata.originalURL = URL(fileURLWithPath: reason)
        
        return metadata
    }
}

final class ShareableMessage: NSObject, UIActivityItemSource {
    let title: String
    let message: String
    let desc: String

    init(title: String, message: String, desc: String) {
        self.title = title
        self.message = message
        self.desc = desc
        
        super.init()
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        message
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        message
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        if let image = UIImage(named: "ZashiLogo") {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        metadata.title = title
        metadata.originalURL = URL(fileURLWithPath: desc)
        
        return metadata
    }
}

final class ShareableURL: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let desc: String

    init(url: URL, title: String, desc: String) {
        self.url = url
        self.title = title
        self.desc = desc
        
        super.init()
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        if let image = UIImage(named: "ZashiLogo") {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        metadata.title = title
        metadata.originalURL = URL(fileURLWithPath: desc)
        
        return metadata
    }
}

class UIShareDialog: UIView {
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
}

extension UIShareDialog {
    func doInitialSetup(activityItems: [Any], completion: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)

            if let onDismiss {
                activityVC.completionWithItemsHandler = { _, _, _, _ in
                    onDismiss()
                }
            }

            UIApplication.shared.connectedScenes.map({ $0 as? UIWindowScene })
            .compactMap({ $0 })
            .first?.windows.first?.rootViewController?.present(
                activityVC,
                animated: true,
                completion: completion
            )
        }
    }
}

struct UIShareDialogView: UIViewRepresentable {
    let activityItems: [Any]
    /// Called when the share sheet finished presenting. Use it to reset the binding
    /// that triggered the presentation.
    let completion: () -> Void
    /// Called when the share sheet is closed, both on completed share and on cancel.
    /// Use it to clean up shared artifacts (e.g. temporary files).
    let onDismiss: (() -> Void)?

    init(activityItems: [Any], completion: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.activityItems = activityItems
        self.completion = completion
        self.onDismiss = onDismiss
    }

    func makeUIView(context: UIViewRepresentableContext<UIShareDialogView>) -> UIShareDialog {
        let view = UIShareDialog()
        view.doInitialSetup(activityItems: activityItems, completion: completion, onDismiss: onDismiss)
        return view
    }
    
    func updateUIView(_ uiView: UIShareDialog, context: UIViewRepresentableContext<UIShareDialogView>) {
        // We can leave it empty here because the view is just handler how to bridge UIKit's UIActivityViewController
        // presentation into SwiftUI. The view itself is not visible, only instantiated, therefore no updates needed.
    }
    
    typealias UIViewType = UIShareDialog
}

#else
import SwiftUI

// macOS: data-holder stubs for the share payloads (native NSSharingServicePicker deferred to goal #3).
struct ShareableImage {
    let image: PlatformImage
    let title: String
    let reason: String
    init(image: PlatformImage, title: String, reason: String) {
        self.image = image
        self.title = title
        self.reason = reason
    }
}

struct ShareableMessage {
    let title: String
    let message: String
    let desc: String
    init(title: String, message: String, desc: String) {
        self.title = title
        self.message = message
        self.desc = desc
    }
}

struct ShareableURL {
    let url: URL
    let title: String
    let desc: String
    init(url: URL, title: String, desc: String) {
        self.url = url
        self.title = title
        self.desc = desc
    }
}

/// macOS stub: the iOS `UIActivityViewController` share sheet isn't bridged here yet
/// (NSSharingServicePicker is the macOS follow-up). Renders nothing.
struct UIShareDialogView: View {
    let activityItems: [Any]
    let completion: () -> Void
    let onDismiss: (() -> Void)?
    init(activityItems: [Any], completion: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.activityItems = activityItems
        self.completion = completion
        self.onDismiss = onDismiss
    }
    var body: some View { EmptyView() }
}
#endif
