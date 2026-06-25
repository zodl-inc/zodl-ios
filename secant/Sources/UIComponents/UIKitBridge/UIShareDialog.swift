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
import AppKit
import UniformTypeIdentifiers

// macOS: data-holder payloads for the share content (unwrapped into native share items below).
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

/// macOS: content-aware native share. A single exported file → `NSSavePanel` (the macOS "export"
/// verb — no popover, no stray arrow). Everything else (QR image, address/URI, feedback text) →
/// `NSSharingServicePicker` (AirDrop / Mail / Messages / Copy …), anchored to the key window's
/// bottom center. Unwraps the `Shareable*` payloads into
/// native items (NSImage / String / URL) and survives the binding reset (`completion`).
struct UIShareDialogView: NSViewRepresentable {
    let activityItems: [Any]
    let completion: () -> Void
    let onDismiss: (() -> Void)?

    init(activityItems: [Any], completion: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.activityItems = activityItems
        self.completion = completion
        self.onDismiss = onDismiss
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let items = Self.shareItems(from: activityItems)

        // Content-aware presentation. A single exported FILE (tax CSV, zipped logs, private data) is an
        // "export" on macOS, so it gets a native Save panel — no popover, no stray arrow. Everything else
        // (QR image, address/URI, feedback text) is a genuine "share", so it gets the system share menu,
        // anchored to the window's bottom center — the menu rises from the bottom with its arrow pointing
        // down at the midpoint, instead of the old dead-center anchor whose arrow pointed at nothing. (The
        // SwiftUI-hosted content view is flipped, so `maxY` is the bottom edge.)
        let fileURLs = items.compactMap { $0 as? URL }.filter(\.isFileURL)
        if items.count == 1, fileURLs.count == 1, let fileURL = fileURLs.first {
            Self.presentSavePanel(for: fileURL, onDismiss: onDismiss)
        } else if !items.isEmpty, let anchor = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = context.coordinator
            let rect = NSRect(x: anchor.bounds.midX + Design.Mac.sidebarWidth * 0.5, y: anchor.bounds.maxY - 24, width: 1, height: 1)
            picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        } else {
            onDismiss?()
        }
        completion()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        let onDismiss: (() -> Void)?
        init(onDismiss: (() -> Void)?) { self.onDismiss = onDismiss }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            onDismiss?()
        }
    }

    /// Presents a native Save panel for a single exported file (sheet-attached to the key window when
    /// possible) and copies the temporary export to the chosen destination. `onDismiss` fires on both
    /// Save and Cancel so the caller can clean up the temporary file, mirroring the share-picker's
    /// `didChoose` behavior.
    private static func presentSavePanel(for fileURL: URL, onDismiss: (() -> Void)?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }
        if !fileURL.pathExtension.isEmpty, let contentType = UTType(filenameExtension: fileURL.pathExtension) {
            panel.allowedContentTypes = [contentType]
        }

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let destination = panel.url {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try? fileManager.copyItem(at: fileURL, to: destination)
            }
            onDismiss?()
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private static func shareItems(from activityItems: [Any]) -> [Any] {
        activityItems.flatMap { item -> [Any] in
            switch item {
            case let payload as ShareableImage: return [payload.image]
            case let payload as ShareableMessage: return [payload.message]
            case let payload as ShareableURL: return [payload.url]
            default: return [item]
            }
        }
    }
}
#endif
