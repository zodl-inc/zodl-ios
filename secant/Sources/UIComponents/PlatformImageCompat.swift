//
//  PlatformImageCompat.swift
//  Zashi
//
//  Cross-platform image conveniences:
//  - `PlatformImage(cgImage:)` works on macOS (NSImage needs an explicit size).
//  - `Image(platformImage:)` maps to `Image(platformImage:)` / `Image(nsImage:)`.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)
extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
#endif

extension Image {
    init(platformImage: PlatformImage) {
#if canImport(UIKit)
        self.init(uiImage: platformImage)
#elseif canImport(AppKit)
        self.init(nsImage: platformImage)
#endif
    }
}
