#!/usr/bin/env swift
//
// Renders the app icon: a green tile with the printed-leaf mark that Mangrove
// also draws in SwiftUI (Theme.swift's `LeafMark`).
//
//   swift scripts/make-icon.swift out.png [size]
//
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outputPath = args.count > 1 ? args[1] : "icon_1024.png"
let size = args.count > 2 ? (Int(args[2]) ?? 1024) : 1024
let S = CGFloat(size)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("could not create a bitmap context\n".utf8))
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// MARK: - Rounded tile (macOS icon grid: 824pt content inside 1024pt)

let inset = S * 0.098
let tile = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner = tile.width * 0.2237
let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

// Soft contact shadow so the tile sits on any wallpaper.
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -S * 0.014),
    blur: S * 0.035,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30)
)
ctx.addPath(tilePath)
ctx.setFillColor(rgb(10, 95, 46))
ctx.fillPath()
ctx.restoreGState()

// Vertical green gradient inside the tile.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: space,
    colors: [rgb(56, 185, 104), rgb(20, 140, 66), rgb(9, 88, 43)] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: tile.maxY),
    end: CGPoint(x: 0, y: tile.minY),
    options: []
)

// Warm light source in the upper-left, like the rest of the macOS icon set.
let highlight = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
             CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: tile.minX + tile.width * 0.22, y: tile.maxY - tile.height * 0.12),
    startRadius: 0,
    endCenter: CGPoint(x: tile.minX + tile.width * 0.22, y: tile.maxY - tile.height * 0.12),
    endRadius: tile.width * 0.72,
    options: []
)
ctx.restoreGState()

// Inner top edge highlight.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let edge = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35),
             CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    edge,
    start: CGPoint(x: 0, y: tile.maxY),
    end: CGPoint(x: 0, y: tile.maxY - tile.height * 0.06),
    options: []
)
ctx.restoreGState()

// MARK: - Leaf mark

let center = CGPoint(x: S * 0.5, y: S * 0.505)
let halfHeight = tile.height * 0.305
let halfWidth = tile.width * 0.225

let tipTop = CGPoint(x: center.x, y: center.y + halfHeight)
let tipBottom = CGPoint(x: center.x, y: center.y - halfHeight)

let leaf = CGMutablePath()
leaf.move(to: tipBottom)
// Left edge, bowing outward.
leaf.addCurve(
    to: tipTop,
    control1: CGPoint(x: center.x - halfWidth * 1.42, y: center.y - halfHeight * 0.62),
    control2: CGPoint(x: center.x - halfWidth * 1.42, y: center.y + halfHeight * 0.62)
)
// Right edge, bowing outward.
leaf.addCurve(
    to: tipBottom,
    control1: CGPoint(x: center.x + halfWidth * 1.42, y: center.y + halfHeight * 0.62),
    control2: CGPoint(x: center.x + halfWidth * 1.42, y: center.y - halfHeight * 0.62)
)
leaf.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006), blur: S * 0.016,
              color: CGColor(srgbRed: 0, green: 40, blue: 18, alpha: 0.35))
ctx.addPath(leaf)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Diagonal fold: light from the upper left, so the leaf reads as folded paper.
ctx.saveGState()
ctx.addPath(leaf)
ctx.clip()
let fold = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
             CGColor(srgbRed: 205 / 255, green: 236 / 255, blue: 217 / 255, alpha: 1)] as CFArray,
    locations: [0.35, 1.0]
)!
ctx.drawLinearGradient(
    fold,
    start: CGPoint(x: center.x - halfWidth * 0.9, y: center.y + halfHeight * 0.7),
    end: CGPoint(x: center.x + halfWidth * 1.1, y: center.y - halfHeight * 0.8),
    options: []
)
ctx.restoreGState()

// Single central vein, stopping short of both tips.
ctx.saveGState()
ctx.addPath(leaf)
ctx.clip()
ctx.setLineWidth(max(1, S * 0.0085))
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(20, 112, 56, 0.42))
ctx.move(to: CGPoint(x: center.x, y: center.y - halfHeight * 0.62))
ctx.addLine(to: CGPoint(x: center.x, y: center.y + halfHeight * 0.42))
ctx.strokePath()
ctx.restoreGState()

// MARK: - Write PNG

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    FileHandle.standardError.write(Data("could not open \(outputPath) for writing\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(outputPath)\n".utf8))
    exit(1)
}
print("wrote \(outputPath) (\(size)x\(size))")
