//
//  MacAmountTextField.swift
//
//
//  Created by Lukáš Korba on 02.07.2026.
//

#if os(macOS)
import AppKit
import SwiftUI

/// macOS replacement for the large-font SwiftUI `TextField` in amount inputs (B4-8).
///
/// SwiftUI's macOS `TextField` is backed by an `NSTextField` whose cell runs in
/// `usesSingleLineMode`. That mode lays the EDITING text out on a fixed baseline derived
/// from default-system-font metrics, not the field's font — with the process-registered
/// Inter at 24pt, typed text lands in a ~16pt line box (13pt-system metrics): glyphs
/// top-clip and ride high while editing, then snap to the correct position on blur (the
/// static cell draw uses correct metrics). Verified in an isolated rig: paragraph-style
/// line-height pins are ignored in that mode, and flipping `usesSingleLineMode` OFF is the
/// one switch that fixes layout. SwiftUI exposes no way to reach it, hence this
/// representable. The quirk is sub-pixel at ~14pt (broken box ≈ correct box), so
/// `ZashiTextField` and other small fields stay on the SwiftUI `TextField`.
struct MacAmountTextField: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 24
    var autoFocusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont(name: FontFamily.Inter.semiBold.name, size: fontSize)
        field.alignment = .right
        field.lineBreakMode = .byClipping
        // The load-bearing line: single-line mode is the broken layout path (see header).
        // Classic single-line behavior is preserved via wraps=false + isScrollable=true.
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        if autoFocusOnAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEnabled = context.environment.isEnabled
        field.textColor = NSColor(Design.Text.primary.color(colorScheme))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont(name: FontFamily.Inter.semiBold.name, size: fontSize) as Any,
                .foregroundColor: NSColor(Design.Text.tertiary.color(colorScheme)),
                .paragraphStyle: paragraph
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacAmountTextField

        init(_ parent: MacAmountTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // B4-9 parity: no Writing Tools bubble on a numeric field.
            guard let field = notification.object as? NSTextField else { return }
            if #available(macOS 15.0, *) {
                (field.currentEditor() as? NSTextView)?.writingToolsBehavior = .none
            }
        }
    }
}
#endif
