import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: true) { _ in
    let background = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888),
                                  xRadius: 209, yRadius: 209)
    let orange = NSColor(srgbRed: 0.93, green: 0.26, blue: 0.18, alpha: 1)
    let plum = NSColor(srgbRed: 0.46, green: 0.10, blue: 0.25, alpha: 1)
    NSGradient(starting: orange, ending: plum)?.draw(in: background, angle: 52)

    let frame = NSBezierPath(roundedRect: NSRect(x: 238, y: 299, width: 548, height: 426),
                             xRadius: 65, yRadius: 65)
    NSColor.white.withAlphaComponent(0.16).setFill()
    frame.fill()
    NSColor.white.setStroke()
    frame.lineWidth = 30
    frame.stroke()

    let mountains = NSBezierPath()
    mountains.move(to: NSPoint(x: 254, y: 648))
    mountains.line(to: NSPoint(x: 401, y: 494))
    mountains.line(to: NSPoint(x: 522, y: 615))
    mountains.line(to: NSPoint(x: 611, y: 522))
    mountains.line(to: NSPoint(x: 772, y: 684))
    mountains.lineWidth = 29
    mountains.lineJoinStyle = .round
    mountains.stroke()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 587, y: 369, width: 63, height: 63)).fill()

    let badge = NSBezierPath(ovalIn: NSRect(x: 653, y: 614, width: 208, height: 208))
    NSColor(srgbRed: 0.99, green: 0.91, blue: 0.78, alpha: 1).setFill()
    badge.fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 757, y: 669))
    arrow.line(to: NSPoint(x: 757, y: 756))
    arrow.move(to: NSPoint(x: 718, y: 725))
    arrow.line(to: NSPoint(x: 757, y: 764))
    arrow.line(to: NSPoint(x: 796, y: 725))
    arrow.lineWidth = 17
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    plum.setStroke()
    arrow.stroke()
    return true
}

func png(at pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Couldn’t create the app icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Couldn’t encode the app icon")
    }
    return data
}

func iconRecord(_ type: String, _ data: Data) -> Data {
    var length = UInt32(8 + data.count).bigEndian
    return Data(type.utf8) + withUnsafeBytes(of: &length) { Data($0) } + data
}

// ICNS stores each PNG size as a four-character type followed by its record length.
var records = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    records.append(iconRecord(type, png(at: size)))
}
try iconRecord("icns", records).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
