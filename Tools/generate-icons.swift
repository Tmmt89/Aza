#!/usr/bin/env swift
// Run from the repository root: swift Tools/generate-icons.swift
// Packs the approved PNG artwork into macOS assets without redrawing it.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Aza/Assets.xcassets")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func context(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func artwork(_ name: String) throws -> CGImage {
    let data = try Data(contentsOf: root.appendingPathComponent("Design/\(name).png"))
    guard let image = NSBitmapImageRep(data: data)?.cgImage else {
        fatalError("Cannot decode \(name)")
    }
    let canvas = context(width: image.width, height: image.height)
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = canvas.data!.assumingMemoryBound(to: UInt8.self)
    var left = image.width, top = image.height, right = -1, bottom = -1
    for y in 0..<image.height {
        for x in 0..<image.width where pixels[(y * image.width + x) * 4 + 3] > 8 {
            left = min(left, x); right = max(right, x)
            top = min(top, y); bottom = max(bottom, y)
        }
    }
    precondition(left > 0 && top > 0 && right < image.width - 1 && bottom < image.height - 1,
                 "\(name) must have transparent outer margins, not a baked background")
    precondition(right > left && bottom > top, "\(name) is empty")
    return canvas.makeImage()!.cropping(to: CGRect(
        x: left, y: top, width: right - left + 1, height: bottom - top + 1))!
}

func write(_ image: CGImage, width: Int, height: Int, inset: CGFloat, to url: URL) throws {
    let canvas = context(width: width, height: height)
    let scale = min((CGFloat(width) - inset * 2) / CGFloat(image.width),
                    (CGFloat(height) - inset * 2) / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    canvas.interpolationQuality = .high
    canvas.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2,
                                 y: (CGFloat(height) - size.height) / 2,
                                 width: size.width, height: size.height))
    let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    precondition(bitmap.hasAlpha && bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
}

let icon = try artwork("app-icon")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try write(icon, width: size, height: size, inset: CGFloat(size) * 100 / 1024,
              to: assets.appendingPathComponent("AppIcon.appiconset/icon_\(size).png"))
}

let mark = try artwork("menu-bar-mark")
let menu = assets.appendingPathComponent("MenuBarMark.imageset")
try FileManager.default.createDirectory(at: menu, withIntermediateDirectories: true)
for scale in 1...3 {
    try write(mark, width: 28 * scale, height: 18 * scale, inset: CGFloat(scale),
              to: menu.appendingPathComponent("mark_\(scale)x.png"))
}
let manifest: [String: Any] = [
    "images": (1...3).map { ["filename": "mark_\($0)x.png", "idiom": "universal", "scale": "\($0)x"] },
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template"],
]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: menu.appendingPathComponent("Contents.json"), options: .atomic)
print("Generated and checked 7 app icon sizes and 3 menu-bar template sizes")
