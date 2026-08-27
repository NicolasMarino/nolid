//
//  make-icon.swift
//  NoLid — icon generator.
//
//  Draws the app icon from code instead of shipping a binary blob nobody can
//  edit: run it, review the diff, commit the result. It renders every size
//  natively rather than downscaling one big canvas, so the symbol stays crisp
//  at 16pt where it is nothing but a few pixels.
//
//  Usage:  swift Tools/make-icon.swift Resources/NoLid.icns
//

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/NoLid.icns"

/// Same symbol the menu bar shows once the built-in display is off: what you
/// are left with is your external monitors, and nothing else.
let symbolName = "display.2"

/// macOS icons do not fill their canvas. This is the share of the edge the
/// rounded square occupies, matching the system grid closely enough.
let squircleScale: CGFloat = 0.82
/// Apple's continuous-corner ratio for that square.
let cornerRatio: CGFloat = 0.2237

func drawIcon(side: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let inset = side * (1 - squircleScale) / 2
    let square = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = square.width * cornerRatio
    let body = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    // Deep slate to near-black: the icon should read as a screen that went dark.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.24, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 1),
    ])
    gradient?.draw(in: body, angle: -90)

    // A hairline lip so the shape keeps an edge on a dark desktop.
    NSColor(white: 1, alpha: 0.16).setStroke()
    body.lineWidth = max(1, side / 256)
    body.stroke()

    let glyphSide = square.width * 0.58
    // The colour has to come from the symbol configuration. Filling a rect and
    // masking it does not work here: the compositing operation applies to the
    // whole context, not just the glyph, and eats the background with it.
    let config = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .medium)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }

    var glyphRect = NSRect(origin: .zero, size: symbol.size)
    glyphRect.origin.x = square.midX - symbol.size.width / 2
    glyphRect.origin.y = square.midY - symbol.size.height / 2
    symbol.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)

    return rep
}

let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("NoLid-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, pixels) in sizes {
    guard let rep = drawIcon(side: pixels),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()

try? FileManager.default.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(outputPath)")
