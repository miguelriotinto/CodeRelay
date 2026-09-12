import Foundation
import AppKit
import UniformTypeIdentifiers

enum ImagePasteHandler {

    /// Returns image PNG data from the system pasteboard, or nil if clipboard has no image.
    static func extractFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Data? {
        // Try PNG first
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }
        // Fall back to TIFF and convert
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return pngData
        }
        // Try an NSImage — covers JPEG, HEIC, and file URLs to images.
        if let image = NSImage(pasteboard: pasteboard),
           let tiffRep = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffRep),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return pngData
        }
        return nil
    }

    /// Converts arbitrary image data (JPEG, TIFF, HEIC, PNG) to PNG.
    /// Returns nil if the data isn't a decodable image.
    static func convertToPNG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffRep = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffRep),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    /// Loads and converts an image file at the given URL to PNG data.
    static func convertFileToPNG(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return convertToPNG(data)
    }
}
