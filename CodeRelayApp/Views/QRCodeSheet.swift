import SwiftUI
import CoreImage

struct QRCodeSheet: View {
    let sessionId: UUID
    let sessionName: String?
    @Environment(\.dismiss) private var dismiss

    private var deepLink: String {
        "coderelay://session/\(sessionId.uuidString)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(sessionName ?? String(sessionId.uuidString.prefix(8)))
                    .font(.headline)

                if let cgImage = generateQRCode() {
                    Image(decorative: cgImage, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 280, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ContentUnavailableView(
                        "QR Code Unavailable",
                        systemImage: "qrcode",
                        description: Text("Could not generate QR code.")
                    )
                }

                Text(deepLink)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)

                Text("Scan this code from another device to attach to this session.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.vertical, 24)
            .navigationTitle("Share Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private static let ciContext = CIContext()

    private func generateQRCode() -> CGImage? {
        guard let data = deepLink.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 280.0 / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return Self.ciContext.createCGImage(scaled, from: scaled.extent)
    }
}
