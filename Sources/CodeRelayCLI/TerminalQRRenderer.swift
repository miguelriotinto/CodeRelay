import Foundation
#if canImport(CoreImage)
import CoreImage
#else
import QRCodeGenerator
#endif

/// Renders a QR code as terminal text using half-block glyphs.
///
/// On Apple platforms this uses CoreImage's `CIQRCodeGenerator`, a system
/// framework, so it adds no SPM dependency — the same generator the iOS and
/// macOS apps already use for session-sharing QR codes. It emits one pixel per
/// QR module, which we read back as a boolean matrix. Linux has no CoreImage;
/// there the matrix comes from `swift-qrcode-generator` (Nayuki's encoder in
/// pure Swift, a Linux-only dependency), at the same "M" correction level. The
/// two encoders may pick different masks for the same payload — both are valid
/// QR codes — and everything from the matrix down is shared.
///
/// Two details matter for scannability:
///
/// 1. **Quiet zone.** The QR spec requires a light margin; without it many
///    scanners will not lock on.
/// 2. **Explicit colours.** We emit 24-bit SGR foreground/background rather than
///    inheriting the terminal theme. On a dark theme the modules would otherwise
///    be inverted, and most scanners fail on an inverted QR — the most common
///    way terminal QR codes break.
struct TerminalQRRenderer {

    /// Light modules of margin added on every side.
    let quietZone: Int

    init(quietZone: Int = 2) {
        self.quietZone = quietZone
    }

    /// `true` = dark module. Includes the quiet zone.
    func matrix(for payload: String) -> [[Bool]]? {
        guard !payload.isEmpty, let modules = Self.modules(for: payload) else { return nil }
        let width = modules.count
        let side = width + quietZone * 2
        var result = [[Bool]](repeating: [Bool](repeating: false, count: side), count: side)
        for rowIndex in 0..<width {
            for colIndex in 0..<width {
                result[rowIndex + quietZone][colIndex + quietZone] = modules[rowIndex][colIndex]
            }
        }
        return result
    }

    #if canImport(CoreImage)
    /// The bare symbol (no quiet zone) from CoreImage, one pixel per module.
    private static func modules(for payload: String) -> [[Bool]]? {
        guard let data = payload.data(using: .isoLatin1),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let image = filter.outputImage else { return nil }
        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // Software renderer: deterministic, and no GPU context in a CLI.
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colourSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let bitmap = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colourSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard width == height else { return nil }
        var result = [[Bool]](repeating: [Bool](repeating: false, count: width), count: width)
        for rowIndex in 0..<height {
            for colIndex in 0..<width {
                // Dark module = low luminance.
                result[rowIndex][colIndex] = pixels[rowIndex * width + colIndex] < 128
            }
        }
        return result
    }
    #else
    /// The symbol from the pure-Swift encoder, wrapped in the same 1-module
    /// light border `CIQRCodeGenerator` puts around its output. That border is
    /// part of what the Mac ships — the printed code has `quietZone + 1` light
    /// modules each side — so it is reproduced here rather than treated as a
    /// CoreImage quirk: the matrix geometry, and therefore the rendered QR, is
    /// identical on both platforms and one set of tests covers both.
    private static func modules(for payload: String) -> [[Bool]]? {
        guard let code = try? QRCode.encode(text: payload, ecl: .medium) else { return nil }
        let size = code.size
        guard size > 0 else { return nil }
        let bordered = size + 2
        var result = [[Bool]](repeating: [Bool](repeating: false, count: bordered), count: bordered)
        for y in 0..<size {
            for x in 0..<size {
                result[y + 1][x + 1] = code.getModule(x: x, y: y)
            }
        }
        return result
    }
    #endif

    /// Renders the matrix as text, two module rows per line via half-blocks.
    func render(_ payload: String) -> String? {
        guard let matrix = matrix(for: payload) else { return nil }

        // Dark modules black, light modules white, regardless of theme.
        let dark = "\u{1B}[38;2;0;0;0m"
        let light = "\u{1B}[48;2;255;255;255m"
        let reset = "\u{1B}[0m"

        var out = ""
        var row = 0
        while row < matrix.count {
            let top = matrix[row]
            let bottom = row + 1 < matrix.count
                ? matrix[row + 1]
                : [Bool](repeating: false, count: matrix.count)

            out += light + dark
            for column in 0..<matrix.count {
                switch (top[column], bottom[column]) {
                case (true, true):   out += "\u{2588}"  // full block
                case (true, false):  out += "\u{2580}"  // upper half
                case (false, true):  out += "\u{2584}"  // lower half
                case (false, false): out += " "
                }
            }
            out += reset + "\n"
            row += 2
        }
        return out
    }
}
