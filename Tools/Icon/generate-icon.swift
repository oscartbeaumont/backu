#!/usr/bin/env swift
//
//  generate-icon.swift
//  Backu
//
//  Renders the Backu app icon (iOS + macOS) and the in-app brand mark,
//  together with the asset catalog contents that reference them.
//
//  Usage (from anywhere):
//
//      swift Tools/Icon/generate-icon.swift
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Canvas

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

final class Bitmap {
    let width: Int
    let height: Int
    let context: CGContext
    let hasAlpha: Bool

    init(width: Int, height: Int, hasAlpha: Bool) {
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
        let info = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: sRGB,
                bitmapInfo: info
            )
        else {
            fatalError("Unable to create a \(width)x\(height) bitmap context")
        }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        context = ctx
    }

    var image: CGImage {
        guard let image = context.makeImage() else {
            fatalError("Unable to snapshot a \(width)x\(height) bitmap context")
        }
        return image
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        fatalError("Unable to create a PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Unable to write \(url.path)")
    }
}

// MARK: - Palette

let brandLight = rgba(0x2F6BF6)
let brandMid = rgba(0x1B55DF)
let brandDeep = rgba(0x0A47C9)

/// The launch background is the tone the icon reads as at a glance.
let launchBackground = rgba(0x1B55DF)

// MARK: - Background

func drawBackground(_ ctx: CGContext, in rect: CGRect) {
    ctx.saveGState()
    ctx.clip(to: rect)

    let diagonal = CGGradient(
        colorsSpace: sRGB,
        colors: [rgba(0x3E7BFF), brandLight, brandMid, brandDeep] as CFArray,
        locations: [0, 0.28, 0.68, 1]
    )!
    ctx.drawLinearGradient(
        diagonal,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // A very soft pool of light in the top-left corner keeps the flat fill alive.
    let glowCentre = CGPoint(
        x: rect.minX + rect.width * 0.16,
        y: rect.minY + rect.height * 0.88
    )
    let glow = CGGradient(
        colorsSpace: sRGB,
        colors: [rgba(0xFFFFFF, 0.16), rgba(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: glowCentre,
        startRadius: 0,
        endCenter: glowCentre,
        endRadius: rect.width * 0.78,
        options: []
    )

    // Inner highlight: a whisper of light along the top edge.
    let sheen = CGGradient(
        colorsSpace: sRGB,
        colors: [rgba(0xFFFFFF, 0.09), rgba(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.06),
        options: []
    )

    ctx.restoreGState()
}

// MARK: - Mark geometry

/// Two overlapping photo cards. The numbers describe the composition in a
/// 588 x 518 design box; everything else is derived from it.
struct MarkGeometry {
    let front: CGRect
    let back: CGRect
    let radius: CGFloat

    init(bbox: CGRect) {
        let designWidth: CGFloat = 588
        let designHeight: CGFloat = 518
        let scale = min(bbox.width / designWidth, bbox.height / designHeight)

        let cardWidth = 500 * scale
        let cardHeight = 430 * scale
        let offset = 88 * scale

        let originX = bbox.midX - (cardWidth + offset) / 2
        let originY = bbox.midY - (cardHeight + offset) / 2

        front = CGRect(x: originX, y: originY, width: cardWidth, height: cardHeight)
        back = front.offsetBy(dx: offset, dy: offset)
        radius = 104 * scale
    }

    /// A point expressed in card-relative coordinates (0...1 on each axis).
    func point(_ x: CGFloat, _ y: CGFloat, in card: CGRect) -> CGPoint {
        CGPoint(x: card.minX + x * card.width, y: card.minY + y * card.height)
    }

    /// The sun, sitting in the upper-left of the photo.
    var sun: CGRect {
        let centre = point(0.255, 0.655, in: front)
        let radius = 0.080 * front.width
        return CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    /// A quiet range of hills across the lower half of the photo.
    var mountains: CGPath {
        let peak = 0.034 * front.width
        return roundedPolygon(
            [
                point(0.115, 0.215, in: front),
                point(0.375, 0.415, in: front),
                point(0.510, 0.325, in: front),
                point(0.715, 0.525, in: front),
                point(0.945, 0.215, in: front),
            ],
            radii: [0.022 * front.width, peak * 1.35, peak, peak * 1.4, 0.022 * front.width]
        )
    }
}

/// A closed polygon with rounded corners, one radius per vertex.
func roundedPolygon(_ points: [CGPoint], radii: [CGFloat]) -> CGPath {
    precondition(points.count > 2 && points.count == radii.count)

    func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }

    let path = CGMutablePath()
    path.move(to: mid(points[points.count - 1], points[0]))
    for index in points.indices {
        path.addArc(
            tangent1End: points[index],
            tangent2End: points[(index + 1) % points.count],
            radius: radii[index]
        )
    }
    path.closeSubpath()
    return path
}

/// A continuous-corner squircle, the shape macOS expects for app icons.
func superellipse(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720

    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = rect.midX + (ct < 0 ? -1 : 1) * a * pow(abs(ct), 2 / exponent)
        let y = rect.midY + (st < 0 ? -1 : 1) * b * pow(abs(st), 2 / exponent)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - Mark

enum MarkFill {
    /// White cards on the gradient icon background.
    case white
    /// Gradient cards on a transparent background, for in-app use.
    case gradient
    /// Solid black alpha mask, for `renderingMode(.template)`.
    case monochrome
}

func paintCard(
    _ ctx: CGContext,
    path: CGPath,
    fill: MarkFill,
    alpha: CGFloat,
    gradientRect: CGRect
) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(path)

    switch fill {
    case .white:
        ctx.setFillColor(rgba(0xFFFFFF))
        ctx.fillPath()
    case .monochrome:
        ctx.setFillColor(rgba(0x000000))
        ctx.fillPath()
    case .gradient:
        ctx.clip()
        let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [rgba(0x4A84FF), brandLight, brandDeep] as CFArray,
            locations: [0, 0.4, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: gradientRect.minX, y: gradientRect.maxY),
            end: CGPoint(x: gradientRect.maxX, y: gradientRect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    ctx.restoreGState()
}

func drawMark(_ ctx: CGContext, bbox: CGRect, fill: MarkFill) {
    let geometry = MarkGeometry(bbox: bbox)

    let front = CGPath(
        roundedRect: geometry.front,
        cornerWidth: geometry.radius,
        cornerHeight: geometry.radius,
        transform: nil
    )
    let back = CGPath(
        roundedRect: geometry.back,
        cornerWidth: geometry.radius,
        cornerHeight: geometry.radius,
        transform: nil
    )

    paintCard(ctx, path: back, fill: fill, alpha: 0.55, gradientRect: bbox)
    paintCard(ctx, path: front, fill: fill, alpha: 1, gradientRect: bbox)

    // Punch the photo detail out of the front card only.
    ctx.saveGState()
    ctx.addPath(front)
    ctx.clip()
    ctx.setBlendMode(.destinationOut)
    ctx.setFillColor(rgba(0x000000))
    ctx.addPath(CGPath(ellipseIn: geometry.sun, transform: nil))
    ctx.fillPath()
    ctx.addPath(geometry.mountains)
    ctx.fillPath()
    ctx.restoreGState()
}

func renderMark(canvas: Int, bbox: CGRect, fill: MarkFill) -> CGImage {
    let bitmap = Bitmap(width: canvas, height: canvas, hasAlpha: true)
    drawMark(bitmap.context, bbox: bbox, fill: fill)
    return bitmap.image
}

// MARK: - Compositions

/// The mark is 62.5% of the shortest side, centred on the artwork.
func markBox(in rect: CGRect, height: CGFloat = 0.625) -> CGRect {
    let side = min(rect.width, rect.height) * height
    return CGRect(
        x: rect.midX - side / 2,
        y: rect.midY - side / 2,
        width: side,
        height: side
    )
}

func drawMarkWithShadow(_ ctx: CGContext, mark: CGImage, canvas: CGRect) {
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -canvas.height * 0.010),
        blur: canvas.height * 0.026,
        color: rgba(0x041A45, 0.24)
    )
    ctx.draw(mark, in: canvas)
    ctx.restoreGState()
}

/// Full-bleed square icon: iOS and iPadOS apply the mask themselves.
func renderIOSIcon(side: Int) -> CGImage {
    let bitmap = Bitmap(width: side, height: side, hasAlpha: false)
    let ctx = bitmap.context
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))

    drawBackground(ctx, in: canvas)

    let bbox = markBox(in: canvas)
    let mark = renderMark(canvas: side, bbox: bbox, fill: .white)
    drawMarkWithShadow(ctx, mark: mark, canvas: canvas)

    return bitmap.image
}

/// macOS: the classic padded squircle floating on a transparent canvas.
func renderMacIcon(side: Int) -> CGImage {
    let bitmap = Bitmap(width: side, height: side, hasAlpha: true)
    let ctx = bitmap.context
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))

    let tileSide = canvas.width * 0.804
    let tile = CGRect(
        x: canvas.midX - tileSide / 2,
        y: canvas.midY - tileSide / 2,
        width: tileSide,
        height: tileSide
    )
    let shape = superellipse(in: tile)

    // The shadow belongs to the tile, so it is cast by a filled copy of it.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -canvas.height * 0.009),
        blur: canvas.height * 0.020,
        color: rgba(0x000A1F, 0.34)
    )
    ctx.addPath(shape)
    ctx.setFillColor(brandDeep)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    drawBackground(ctx, in: tile)

    let bbox = markBox(in: tile, height: 0.60)
    let mark = renderMark(canvas: side, bbox: bbox, fill: .white)
    drawMarkWithShadow(ctx, mark: mark, canvas: canvas)

    ctx.restoreGState()

    // A hairline rim keeps the edge crisp against light and dark desktops.
    ctx.saveGState()
    ctx.addPath(superellipse(in: tile.insetBy(dx: canvas.width * 0.0015, dy: canvas.width * 0.0015)))
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.18))
    ctx.setLineWidth(max(1, canvas.width * 0.0022))
    ctx.strokePath()
    ctx.restoreGState()

    return bitmap.image
}

func renderBrandMark(side: Int) -> CGImage {
    let bitmap = Bitmap(width: side, height: side, hasAlpha: true)
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
    drawMark(bitmap.context, bbox: markBox(in: canvas, height: 0.90), fill: .gradient)
    return bitmap.image
}

func renderTemplate(side: Int) -> CGImage {
    let bitmap = Bitmap(width: side, height: side, hasAlpha: true)
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
    drawMark(bitmap.context, bbox: markBox(in: canvas, height: 0.90), fill: .monochrome)
    return bitmap.image
}

func scaled(_ image: CGImage, to side: Int, hasAlpha: Bool) -> CGImage {
    let bitmap = Bitmap(width: side, height: side, hasAlpha: hasAlpha)
    bitmap.context.interpolationQuality = .high
    bitmap.context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
    )
    return bitmap.image
}

// MARK: - Preview sheet

func drawLabel(
    _ string: String,
    in ctx: CGContext,
    centreX: CGFloat,
    baseline: CGFloat,
    size: CGFloat
) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .medium),
        .foregroundColor: NSColor(cgColor: rgba(0x5A5A66))!,
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: string, attributes: attributes)
    )
    let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
    ctx.saveGState()
    ctx.textPosition = CGPoint(
        x: centreX - bounds.width / 2 - bounds.minX,
        y: baseline
    )
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func renderPreview(ios: CGImage, mac: CGImage, brand: CGImage, template: CGImage) -> CGImage {
    let sizes = [1024, 180, 120, 60, 32]
    let pad: CGFloat = 48
    let gap: CGFloat = 56
    let surfaceSide: CGFloat = 248
    let itemSide: CGFloat = 200

    var width = pad * 2
    for (index, side) in sizes.enumerated() {
        width += CGFloat(side)
        if index < sizes.count - 1 { width += gap }
    }

    let extrasBottom: CGFloat = 88
    let ladderBaseline = extrasBottom + surfaceSide + 96
    let height = ladderBaseline + 1024 + pad

    let bitmap = Bitmap(width: Int(width), height: Int(height), hasAlpha: false)
    let ctx = bitmap.context

    ctx.setFillColor(rgba(0xEFEFF2))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high

    // The size ladder, bottom aligned on one baseline.
    var x = pad
    for side in sizes {
        let rect = CGRect(
            x: x,
            y: ladderBaseline,
            width: CGFloat(side),
            height: CGFloat(side)
        )
        ctx.draw(ios, in: rect)
        drawLabel("\(side)", in: ctx, centreX: rect.midX, baseline: ladderBaseline - 40, size: 28)
        x += CGFloat(side) + gap
    }

    // The macOS tile, the in-app mark and the tintable template.
    let surfaces: [(CGImage, CGColor, CGColor?)] = [
        (mac, rgba(0xE2E2E8), nil),
        (brand, rgba(0xFFFFFF), nil),
        (template, rgba(0xFFFFFF), rgba(0x2F6BF6)),
    ]
    let labels = ["macOS", "BrandMark", "BrandMarkTemplate"]

    x = pad
    for (index, surface) in surfaces.enumerated() {
        let frame = CGRect(x: x, y: extrasBottom, width: surfaceSide, height: surfaceSide)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.setFillColor(surface.1)
        ctx.fillPath()
        ctx.restoreGState()

        let rect = CGRect(
            x: frame.midX - itemSide / 2,
            y: frame.midY - itemSide / 2,
            width: itemSide,
            height: itemSide
        )
        if let tint = surface.2 {
            ctx.saveGState()
            ctx.clip(to: rect, mask: surface.0)
            ctx.setFillColor(tint)
            ctx.fill(rect)
            ctx.restoreGState()
        } else {
            ctx.draw(surface.0, in: rect)
        }

        drawLabel(labels[index], in: ctx, centreX: frame.midX, baseline: 44, size: 26)
        x += surfaceSide + gap
    }

    return bitmap.image
}

// MARK: - Asset catalog

func writeJSON(_ object: Any, to url: URL) {
    let data: Data
    do {
        data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    } catch {
        fatalError("Unable to encode \(url.lastPathComponent): \(error)")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("Unable to write \(url.path): \(error)")
    }
}

func colourComponents(_ hex: UInt32) -> [String: String] {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    func format(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }
    return ["alpha": "1.000", "blue": format(b), "green": format(g), "red": format(r)]
}

func coloursetJSON(light: UInt32, dark: UInt32) -> [String: Any] {
    [
        "colors": [
            [
                "color": [
                    "color-space": "srgb",
                    "components": colourComponents(light),
                ],
                "idiom": "universal",
            ],
            [
                "appearances": [["appearance": "luminosity", "value": "dark"]],
                "color": [
                    "color-space": "srgb",
                    "components": colourComponents(dark),
                ],
                "idiom": "universal",
            ],
        ],
        "info": ["author": "xcode", "version": 1],
    ]
}

// MARK: - Main

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL
    .deletingLastPathComponent()  // Icon
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // the repository

let assetsURL = repoRoot.appendingPathComponent("Sources/Resources/Assets.xcassets")
let iconSetURL = assetsURL.appendingPathComponent("AppIcon.appiconset")
let brandSetURL = assetsURL.appendingPathComponent("BrandMark.imageset")
let templateSetURL = assetsURL.appendingPathComponent("BrandMarkTemplate.imageset")
let accentURL = assetsURL.appendingPathComponent("AccentColor.colorset")
let launchURL = assetsURL.appendingPathComponent("LaunchBackground.colorset")

for directory in [assetsURL, iconSetURL, brandSetURL, templateSetURL, accentURL, launchURL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

let masterSide = 1024
let iosMaster = renderIOSIcon(side: masterSide)
let macMaster = renderMacIcon(side: masterSide)
let brandMaster = renderBrandMark(side: masterSide)
let templateMaster = renderTemplate(side: masterSide)

// iOS / iPadOS: a single 1024pt artwork, the compiler derives every device size.
writePNG(iosMaster, to: iconSetURL.appendingPathComponent("AppIcon-ios-1024.png"))

// macOS: the full 16/32/128/256/512 @1x/@2x ladder.
let macSides = [16, 32, 64, 128, 256, 512, 1024]
var macFiles: [Int: String] = [:]
for side in macSides {
    let name = "AppIcon-mac-\(side).png"
    let image = side == masterSide ? macMaster : scaled(macMaster, to: side, hasAlpha: true)
    writePNG(image, to: iconSetURL.appendingPathComponent(name))
    macFiles[side] = name
}

writePNG(brandMaster, to: brandSetURL.appendingPathComponent("BrandMark-1024.png"))
writePNG(
    scaled(brandMaster, to: 256, hasAlpha: true),
    to: brandSetURL.appendingPathComponent("BrandMark-256.png")
)

writePNG(templateMaster, to: templateSetURL.appendingPathComponent("BrandMarkTemplate-1024.png"))
writePNG(
    scaled(templateMaster, to: 256, hasAlpha: true),
    to: templateSetURL.appendingPathComponent("BrandMarkTemplate-256.png")
)

// MARK: Catalog manifests

writeJSON(
    ["info": ["author": "xcode", "version": 1]],
    to: assetsURL.appendingPathComponent("Contents.json")
)

var iconImages: [[String: String]] = [
    [
        "filename": "AppIcon-ios-1024.png",
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    ]
]

let macEntries: [(points: String, scale: String, pixels: Int)] = [
    ("16x16", "1x", 16),
    ("16x16", "2x", 32),
    ("32x32", "1x", 32),
    ("32x32", "2x", 64),
    ("128x128", "1x", 128),
    ("128x128", "2x", 256),
    ("256x256", "1x", 256),
    ("256x256", "2x", 512),
    ("512x512", "1x", 512),
    ("512x512", "2x", 1024),
]
for entry in macEntries {
    iconImages.append([
        "filename": macFiles[entry.pixels]!,
        "idiom": "mac",
        "scale": entry.scale,
        "size": entry.points,
    ])
}

writeJSON(
    ["images": iconImages, "info": ["author": "xcode", "version": 1]],
    to: iconSetURL.appendingPathComponent("Contents.json")
)

writeJSON(
    [
        "images": [
            ["filename": "BrandMark-1024.png", "idiom": "universal", "scale": "1x"],
            ["filename": "BrandMark-256.png", "idiom": "universal", "scale": "2x"],
        ],
        "info": ["author": "xcode", "version": 1],
    ],
    to: brandSetURL.appendingPathComponent("Contents.json")
)

writeJSON(
    [
        "images": [
            ["filename": "BrandMarkTemplate-1024.png", "idiom": "universal", "scale": "1x"],
            ["filename": "BrandMarkTemplate-256.png", "idiom": "universal", "scale": "2x"],
        ],
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ],
    to: templateSetURL.appendingPathComponent("Contents.json")
)

writeJSON(
    coloursetJSON(light: 0x2F6BF6, dark: 0x5B8CFF),
    to: accentURL.appendingPathComponent("Contents.json")
)
writeJSON(
    coloursetJSON(light: 0x1B55DF, dark: 0x0A47C9),
    to: launchURL.appendingPathComponent("Contents.json")
)

// MARK: Preview

let preview = renderPreview(
    ios: iosMaster,
    mac: macMaster,
    brand: brandMaster,
    template: templateMaster
)
writePNG(preview, to: repoRoot.appendingPathComponent("Tools/Icon/preview.png"))

print("Rendered icon assets into Sources/Resources/Assets.xcassets")
