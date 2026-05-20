import SwiftUI
import AVFoundation
import AppKit

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: SessionCoordinator
    var onAttachSuccess: (() -> Void)?
    @State private var errorMessage: String?
    @State private var scannedValue: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Scan QR Code")
                .font(.headline)
                .padding()

            if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QRScannerRepresentable(onScan: handleScan, onError: handleError)
                    .frame(width: 480, height: 360)
                    .background(.black)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }

    private func handleScan(_ value: String) {
        guard scannedValue == nil else { return }
        scannedValue = value
        if let url = URL(string: value), url.scheme == "clauderelay",
           url.host == "session",
           let uuidString = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: uuidString) {
            Task {
                await coordinator.attachRemoteSession(id: uuid)
                dismiss()
                onAttachSuccess?()
            }
        } else {
            errorMessage = "Invalid QR code format."
        }
    }

    private func handleError(_ error: String) {
        errorMessage = error
    }
}

/// AVFoundation QR scanner wrapped in NSViewRepresentable.
private struct QRScannerRepresentable: NSViewRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            context.coordinator.setupSession(in: containerView)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        context.coordinator.setupSession(in: containerView)
                    } else {
                        context.coordinator.onError("Camera access denied. Grant permission in System Settings → Privacy & Security → Camera.")
                    }
                }
            }
        case .denied, .restricted:
            onError("Camera access denied. Grant permission in System Settings → Privacy & Security → Camera.")
        @unknown default:
            onError("Unable to access camera.")
        }

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.previewLayer?.frame = nsView.bounds
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onError: (String) -> Void
        var session: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func setupSession(in containerView: NSView) {
            let session = AVCaptureSession()
            self.session = session

            guard let device = AVCaptureDevice.default(for: .video) else {
                onError("No camera available.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }

                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) { session.addOutput(output) }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            } catch {
                onError("Camera setup failed: \(error.localizedDescription)")
                return
            }

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = containerView.bounds
            containerView.layer?.addSublayer(previewLayer)
            self.previewLayer = previewLayer

            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            session?.stopRunning()
            onScan(value)
        }
    }
}
