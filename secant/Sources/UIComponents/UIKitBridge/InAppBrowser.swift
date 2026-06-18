//
//  InAppBrowser.swift
//
//
//  Created by Lukáš Korba on 06-28-2024.
//

#if os(iOS)
import Foundation
import SwiftUI
import SafariServices

struct InAppBrowserView: UIViewControllerRepresentable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func makeUIViewController(context: UIViewControllerRepresentableContext<InAppBrowserView>) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: UIViewControllerRepresentableContext<InAppBrowserView>) {
    }
}
#else
import Foundation
import SwiftUI

/// macOS stub: `SFSafariViewController` is iOS-only. Renders nothing here; opening URLs
/// externally (NSWorkspace) is a follow-up.
struct InAppBrowserView: View {
    let url: URL
    init(url: URL) { self.url = url }
    var body: some View { EmptyView() }
}
#endif
