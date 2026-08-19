#!/usr/bin/env swift
// Generates the menu bar glyph — the same rail-and-pane shape as the app icon,
// reduced to what survives at 16pt beside SF Symbols.
//
//   swift scripts/make-glyph.swift Apps/Sideport/Assets.xcassets
//
// Two states, because the menu bar's whole job is saying whether a device is
// there: mounted, and mounted-with-nothing, which wears the slash macOS uses
// everywhere else for "not available".
//
// Written as vector PDF and marked a template image, so AppKit tints it to
// match the menu bar rather than us guessing at light and dark.

import AppKit

let catalog = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Apps/Sideport/Assets.xcassets"

/// The glyph, drawn at its natural 16pt size into `context`.
///
/// Strokes are 1.4 / 1.3 to match SF Symbols Regular; the mounted row stays
/// solid so the glyph keeps the same optical weight as its neighbours.
func drawGlyph(in context: CGContext) {
    context.setLineWidth(1.4)
    context.addPath(CGPath(roundedRect: CGRect(x: 1.7, y: 2.6, width: 12.6, height: 10.8),
                           cornerWidth: 2.6, cornerHeight: 2.6, transform: nil))
    context.strokePath()

    context.setLineWidth(1.3)
    context.move(to: CGPoint(x: 6.2, y: 3.2))
    context.addLine(to: CGPoint(x: 6.2, y: 12.8))
    context.strokePath()

    context.addPath(CGPath(roundedRect: CGRect(x: 3.7, y: 7.2, width: 1.0, height: 1.6),
                           cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
    context.fillPath()
}

/// The slash, and the gap that keeps it from touching what it crosses.
///
/// Top left down to bottom right, the direction every `.slash` symbol in the
/// system runs, so it reads as the same word rather than a decoration.
///
/// A template image carries no colours to overpaint the glyph with, so the gap
/// has to be a hole: the glyph is clipped to everything outside a fattened copy
/// of the slash, and the slash is then drawn down the middle of it.
let slash = CGMutablePath()
slash.move(to: CGPoint(x: 2.2, y: 13.8))
slash.addLine(to: CGPoint(x: 13.8, y: 2.2))

func page(slashed: Bool) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 16, height: 16)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        FileHandle.standardError.write(Data("could not open a PDF context\n".utf8))
        exit(1)
    }
    context.beginPDFPage(nil)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(.black)
    context.setFillColor(.black)

    if slashed {
        context.saveGState()
        context.addRect(box)
        context.addPath(slash.copy(strokingWithWidth: 3.2, lineCap: .round, lineJoin: .round,
                                   miterLimit: 10, transform: .identity))
        context.clip(using: .evenOdd)
        drawGlyph(in: context)
        context.restoreGState()

        context.setLineWidth(1.4)
        context.addPath(slash)
        context.strokePath()
    } else {
        drawGlyph(in: context)
    }

    context.endPDFPage()
    context.closePDF()
    return data as Data
}

for (name, slashed) in [("MenuBarIcon", false), ("MenuBarIconOffline", true)] {
    let directory = "\(catalog)/\(name).imageset"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try! page(slashed: slashed).write(to: URL(fileURLWithPath: "\(directory)/\(name).pdf"))
    try! """
    {
      "images" : [
        {
          "filename" : "\(name).pdf",
          "idiom" : "universal"
        }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : {
        "preserves-vector-representation" : true,
        "template-rendering-intent" : "template"
      }
    }
    """.write(toFile: "\(directory)/Contents.json", atomically: true, encoding: .utf8)
    print("wrote \(directory)")
}
