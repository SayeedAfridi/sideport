#!/usr/bin/env swift
// Draws the background of the disk image window, in the same graphite and teal
// as the app icon.
//
//   swift scripts/make-dmg-background.swift scripts/release/dmg-background.tiff
//
// Written as a two-representation TIFF — 640x400 at 72dpi and the same drawing
// at 144dpi — because that is the only way Finder is told a background has a
// Retina version. A lone @2x PNG is displayed at half size instead.

import AppKit

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "scripts/release/dmg-background.tiff"

let width: CGFloat = 640
let height: CGFloat = 400

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// The flat one-colour mark from the icon: the plate with the pane and the
/// mounted row knocked out of it, drawn to fit `rect`.
func mark(in rect: NSRect) -> NSBezierPath {
    let unit = rect.width / 600            // the mark is 600 wide in icon space
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: rect.minX + (x - 212) * unit,
                                         y: rect.minY + (772 - y - h) * unit,
                                         width: w * unit, height: h * unit),
                     xRadius: r * unit, yRadius: r * unit)
    }
    let path = box(212, 252, 600, 520, 110)
    path.append(box(512, 322, 230, 380, 60))
    path.append(box(272, 476, 170, 72, 36))
    path.windingRule = .evenOdd
    return path
}

/// One representation of the background at `scale`.
func draw(scale: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write(Data("could not allocate the background bitmap\n".utf8))
        exit(1)
    }
    // Points, not pixels: setting the rep's size is what marks the 2x drawing
    // as 144dpi rather than as a second, larger image.
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Plate: the icon's own gradient, and its sheen falling off before halfway.
    NSGradient(colors: [color(0x3A4149), color(0x22272C), color(0x14181B)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)?
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.07), NSColor(white: 1, alpha: 0)],
               atLocations: [0, 1], colorSpace: .sRGB)?
        .draw(in: NSRect(x: 0, y: height * 0.52, width: width, height: height * 0.48), angle: -90)

    // The two plates the icons stand on — the icon's own composition, one
    // panel for the app and one for the folder it is going to.
    //
    // They are mid-toned on purpose. Finder draws icon labels in black under a
    // light appearance and white under a dark one, over whatever we put here,
    // so a panel that suits one is illegible in the other. At this value both
    // land near a 4.5:1 contrast ratio and the two names stay readable either
    // way — which matters more than the panels being as dark as the icon.
    for x in [CGFloat(46), CGFloat(364)] {
        let plate = NSBezierPath(roundedRect: NSRect(x: x, y: 115, width: 230, height: 195),
                                 xRadius: 26, yRadius: 26)
        NSGradient(colors: [color(0x7B858D), color(0x67727A)], atLocations: [0, 1], colorSpace: .sRGB)?
            .draw(in: plate, angle: -90)
        plate.lineWidth = 1
        NSColor(white: 1, alpha: 0.14).setStroke()
        plate.stroke()
    }

    // The gesture the window is asking for, crossing the gap between them.
    color(0x23C7BB).setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 296, y: 220))
    arrow.line(to: NSPoint(x: 340, y: 220))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 331, y: 233))
    head.line(to: NSPoint(x: 345, y: 220))
    head.line(to: NSPoint(x: 331, y: 207))
    head.lineWidth = 6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Watermark: quiet enough to sit under the window's real content, and off
    // the panels so it never competes with the two names that matter.
    let watermark = NSRect(x: 40, y: 30, width: 30, height: 26)
    NSColor(white: 1, alpha: 0.22).setFill()
    mark(in: watermark).fill()
    let title = NSAttributedString(string: "Sideport", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor(white: 1, alpha: 0.22),
        .kern: 0.4,
    ])
    title.draw(at: NSPoint(x: watermark.maxX + 12, y: 31))

    let caption = NSAttributedString(string: "Drag Sideport into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.34),
    ])
    caption.draw(at: NSPoint(x: width - caption.size().width - 40, y: 34))

    return rep
}

let reps = [draw(scale: 1), draw(scale: 2)]
guard let tiff = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode the background\n".utf8))
    exit(1)
}
let directory = (output as NSString).deletingLastPathComponent
if !directory.isEmpty {
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
}
try! tiff.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(Int(width))x\(Int(height)), 1x and 2x)")
