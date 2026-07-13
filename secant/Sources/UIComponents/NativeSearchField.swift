//
//  NativeSearchField.swift
//  Zashi
//
//  macOS-only: the genuine AppKit search control (NSSearchField) bridged to SwiftUI. Gives the
//  native magnifier padding, X clear button, and focus ring that a plain SwiftUI TextField can't —
//  while remaining a plain view we can drop into a toolbar item at a position of our choosing
//  (e.g. search-first, filter-second).
//

#if os(macOS)
import SwiftUI
import AppKit

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
#endif
