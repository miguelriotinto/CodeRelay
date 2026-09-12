import SwiftUI
import CoreImage

struct QRCodePopover: View {
    let sessionId: UUID
    let sessionName: String?

    private var deepLink: String {
        "coderelay://session/\(sessionId.uuidString)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(sessionName ?? String(sessionId.uuidString.prefix(8)))
                .font(.headline)
            if let cgImage = generateQRCode() {
                Image(decorative: cgImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            } else {
                Text("Failed to generate QR code")
                    .foregroundStyle(.red)
            }
            Text(deepLink)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .frame(width: 260)
    }

    private static let ciContext = CIContext()

    private func generateQRCode() -> CGImage? {
        guard let data = deepLink.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 220.0 / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return Self.ciContext.createCGImage(scaled, from: scaled.extent)
    }
}
