import SwiftUI
import CoreImage
import UIKit

// MARK: - QR Code Generation

struct QRCodeGenerator {
    private static let context = CIContext()

    static func generate(from string: String, size: CGFloat = 200) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / ciImage.extent.size.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - QR Code Overlay

struct QRCodeOverlay: View {
    let sessionId: UUID
    let sessionName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 16) {
                if let image = QRCodeGenerator.generate(
                    from: "coderelay://session/\(sessionId.uuidString)",
                    size: 200
                ) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(sessionName)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}
