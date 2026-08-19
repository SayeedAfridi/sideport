#!/usr/bin/env swift
// Generates the app icon set from an SF Symbol, so the icon is reproducible
// from source rather than a binary blob nobody can edit.
//
//   swift scripts/make-icon.swift Apps/Sideport/Assets.xcassets/AppIcon.appiconset

import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Apps/Sideport/Assets.xcassets/AppIcon.appiconset"

/// Tints a template symbol by filling only its opaque pixels.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let output = NSImage(size: image.size)
    output.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    output.unlockFocus()
    return output
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

    // macOS icons sit inside the canvas rather than filling it.
    let inset = size * 0.085
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237  // Apple's squircle approximation

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.71, blue: 0.44, alpha: 1),   // Android green
        NSColor(srgbRed: 0.06, green: 0.42, blue: 0.35, alpha: 1),
    ])
    gradient?.draw(in: NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius), angle: -90)

    let symbolName = "iphone.gen3"
    let configuration = NSImage.SymbolConfiguration(pointSize: plate.height * 0.62, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Android device")?
        .withSymbolConfiguration(configuration) else {
        FileHandle.standardError.write(Data("missing symbol \(symbolName)\n".utf8))
        exit(1)
    }
    let white = tinted(symbol, .white)
    let box = NSRect(x: plate.midX - white.size.width / 2,
                     y: plate.midY - white.size.height / 2,
                     width: white.size.width,
                     height: white.size.height)
    white.draw(in: box)

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
