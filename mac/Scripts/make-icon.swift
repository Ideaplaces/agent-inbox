#!/usr/bin/env swift
// Draws the Agent Inbox app icon and writes an .iconset for iconutil.
//
// The mark is generated rather than committed as a binary so the whole app,
// icon included, is auditable as source. Run via Scripts/make-icon.sh.

import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AgentInbox.iconset"

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func draw(size: CGFloat, into context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.saveGState()

    // macOS icons sit in a rounded square with a margin, not edge to edge.
    let inset = size * 0.08
    let body = rect.insetBy(dx: inset, dy: inset)
    let corner = body.width * 0.2237  // Apple's continuous-corner ratio
    let clip = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner,
                      transform: nil)
    context.addPath(clip)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.13, green: 0.17, blue: 0.23, alpha: 1),
            CGColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: [])

    // The tray: a wide slot the arrow drops into.
    let unit = size / 100
    let trayWidth = unit * 52
    let trayHeight = unit * 20
    let tray = CGRect(
        x: rect.midX - trayWidth / 2,
        y: rect.midY - unit * 26,
        width: trayWidth,
        height: trayHeight)

    let stroke = unit * 7
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))

    let trayPath = CGMutablePath()
    trayPath.move(to: CGPoint(x: tray.minX, y: tray.maxY))
    trayPath.addLine(to: CGPoint(x: tray.minX, y: tray.minY + stroke / 2))
    trayPath.addLine(to: CGPoint(x: tray.maxX, y: tray.minY + stroke / 2))
    trayPath.addLine(to: CGPoint(x: tray.maxX, y: tray.maxY))
    context.addPath(trayPath)
    context.strokePath()

    // The arrow: something arriving, which is the whole product.
    let arrowTop = rect.midY + unit * 30
    let arrowBottom = rect.midY - unit * 12
    context.move(to: CGPoint(x: rect.midX, y: arrowTop))
    context.addLine(to: CGPoint(x: rect.midX, y: arrowBottom))
    context.strokePath()

    let head = unit * 13
    context.move(to: CGPoint(x: rect.midX - head, y: arrowBottom + head))
    context.addLine(to: CGPoint(x: rect.midX, y: arrowBottom))
    context.addLine(to: CGPoint(x: rect.midX + head, y: arrowBottom + head))
    context.strokePath()

    // The amber dot is "someone needs you", the state the app exists for.
    let dotRadius = unit * 9
    let dot = CGRect(
        x: body.maxX - dotRadius * 2 - unit * 9,
        y: body.maxY - dotRadius * 2 - unit * 9,
        width: dotRadius * 2,
        height: dotRadius * 2)
    context.setFillColor(CGColor(red: 0.98, green: 0.68, blue: 0.16, alpha: 1))
    context.fillEllipse(in: dot)

    context.restoreGState()
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for entry in sizes {
    let px = entry.px
    guard let context = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create bitmap context") }

    context.setAllowsAntialiasing(true)
    draw(size: CGFloat(px), into: context)

    guard let image = context.makeImage() else { fatalError("could not render icon") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode png")
    }
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(entry.name).png")
    try png.write(to: url)
}

print("wrote \(sizes.count) images to \(outputDir)")
