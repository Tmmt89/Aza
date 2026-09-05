#!/usr/bin/env swift
// swift Tools/dmg-background.swift output.tiff
import AppKit

let size = NSSize(width: 640, height: 380)
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let representations = [1, 2].map { scale -> NSBitmapImageRep in
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: 640 * scale, pixelsHigh: 380 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    graphics.cgContext.translateBy(x: 0, y: CGFloat(380 * scale))
    graphics.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    ("Установите Aza" as NSString).draw(in: NSRect(x: 30, y: 44, width: 580, height: 38),
        withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                         .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1),
                         .paragraphStyle: paragraph])
    ("Перетащите Aza в папку Applications" as NSString).draw(
        in: NSRect(x: 30, y: 316, width: 580, height: 28),
        withAttributes: [.font: NSFont.systemFont(ofSize: 16),
                         .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1),
                         .paragraphStyle: paragraph])
    let arrowColor = NSColor(calibratedRed: 0.39, green: 0.51, blue: 0.19, alpha: 1)
    arrowColor.setFill()
    // Неровная толщина росчерка и свободные концы, с отступом от значков.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 229, y: 157))
    arrow.curve(to: NSPoint(x: 319, y: 99),
                controlPoint1: NSPoint(x: 246, y: 113),
                controlPoint2: NSPoint(x: 282, y: 87))
    arrow.curve(to: NSPoint(x: 405, y: 140),
                controlPoint1: NSPoint(x: 351, y: 105),
                controlPoint2: NSPoint(x: 383, y: 121))
    arrow.curve(to: NSPoint(x: 403, y: 144),
                controlPoint1: NSPoint(x: 407, y: 142),
                controlPoint2: NSPoint(x: 406, y: 145))
    arrow.curve(to: NSPoint(x: 319, y: 104),
                controlPoint1: NSPoint(x: 380, y: 126),
                controlPoint2: NSPoint(x: 350, y: 110))
    arrow.curve(to: NSPoint(x: 229, y: 157),
                controlPoint1: NSPoint(x: 283, y: 94),
                controlPoint2: NSPoint(x: 250, y: 115))
    arrow.close()
    arrow.fill()
    arrowColor.setStroke()
    let tip = NSBezierPath()
    tip.lineWidth = 3
    tip.lineCapStyle = .round
    tip.lineJoinStyle = .round
    tip.move(to: NSPoint(x: 398, y: 124))
    tip.curve(to: NSPoint(x: 405, y: 142),
              controlPoint1: NSPoint(x: 400, y: 131),
              controlPoint2: NSPoint(x: 400, y: 139))
    tip.curve(to: NSPoint(x: 385, y: 139),
              controlPoint1: NSPoint(x: 400, y: 140),
              controlPoint2: NSPoint(x: 392, y: 141))
    tip.stroke()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = size
    return bitmap
}
// Retina и обычный фон должны совпадать по масштабу, а не только по DPI.
var difference: CGFloat = 0
var samples: CGFloat = 0
for y in stride(from: 0, to: 380, by: 4) {
    for x in stride(from: 0, to: 640, by: 4) {
        let small = representations[0].colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let retina = representations[1].colorAt(x: x * 2, y: y * 2)!.usingColorSpace(.sRGB)!
        difference += abs(small.greenComponent - retina.greenComponent)
        samples += 1
    }
}
precondition(difference / samples < 0.01, "Retina background has a different scale")
try NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff,
    properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
