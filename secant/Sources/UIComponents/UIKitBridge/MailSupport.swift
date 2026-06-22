//
//  MailSupport.swift
//  secant
//
//  Cross-platform mail-availability check. MessageUI's MFMailComposeViewController
//  is iOS-only; on macOS there's no in-app composer here, so this reports false.
//  (The actual composer presentation lives in UIMailDialog, which is iOS-gated.)
//

#if canImport(MessageUI)
@preconcurrency import MessageUI
#endif

enum MailSupport {
    /// Whether the platform can present an in-app mail composer.
    static func canSendMail() -> Bool {
#if canImport(MessageUI)
        return MainActor.assumeIsolated { MFMailComposeViewController.canSendMail() }
#else
        // macOS: there's no in-app composer, but `UIMailDialogView` opens the default mail client
        // via a `mailto:` URL, so report `true` to route support/feedback to mail (not share).
        return true
#endif
    }
}
