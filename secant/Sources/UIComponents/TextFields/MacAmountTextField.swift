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
/// Amount-field focus ergonomics (round 4.1, field feedback):
/// - the placeholder dismisses while the field is focused (like the iOS focus-conditional
///   prompt) and returns on blur;
/// - acquiring focus puts the caret at the END of the value. The text is right-aligned in a
///   full-width field, so a click usually lands in the empty area LEFT of the glyphs and AppKit
///   snaps the caret to the nearest position — the string START ("|122", typing prepends).
///   Amount entry appends. Subsequent clicks while already focused reposition normally, so
///   mid-value edits stay possible.
private final class MacAmountNSTextField: NSTextField {
    /// The placeholder to show while idle; `placeholderAttributedString` itself is nil'd
    /// during editing.
    private var idlePlaceholder: NSAttributedString?
    /// Focus once, when the field lands in a window (see `viewDidMoveToWindow`).
    var autoFocusOnAppear = false
    private var didAutoFocus = false
    /// The LIVE focus truth (B4-8 round 5.2). Round 5.1's session flag desynced because the
    /// responder callbacks LIE about the net state: in the SwiftUI-hosted window the field's
    /// `becomeFirstResponder` is followed by a transient `textDidEndEditing` (the hosting
    /// view's focus arbitration bounces the responder), after which focus lands back on the
    /// FIELD EDITOR without the field's `becomeFirstResponder` ever re-firing — device log:
    /// become(true) → end(false), final flag FALSE while visibly focused. So: never track,
    /// always ASK. Focused = the window's first responder is the field itself, or a field
    /// editor whose delegate is this field (the normal state while editing).
    private var isEffectivelyFocused: Bool {
        guard let window else { return false }
        if window.firstResponder === self { return true }
        if let editor = window.firstResponder as? NSTextView, editor.delegate === self {
            return true
        }
        return false
    }

    /// Re-derive placeholder visibility from the live responder truth. Called one runloop
    /// turn AFTER each responder event (become/end), so transient bounces have settled and
    /// the answer reflects where focus actually ended up — event ORDER can no longer
    /// strand a stale placeholder (or a stale dismissal).
    private func refreshPlaceholderVisibility() {
        placeholderAttributedString = isEffectivelyFocused ? nil : idlePlaceholder
        needsDisplay = true
    }

    /// The ONE write path for the placeholder from `updateNSView`: remembers the idle
    /// string and applies it per the live focus truth. Localization is the caller's
    /// (`store.localePlaceholder` — "0.00" vs "0,00").
    func setIdlePlaceholder(_ placeholder: NSAttributedString) {
        idlePlaceholder = placeholder
        refreshPlaceholderVisibility()
    }

    /// Round 4.1's `asyncAfter(0.1)` autofocus silently no-op'd whenever the field wasn't
    /// in a window yet — leaving the field unfocused AND the round-4.1 placeholder/caret
    /// fixes never running. The window arriving is the reliable signal.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard autoFocusOnAppear, !didAutoFocus, window != nil else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            // Optimistic hide now (with the repaint a borderless field doesn't get for
            // free), TRUTH one turn later — by then the hosting view's focus bounce has
            // settled, whichever way it went.
            placeholderAttributedString = nil
            needsDisplay = true
            configureFieldEditor()
            // After the current event finishes: the click that focused the field places the
            // caret at the click point AFTER this method runs, so the end-caret (and the
            // editor attributes, if the editor was installed late) must be applied on the
            // next runloop turn to win.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configureFieldEditor()
                if let editor = self.currentEditor() {
                    editor.selectedRange = NSRange(location: (self.stringValue as NSString).length, length: 0)
                }
                self.refreshPlaceholderVisibility()
            }
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Deliberately NOT a synchronous placeholder restore: this callback also fires as
        // a TRANSIENT during the hosting view's focus bounce (become → end → focus lands
        // back on the field editor with no new become). One turn later the responder truth
        // is settled: genuinely blurred ⇒ placeholder returns; still focused ⇒ it stays
        // hidden.
        DispatchQueue.main.async { [weak self] in
            self?.refreshPlaceholderVisibility()
        }
    }

    /// The load-bearing caret/baseline fix (B4-8 round 5). An EMPTY field editor
    /// (`NSTextView`) draws its insertion point from `typingAttributes` — NOT from the
    /// field's `alignment`, which only reaches the editor's text storage once there is
    /// text. Left unconfigured, an empty right-aligned field blinks its caret at the LEFT
    /// edge with 13pt-system metrics (short caret, high baseline), then jumps to the right
    /// with the real font on the first typed character. Setting the paragraph style + the
    /// real font in `typingAttributes` puts the caret at the RIGHT edge, at the real
    /// font's height and baseline, from the first frame.
    private func configureFieldEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        editor.defaultParagraphStyle = paragraph
        editor.alignment = .right
        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if let font { attrs[.font] = font }
        if let textColor { attrs[.foregroundColor] = textColor }
        editor.typingAttributes = attrs
    }
}

struct MacAmountTextField: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 24
    var autoFocusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = MacAmountNSTextField()
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
        field.autoFocusOnAppear = autoFocusOnAppear
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
        let idlePlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont(name: FontFamily.Inter.semiBold.name, size: fontSize) as Any,
                .foregroundColor: NSColor(Design.Text.tertiary.color(colorScheme)),
                .paragraphStyle: paragraph
            ]
        )
        // Route through the gated setter — NEVER poke `placeholderAttributedString` here.
        // The old `currentEditor() == nil` guard raced focus acquisition (the editor can
        // install a beat after becomeFirstResponder) and resurrected the placeholder for
        // the whole focused-empty session (B4-8 round 5.1).
        (field as? MacAmountNSTextField)?.setIdlePlaceholder(idlePlaceholder)
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
