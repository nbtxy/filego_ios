#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: replace-screenshot-title.swift <input.png> <output.png>\n", stderr)
    exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
    let data = try? Data(contentsOf: inputURL),
    let source = NSBitmapImageRep(data: data),
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: source.pixelsWide,
        pixelsHigh: source.pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
else {
    fputs("unable to read input PNG\n", stderr)
    exit(65)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("unable to create drawing context\n", stderr)
    exit(70)
}
NSGraphicsContext.current = context

let canvasHeight = CGFloat(bitmap.pixelsHigh)
source.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
let replacementRect = NSRect(x: 390, y: canvasHeight - 280, width: 510, height: 105)
NSColor(srgbRed: 245 / 255, green: 242 / 255, blue: 233 / 255, alpha: 1).setFill()
replacementRect.fill()

let title = "JustFling Pro" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 50, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 16 / 255, green: 32 / 255, blue: 27 / 255, alpha: 1),
]
let titleSize = title.size(withAttributes: attributes)
let titleOrigin = NSPoint(
    x: (CGFloat(bitmap.pixelsWide) - titleSize.width) / 2,
    y: canvasHeight - 200 - titleSize.height
)
title.draw(at: titleOrigin, withAttributes: attributes)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("unable to encode output PNG\n", stderr)
    exit(70)
}
try png.write(to: outputURL, options: .atomic)
