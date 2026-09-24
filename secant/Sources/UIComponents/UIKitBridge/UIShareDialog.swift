//
//  UIShareDialog.swift
//  Zashi
//
//  Created by Lukáš Korba on 30.01.2023.
//

import Foundation
import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareablePNG: NSObject, UIActivityItemSource {
    private let data: Data
    let title: String

    init(data: Data, title: String) {
        self.data = data
        self.title = title

        super.init()
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        data as NSData
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        data as NSData
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.png.identifier
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        return metadata
    }
}

struct ViewingKeyShareItems {
    let activityItems: [Any]

    init(payload: ViewingKeySharePayload, title: String) {
        activityItems = [
            payload.key.rawValue,
            ShareablePNG(data: payload.png.data, title: title)
        ]
    }
}

struct ViewingKeyNativeShare: Identifiable {
    let payload: ViewingKeySharePayload
    let ownership: ViewingKeyShareOwnership

    var id: UUID { payload.id }
}

struct ViewingKeyActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let ownership: ViewingKeyShareOwnership
    let onPresented: () -> Void
    let onCompletion: () -> Void

    init(
        activityItems: [Any],
        ownership: ViewingKeyShareOwnership,
        onPresented: @escaping () -> Void,
        onCompletion: @escaping () -> Void
    ) {
        self.activityItems = activityItems
        self.ownership = ownership
        self.onPresented = onPresented
        self.onCompletion = onCompletion
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        Self.makeController(
            activityItems: activityItems,
            ownership: ownership,
            onPresented: onPresented,
            onCompletion: onCompletion
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func makeController(
        activityItems: [Any],
        ownership: ViewingKeyShareOwnership,
        onCompletion: @escaping () -> Void
    ) -> ViewingKeyActivityViewController {
        makeController(
            activityItems: activityItems,
            ownership: ownership,
            onPresented: {},
            onCompletion: onCompletion
        )
    }

    static func makeController(
        activityItems: [Any],
        ownership: ViewingKeyShareOwnership,
        onPresented: @escaping () -> Void,
        onCompletion: @escaping () -> Void
    ) -> ViewingKeyActivityViewController {
        let controller = ViewingKeyActivityViewController(
            activityItems: activityItems,
            ownership: ownership,
            onPresented: onPresented
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            ownership.finish()
            onCompletion()
        }
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: controller.view.bounds.midX,
            y: controller.view.bounds.midY,
            width: 0,
            height: 0
        )
        return controller
    }
}

final class ViewingKeyActivityViewController: UIActivityViewController {
    let didTransferPayload: Bool
    private let onPresented: () -> Void
    private var didNotifyPresentation = false

    init(
        activityItems: [Any],
        ownership: ViewingKeyShareOwnership,
        onPresented: @escaping () -> Void
    ) {
        let didTransferPayload = ownership.claimNativeOwnership()
        self.didTransferPayload = didTransferPayload
        self.onPresented = onPresented
        super.init(
            activityItems: didTransferPayload ? activityItems : [],
            applicationActivities: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard didTransferPayload, !didNotifyPresentation else { return }
        didNotifyPresentation = true
        onPresented()
    }
}

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
