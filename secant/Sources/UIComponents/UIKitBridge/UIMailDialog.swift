#if canImport(UIKit)
//
//  UIMailDialog.swift
//  secant
//
//  Created by Michal Fousek on 28.02.2023.
//

import Foundation
import MessageUI
import UIKit
import SwiftUI

class UIMailDialog: UIView {
    var completion: (() -> Void)?

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
    }
}

extension UIMailDialog {
    func doInitialSetup(supportData: SupportData, completion: @escaping () -> Void) {
        self.completion = completion
        DispatchQueue.main.async {
            let mailVC = MFMailComposeViewController()
            mailVC.mailComposeDelegate = self

            // Configure the fields of the interface.
            mailVC.setToRecipients([supportData.toAddress])
            mailVC.setSubject(supportData.subject)
            mailVC.setMessageBody("\n\n\(supportData.message)", isHTML: false)

            let rootVC = UIApplication.shared.connectedScenes
                .map { $0 as? UIWindowScene }
                .compactMap { $0 }
                .first?.windows.first?.rootViewController

            rootVC?.present(
                mailVC,
                animated: true,
                completion: nil
            )
        }
    }
}

extension UIMailDialog: @preconcurrency MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true, completion: completion)
    }
}

struct UIMailDialogView: UIViewRepresentable {
    let supportData: SupportData
    let completion: () -> Void

    init(supportData: SupportData, completion: @escaping () -> Void) {
        self.supportData = supportData
        self.completion = completion
    }
    
    func makeUIView(context: UIViewRepresentableContext<UIMailDialogView>) -> UIMailDialog {
        let view = UIMailDialog()
        view.doInitialSetup(supportData: supportData, completion: completion)
        return view
    }

    func updateUIView(_ uiView: UIMailDialog, context: UIViewRepresentableContext<UIMailDialogView>) {
        // We can leave it empty here because the view is just handler how to bridge UIKit's UIActivityViewController
        // presentation into SwiftUI. The view itself is not visible, only instantiated, therefore no updates needed.
    }

    typealias UIViewType = UIMailDialog
}

#else
import SwiftUI

/// macOS: no in-app mail composer. Open the default mail client via a `mailto:` URL with the
/// support address/subject/body prefilled, then call `completion` (which clears the binding that
/// presented this zero-frame helper).
struct UIMailDialogView: View {
    @Environment(\.openURL) private var openURL
    let supportData: SupportData
    let completion: () -> Void

    init(supportData: SupportData, completion: @escaping () -> Void) {
        self.supportData = supportData
        self.completion = completion
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                var components = URLComponents()
                components.scheme = "mailto"
                components.path = supportData.toAddress
                components.queryItems = [
                    URLQueryItem(name: "subject", value: supportData.subject),
                    URLQueryItem(name: "body", value: "\n\n\(supportData.message)")
                ]
                if let url = components.url {
                    openURL(url)
                }
                completion()
            }
    }
}
#endif
