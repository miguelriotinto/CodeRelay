// Rasterises an SVG with AppKit (NSImage reads SVG on macOS 14+).
// render <in.svg> <out.png> <pixels> [opaque]
import AppKit
let a = CommandLine.arguments
let n = Int(a[3])!, opaque = a.count > 4
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("cannot load \(a[1])") }
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
ctx.interpolationQuality = .high
if opaque { ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n)) }
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
img.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current = nil
let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil); CGImageDestinationFinalize(dest)
