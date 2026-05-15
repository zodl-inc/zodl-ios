//
//  ZashiImagePicker.swift
//
//
//  Created by Lukáš Korba on 2024-04-18.
//

import SwiftUI

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
