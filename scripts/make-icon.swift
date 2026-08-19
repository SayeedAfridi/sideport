#!/usr/bin/env swift
// Generates the app icon set from the vector spec below, so the icon is
// reproducible from source rather than a binary blob nobody can edit.
//
//   swift scripts/make-icon.swift Apps/Sideport/Assets.xcassets/AppIcon.appiconset
//
// The design is "rail and pane": a dark rail of rows beside a light pane, with
// the mounted volume lit teal — a device list next to the folder it opens.
// Every coordinate below is stated in the 1024pt design space and scaled to the
// requested pixel size, so the geometry is identical at 16px and 1024px.

import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Apps/Sideport/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Renders one icon at an exact pixel size.
///
/// Drawing through `NSImage.lockFocus` would render at the display's backing
/// scale, producing 2x-sized PNGs that `actool` rejects without ever saying so —
/// the asset catalog simply compiles to nothing. Rendering into an explicit
/// bitmap whose `size` matches its pixel dimensions keeps one point at one pixel.
func icon(size: CGFloat) -> Data {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write(Data("could not allocate \(pixels)px bitmap\n".utf8))
        exit(1)
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let unit = size / 1024

    /// A rectangle of the design, whose y runs downwards from the top edge like
    /// the drawing it came from, in the upwards-y coordinates AppKit draws in.
    func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x * unit, y: (1024 - y - height) * unit, width: width * unit, height: height * unit)
    }

    func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius * unit, yRadius: radius * unit)
    }

    // Angle -90 runs the gradient downwards, so its first colour is the topmost
    // — the order the design states its stops in.
    func fill(_ path: NSBezierPath, _ stops: [(UInt32, CGFloat)]) {
        NSGradient(colors: stops.map { color($0.0) },
                   atLocations: stops.map(\.1),
                   colorSpace: .sRGB)?.draw(in: path, angle: -90)
    }

    // macOS icons sit inside the canvas rather than filling it.
    let plate = rounded(box(87, 87, 850, 850), 190)
    fill(plate, [(0x474F56, 0), (0x2A3035, 0.5), (0x191D21, 1)])

    // The sheen fades out at y 580, well above the plate's bottom edge, so it
    // is drawn as a gradient over the plate's top half rather than all of it.
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(colorsAndLocations: (NSColor(white: 1, alpha: 0.16), 0), (NSColor(white: 1, alpha: 0), 1))?
        .draw(in: box(87, 87, 850, 493), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Inner rim: a hairline of light just inside the plate edge, which is what
    // keeps the icon from going flat against a dark Dock.
    let rim = rounded(box(90.5, 90.5, 843, 843), 187)
    rim.lineWidth = 7 * unit
    NSColor(white: 1, alpha: 0.1).setStroke()
    rim.stroke()

    fill(rounded(box(212, 252, 250, 520), 80), [(0x0B0F12, 0), (0x1E252A, 1)])   // rail
    fill(rounded(box(502, 252, 310, 520), 80), [(0xE9EEF1, 0), (0xC3CDD2, 0.55), (0x9EAAB1, 1)])  // pane

    // Two idle rows and, between them, the mounted one: taller than its
    // neighbours and pushed past the rail's left edge, so it survives as a teal
    // bar at sizes where the grey rows have dissolved.
    color(0x5B666D).setFill()
    rounded(box(274, 330, 126, 56), 28).fill()
    rounded(box(274, 638, 126, 56), 28).fill()
    fill(rounded(box(246, 470, 184, 84), 42), [(0x45E4D6, 0), (0x12A79E, 1)])

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(size)\n".utf8))
        exit(1)
    }
    return png
}

// (point size, scale) pairs macOS asks for.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]

try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

var entries: [String] = []
for (points, scale) in variants {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    try! icon(size: CGFloat(pixels)).write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name)"))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(toFile: "\(outputDirectory)/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(variants.count) icons to \(outputDirectory)")
