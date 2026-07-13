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
import WebKit

/// macOS: a real in-app browser (WKWebView) — keeps the user inside the app (the iOS
/// `SFSafariViewController` security model) rather than handing off to the system browser. A small
/// chrome bar offers Done + "open in default browser".
struct InAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let url: URL

    init(url: URL) { self.url = url }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Done") { dismiss() }
                Spacer()
                Text(url.host ?? url.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { openURL(url) } label: { Image(systemName: "safari") }
                    .help("Open in default browser")
            }
            .padding(10)
            Divider()
            InAppWebView(url: url)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 640, idealHeight: 760)
    }
}

private struct InAppWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
#endif
