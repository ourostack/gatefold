// Composes the App Store screenshots from raw simulator captures and screenshots/spec.json.
//
//     swift scripts/screenshots/compose.swift <spec.json> <device> <raw dir> <out dir>
//
// One opaque PNG per scene, at the device's canvas size: a paper or ink ground, a ribbon bookmark, a two-line
// headline (New York, the second line in Inkwell), a subline (SF) and the capture in a drawn device. CoreGraphics and
// CoreText only, no browser and no randomness, so the same inputs on the same runner image give the same bytes.
import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    let top: CGColor, bottom: CGColor, ink: CGColor, sub: CGColor, accent: CGColor, edge: CGColor?
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Build 14's calm look: white by day, Midnight black by night, Inkwell blue as the one accent.
let palettes: [String: Palette] = [
    "paper": Palette(top: rgb(0xFFFFFF), bottom: rgb(0xF2F2F5), ink: rgb(0x1D1D1F), sub: rgb(0x6E6E73),
                     accent: rgb(0x2F5D8A), edge: nil),
    "ink": Palette(top: rgb(0x1C1C1E), bottom: rgb(0x000000), ink: rgb(0xF5F5F7), sub: rgb(0x98989D),
                   accent: rgb(0x7FA6D6), edge: rgb(0x3A3A3C)),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("compose: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(path)") }
    return img
}

func font(serif: Bool, size: CGFloat, weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let desc = serif ? (base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor) : base.fontDescriptor
    return CTFontCreateWithFontDescriptor(desc as CTFontDescriptor, size, nil)
}

func line(_ text: String, _ f: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
}

func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

/// Draws `text` centred, wrapped to `maxWidth`, with its first baseline `top` below the canvas top. Returns the bottom.
func paragraph(_ ctx: CGContext, _ text: String, _ f: CTFont, _ color: CGColor, centerX: CGFloat, top: CGFloat,
               maxWidth: CGFloat, canvasH: CGFloat, leading: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        .paragraphStyle: style,
    ]
    let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let path = CGPath(rect: CGRect(x: centerX - maxWidth / 2, y: 0, width: maxWidth, height: 10_000), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var y = top
    for l in lines {
        let w = width(l)
        ctx.textPosition = CGPoint(x: centerX - w / 2, y: canvasH - y)
        CTLineDraw(l, ctx)
        y += leading
    }
    return y - leading
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The capture, turned to the scene's orientation: a landscape scene shot by a portrait framebuffer is rotated.
func oriented(_ img: CGImage, landscape: Bool) -> CGImage {
    let isLandscape = img.width > img.height
    guard landscape != isLandscape else { return img }
    let w = img.height, h = img.width
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fail("no context") }
    // A quarter turn counterclockwise (CoreGraphics' y axis points up): right for landscapeLeft, home side on the right.
    ctx.translateBy(x: CGFloat(w), y: 0)
    ctx.rotate(by: .pi / 2)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage()!
}

func compose(scene: [String: Any], device: [String: Any], raw: String, out: String) {
    let id = scene["id"] as! String
    let canvas = device["canvas"] as! [Int]
    let kind = device["kind"] as! String
    let W = CGFloat(canvas[0]), H = CGFloat(canvas[1])
    // Design unit: one point of the iPhone canvas. The iPad's wider canvas takes its type a little smaller.
    let u = W / 1206 * (kind == "ipad" ? 0.86 : 1)
    let pal = palettes[scene["bg"] as? String ?? "paper"]!
    let landscape = scene["orientation"] as? String == "landscape"
    let shot = oriented(loadImage("\(raw)/\(id).png"), landscape: landscape)

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: canvas[0], height: canvas[1], bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fail("no context") }
    ctx.setShouldSmoothFonts(false)
    ctx.interpolationQuality = .high

    // Ground.
    let ground = CGGradient(colorsSpace: space, colors: [pal.top, pal.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

    // The ribbon bookmark, hanging from the top edge.
    let rw = 46 * u, rh = 104 * u, notch = 22 * u
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: W / 2 - rw / 2, y: H))
    ribbon.addLine(to: CGPoint(x: W / 2 + rw / 2, y: H))
    ribbon.addLine(to: CGPoint(x: W / 2 + rw / 2, y: H - rh))
    ribbon.addLine(to: CGPoint(x: W / 2, y: H - rh + notch))
    ribbon.addLine(to: CGPoint(x: W / 2 - rw / 2, y: H - rh))
    ribbon.closeSubpath()
    ctx.addPath(ribbon)
    ctx.setFillColor(pal.accent)
    ctx.fillPath()

    // Headline: two lines, shrunk together until both fit.
    let headline = scene["headline"] as! [String]
    var size = 96 * u
    var l1 = line(headline[0], font(serif: true, size: size, weight: .bold), pal.ink, kern: -0.6 * u)
    var l2 = line(headline[1], font(serif: true, size: size, weight: .bold), pal.accent, kern: -0.6 * u)
    while max(width(l1), width(l2)) > W * 0.88 && size > 40 * u {
        size -= 2 * u
        l1 = line(headline[0], font(serif: true, size: size, weight: .bold), pal.ink, kern: -0.6 * u)
        l2 = line(headline[1], font(serif: true, size: size, weight: .bold), pal.accent, kern: -0.6 * u)
    }
    let first = 132 * u + rh * 0.55 + size * 0.8
    ctx.textPosition = CGPoint(x: (W - width(l1)) / 2, y: H - first)
    CTLineDraw(l1, ctx)
    ctx.textPosition = CGPoint(x: (W - width(l2)) / 2, y: H - first - size * 1.08)
    CTLineDraw(l2, ctx)

    let subSize = 40 * u
    let textBottom = paragraph(ctx, scene["subline"] as! String, font(serif: false, size: subSize, weight: .regular),
                               pal.sub, centerX: W / 2, top: first + size * 1.08 + 64 * u, maxWidth: W * 0.80,
                               canvasH: H, leading: subSize * 1.3)

    // The device: a drawn bezel around the capture. Portrait devices bleed off the bottom edge.
    let aspect = CGFloat(shot.height) / CGFloat(shot.width)
    let devW: CGFloat, radiusFactor: CGFloat, bezelFactor: CGFloat
    switch (kind, landscape) {
    case ("ipad", true): devW = W * 0.90; radiusFactor = 0.035; bezelFactor = 0.016
    case ("ipad", false): devW = W * 0.80; radiusFactor = 0.045; bezelFactor = 0.020
    case ("duo-outer", _): devW = W * 0.78; radiusFactor = 0.070; bezelFactor = 0.028
    default: devW = W * 0.80; radiusFactor = 0.125; bezelFactor = 0.030
    }
    let bezel = devW * bezelFactor
    let screenW = devW - 2 * bezel, screenH = screenW * aspect
    let devH = screenH + 2 * bezel
    let devTop = textBottom + 96 * u
    // A landscape device sits centred in the space under the text; a portrait one hangs from it and bleeds off.
    let devY = landscape ? (H - devTop - devH) / 2 : H - devTop - devH
    let body = CGRect(x: (W - devW) / 2, y: devY, width: devW, height: devH)
    let outerR = devW * radiusFactor
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * u), blur: 80 * u, color: rgb(0x000000, 0.22))
    ctx.addPath(roundedRect(body, outerR))
    ctx.setFillColor(rgb(0x0B0B0C))
    ctx.fillPath()
    ctx.restoreGState()
    if let edge = pal.edge {
        ctx.addPath(roundedRect(body.insetBy(dx: u, dy: u), outerR))
        ctx.setStrokeColor(edge)
        ctx.setLineWidth(2 * u)
        ctx.strokePath()
    }
    let screen = body.insetBy(dx: bezel, dy: bezel)
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, max(outerR - bezel, 0)))
    ctx.clip()
    ctx.draw(shot, in: screen)
    ctx.restoreGState()
    if kind == "iphone" {
        // The Dynamic Island, where the phone has it (the simulator's capture leaves it out).
        let iw = screen.width * 0.31, ih = screen.width * 0.092
        let island = CGRect(x: screen.midX - iw / 2, y: screen.maxY - screen.width * 0.028 - ih, width: iw, height: ih)
        ctx.addPath(roundedRect(island, ih / 2))
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
    }

    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: "\(out)/\(id).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot finish \(url.path)") }
    print("\(id): \(canvas[0])x\(canvas[1])")
}

let args = CommandLine.arguments
guard args.count == 5 else { fail("usage: compose.swift <spec.json> <device> <raw dir> <out dir>") }
let spec = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let devices = spec["devices"] as! [String: [String: Any]]
guard let device = devices[args[2]] else { fail("no device \(args[2]) in the spec") }
try! FileManager.default.createDirectory(atPath: args[4], withIntermediateDirectories: true)
for scene in spec["scenes"] as! [[String: Any]] where (scene["devices"] as! [String]).contains(args[2]) {
    compose(scene: scene, device: device, raw: args[3], out: args[4])
}
