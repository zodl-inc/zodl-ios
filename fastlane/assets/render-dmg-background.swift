import AppKit

// Renders the ZODL DMG window background: a neutral light canvas with a
// rounded chevron pointing from the app icon (center 150,190 from top) to the
// /Applications drop link (center 450,190). Canvas is the create-dmg window
// content size, 600x400 points; rendered at 1x and 2x for a HiDPI TIFF.
func render(scale: CGFloat, to url: URL) {
    let size = NSSize(width: 600, height: 400)
    let pixelsWide = Int(size.width * scale)
    let pixelsHigh = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not create bitmap rep") }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(calibratedWhite: 0.949, alpha: 1.0).setFill()
    NSRect(origin: .zero, size: size).fill()

    // Chevron: CG origin is bottom-left, icon row center is 190pt from the top.
    let path = NSBezierPath()
    path.lineWidth = 13
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: 278, y: 250))
    path.line(to: NSPoint(x: 322, y: 210))
    path.line(to: NSPoint(x: 278, y: 170))
    NSColor(calibratedWhite: 0.42, alpha: 1.0).setStroke()
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
    try! data.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
render(scale: 1, to: dir.appendingPathComponent("dmg-background.png"))
render(scale: 2, to: dir.appendingPathComponent("dmg-background@2x.png"))
print("rendered 1x + 2x")
