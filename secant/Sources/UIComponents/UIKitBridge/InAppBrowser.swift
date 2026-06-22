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

/// macOS: there is no in-app Safari, so open the URL in the default browser and dismiss the
/// (empty) presentation immediately. Works for every caller that presents this in a sheet —
/// `dismiss()` flips the `isPresented` binding back.
struct InAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let url: URL

    init(url: URL) { self.url = url }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                openURL(url)
                dismiss()
            }
    }
}
#endif
