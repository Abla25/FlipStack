#!/usr/bin/env swift

import AppKit
import Foundation

private let usage = "Usage: render-icon.swift <source.svg> <output.png> [size]"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    fail(usage)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let requestedSize = arguments.count == 4 ? Int(arguments[3]) : 1024

guard let requestedSize, requestedSize >= 64, requestedSize <= 4096 else {
    fail("size must be an integer between 64 and 4096")
}

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fail("could not load \(sourceURL.path)")
}

let canvasSize = NSSize(width: requestedSize, height: requestedSize)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: requestedSize,
    pixelsHigh: requestedSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("could not allocate a \(requestedSize)x\(requestedSize) bitmap")
}

bitmap.size = canvasSize
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("could not create a drawing context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let sourceSize = sourceImage.size
guard sourceSize.width > 0, sourceSize.height > 0 else {
    NSGraphicsContext.restoreGraphicsState()
    fail("the source image has no dimensions")
}

let scale = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
let drawRect = NSRect(
    x: (canvasSize.width - drawSize.width) / 2,
    y: (canvasSize.height - drawSize.height) / 2,
    width: drawSize.width,
    height: drawSize.height
)

sourceImage.draw(
    in: drawRect,
    from: NSRect(origin: .zero, size: sourceSize),
    operation: .sourceOver,
    fraction: 1
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
    fail("could not encode the PNG")
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: .atomic)
} catch {
    fail("could not write \(outputURL.path): \(error.localizedDescription)")
}

print("Rendered \(requestedSize)x\(requestedSize) icon to \(outputURL.path)")
