//
//  ZashiImagePicker.swift
//
//
//  Created by Lukáš Korba on 2024-04-18.
//

import SwiftUI

#if canImport(UIKit)
struct ZashiImagePicker: UIViewControllerRepresentable {
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: ZashiImagePicker

        init(_ parent: ZashiImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[UIImagePickerController.InfoKey.originalImage] as? UIImage {
                parent.selectedImage = image
            }

            parent.showSheet = false
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.showSheet = false
        }
    }

    @Binding var selectedImage: UIImage?
    @Binding var showSheet: Bool

    func makeUIViewController(
        context: UIViewControllerRepresentableContext<ZashiImagePicker>
    ) -> UIImagePickerController {
        let imagePicker = UIImagePickerController()

        imagePicker.allowsEditing = false
        imagePicker.sourceType = .photoLibrary
        imagePicker.delegate = context.coordinator

        return imagePicker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: UIViewControllerRepresentableContext<ZashiImagePicker>
    ) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
#else
import AppKit
import UniformTypeIdentifiers

/// macOS: pick an image file via `NSOpenPanel`; the chosen `NSImage` flows through the same
/// `selectedImage` binding the iOS picker drives, into the QR image detector.
struct ZashiImagePicker: View {
    @Binding var selectedImage: PlatformImage?
    @Binding var showSheet: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                // Defer past the SwiftUI view update: NSOpenPanel.runModal() spins a nested modal run
                // loop, which silently no-ops (the panel never appears) when called synchronously inside
                // onAppear during a render pass — the reported "library button does nothing". Hopping to
                // the next runloop turn lets the file dialog open normally.
                DispatchQueue.main.async {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
                        selectedImage = image
                    }
                    showSheet = false
                }
            }
    }
}
#endif
