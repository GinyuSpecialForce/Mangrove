#!/usr/bin/env swift
//
// Renders the app icon: a mangrove tree standing on its arching prop roots in
// shallow water, on a deep tidal-green tile. The same geometry is drawn in
// SwiftUI by Theme.swift's `MangroveMark`.
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
    colors: [rgb(44, 156, 116), rgb(16, 104, 75), rgb(7, 54, 45)] as CFArray,
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

// MARK: - Tidal water

// A darker band below the waterline gives the roots something to stand in.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let water = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 3, green: 38, blue: 34, alpha: 0),
             CGColor(srgbRed: 3, green: 38, blue: 34, alpha: 0.32)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    water,
    start: CGPoint(x: 0, y: S * 0.31),
    end: CGPoint(x: 0, y: tile.minY),
    options: []
)
ctx.restoreGState()

// MARK: - Mangrove canopy

// Coarse coordinates are deliberate: the canopy is a low, three-lobed coastal
// crown rather than a generic round tree. All of it is drawn white so the mark
// still reads when the icon is scaled to 16pt.
// The crown is a union of overlapping rounded masses, the way a mangrove's
// several stems each push up their own clump of leaves. Filling them as one path
// keeps a single silhouette (and a single shadow) with no seams between lobes.
let canopy = CGMutablePath()
canopy.addEllipse(in: CGRect(
    x: S * 0.235, y: S * 0.545, width: S * 0.530, height: S * 0.155
))
canopy.addEllipse(in: CGRect(
    x: S * 0.245, y: S * 0.585, width: S * 0.175, height: S * 0.165
))
canopy.addEllipse(in: CGRect(
    x: S * 0.360, y: S * 0.625, width: S * 0.195, height: S * 0.190
))
canopy.addEllipse(in: CGRect(
    x: S * 0.480, y: S * 0.635, width: S * 0.190, height: S * 0.190
))
canopy.addEllipse(in: CGRect(
    x: S * 0.595, y: S * 0.610, width: S * 0.175, height: S * 0.175
))
canopy.addEllipse(in: CGRect(
    x: S * 0.660, y: S * 0.575, width: S * 0.120, height: S * 0.140
))
// Rounds the left shoulder where the outer lobe meets the base, so the crown
// does not have a visible notch at nine o'clock.
canopy.addEllipse(in: CGRect(
    x: S * 0.225, y: S * 0.555, width: S * 0.190, height: S * 0.120
))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.007), blur: S * 0.014,
              color: CGColor(srgbRed: 0, green: 30, blue: 22, alpha: 0.32))
ctx.addPath(canopy)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// The underside cools very slightly, so the crown has volume without a gloss.
ctx.saveGState()
ctx.addPath(canopy)
ctx.clip()
let foliage = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
             CGColor(srgbRed: 222 / 255, green: 242 / 255, blue: 230 / 255, alpha: 1)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    foliage,
    start: CGPoint(x: 0, y: S * 0.79),
    end: CGPoint(x: 0, y: S * 0.54),
    options: []
)
ctx.restoreGState()

// MARK: - Trunk and prop roots

ctx.saveGState()
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))

// A short, sturdy trunk; the roots take over below it. The crown sits close to
// the water, which is what stops the silhouette reading as a mushroom.
let trunk = CGMutablePath()
trunk.move(to: CGPoint(x: S * 0.470, y: S * 0.570))
trunk.addLine(to: CGPoint(x: S * 0.530, y: S * 0.570))
trunk.addCurve(
    to: CGPoint(x: S * 0.545, y: S * 0.455),
    control1: CGPoint(x: S * 0.530, y: S * 0.525),
    control2: CGPoint(x: S * 0.538, y: S * 0.485)
)
trunk.addLine(to: CGPoint(x: S * 0.455, y: S * 0.455))
trunk.addCurve(
    to: CGPoint(x: S * 0.470, y: S * 0.570),
    control1: CGPoint(x: S * 0.462, y: S * 0.485),
    control2: CGPoint(x: S * 0.470, y: S * 0.525)
)
trunk.closeSubpath()
ctx.addPath(trunk)
ctx.fillPath()
ctx.restoreGState()

// Five arching roots: the silhouette that distinguishes a mangrove from an
// ordinary tree. The middle root is the trunk continuing into the water.
func drawRoot(
    from start: CGPoint,
    to end: CGPoint,
    control1: CGPoint,
    control2: CGPoint,
    width: CGFloat
) {
    let root = CGMutablePath()
    root.move(to: start)
    root.addCurve(to: end, control1: control1, control2: control2)
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(root)
    ctx.strokePath()
    ctx.restoreGState()
}

let rootWidth = max(1, S * 0.038)
let waterLine = S * 0.272

// A waterline sits behind the roots, so their tips disappear into the tile
// instead of stopping in mid-air.
ctx.saveGState()
ctx.setLineWidth(max(1, S * 0.006))
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(srgbRed: 198 / 255, green: 236 / 255, blue: 219 / 255, alpha: 0.26))
ctx.move(to: CGPoint(x: S * 0.235, y: waterLine))
ctx.addLine(to: CGPoint(x: S * 0.765, y: waterLine))
ctx.strokePath()
ctx.restoreGState()

// The long outer arches.
drawRoot(
    from: CGPoint(x: S * 0.466, y: S * 0.470),
    to: CGPoint(x: S * 0.305, y: waterLine),
    control1: CGPoint(x: S * 0.430, y: S * 0.465),
    control2: CGPoint(x: S * 0.310, y: S * 0.390),
    width: rootWidth
)
drawRoot(
    from: CGPoint(x: S * 0.534, y: S * 0.470),
    to: CGPoint(x: S * 0.695, y: waterLine),
    control1: CGPoint(x: S * 0.570, y: S * 0.465),
    control2: CGPoint(x: S * 0.690, y: S * 0.390),
    width: rootWidth
)

// The two inner braces.
drawRoot(
    from: CGPoint(x: S * 0.484, y: S * 0.458),
    to: CGPoint(x: S * 0.412, y: S * 0.262),
    control1: CGPoint(x: S * 0.462, y: S * 0.430),
    control2: CGPoint(x: S * 0.412, y: S * 0.335),
    width: rootWidth * 0.84
)
drawRoot(
    from: CGPoint(x: S * 0.516, y: S * 0.458),
    to: CGPoint(x: S * 0.588, y: S * 0.262),
    control1: CGPoint(x: S * 0.538, y: S * 0.430),
    control2: CGPoint(x: S * 0.588, y: S * 0.335),
    width: rootWidth * 0.84
)
drawRoot(
    from: CGPoint(x: S * 0.500, y: S * 0.455),
    to: CGPoint(x: S * 0.500, y: S * 0.252),
    control1: CGPoint(x: S * 0.508, y: S * 0.400),
    control2: CGPoint(x: S * 0.492, y: S * 0.320),
    width: rootWidth * 0.90
)

// MARK: - Ripples

// Shortening strokes read as water at every size and keep the roots from
// appearing to float above the tile.
ctx.saveGState()
ctx.setLineCap(.round)
for ripple in [
    (y: S * 0.248, width: S * 0.380, alpha: 0.32),
    (y: S * 0.216, width: S * 0.270, alpha: 0.24),
    (y: S * 0.188, width: S * 0.160, alpha: 0.18),
] {
    ctx.setLineWidth(max(1, S * 0.007))
    ctx.setStrokeColor(CGColor(srgbRed: 198 / 255, green: 236 / 255, blue: 219 / 255, alpha: ripple.alpha))
    ctx.move(to: CGPoint(x: S * 0.5 - ripple.width / 2, y: ripple.y))
    ctx.addLine(to: CGPoint(x: S * 0.5 + ripple.width / 2, y: ripple.y))
    ctx.strokePath()
}
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
