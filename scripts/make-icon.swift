#!/usr/bin/env swift

// Mask a square source PNG into a macOS-style squircle and emit the
// 10 sizes that iconutil expects in an .iconset directory.
//
// Usage: swift scripts/make-icon.swift <source.png> <output-dir>

import AppKit
import CoreGraphics
import Foundation

// Squircle (continuous-curvature) corner using cubic Bezier approximation.
// `f` is the flatness — values around 0.5 match Apple's macOS icon shape.
func squirclePath(in rect: CGRect, cornerFactor: CGFloat = 0.225, f: CGFloat = 0.5) -> CGPath {
    let r = min(rect.width, rect.height) * cornerFactor
    let x = rect.minX, y = rect.minY
    let w = rect.width,  h = rect.height
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + r, y: y))
    p.addLine(to: CGPoint(x: x + w - r, y: y))
    p.addCurve(to: CGPoint(x: x + w, y: y + r),
               control1: CGPoint(x: x + w - r * f, y: y),
               control2: CGPoint(x: x + w, y: y + r * f))
    p.addLine(to: CGPoint(x: x + w, y: y + h - r))
    p.addCurve(to: CGPoint(x: x + w - r, y: y + h),
               control1: CGPoint(x: x + w, y: y + h - r * f),
               control2: CGPoint(x: x + w - r * f, y: y + h))
    p.addLine(to: CGPoint(x: x + r, y: y + h))
    p.addCurve(to: CGPoint(x: x, y: y + h - r),
               control1: CGPoint(x: x + r * f, y: y + h),
               control2: CGPoint(x: x, y: y + h - r * f))
    p.addLine(to: CGPoint(x: x, y: y + r))
    p.addCurve(to: CGPoint(x: x + r, y: y),
               control1: CGPoint(x: x, y: y + r * f),
               control2: CGPoint(x: x + r * f, y: y))
    p.closeSubpath()
    return p
}

func render(source: CGImage, size: Int, cornerFactor: CGFloat) -> Data? {
    let dim = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: dim, height: dim))

    let path = squirclePath(in: CGRect(x: 0, y: 0, width: dim, height: dim),
                            cornerFactor: cornerFactor)
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: dim, height: dim))

    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
}

// --- entry ---

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("Usage: \(args[0]) <source.png> <output-dir>\n".utf8))
    exit(1)
}
let sourcePath = args[1]
let outDir = args[2]

guard let nsImage = NSImage(contentsOfFile: sourcePath),
      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("Failed to read \(sourcePath)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

let cornerFactor: CGFloat = 0.225

for (name, size) in sizes {
    guard let data = render(source: cgImage, size: size, cornerFactor: cornerFactor) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    let path = (outDir as NSString).appendingPathComponent(name)
    try? data.write(to: URL(fileURLWithPath: path))
    print("  wrote \(name) (\(data.count) bytes)")
}
