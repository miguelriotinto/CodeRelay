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

/// Uses NSViewControllerRepresentable (mirrors the working iOS UIViewController pattern).
private struct QRScannerRepresentable: NSViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeNSViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        vc.onError = onError
        return vc
    }

    func updateNSViewController(_ nsViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: NSViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        checkAuthorizationAndSetup()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        captureSession?.stopRunning()
    }

    private func checkAuthorizationAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.onError?("Camera access denied. Grant permission in System Settings → Privacy & Security → Camera.")
                    }
                }
            }
        case .denied, .restricted:
            onError?("Camera access denied. Grant permission in System Settings → Privacy & Security → Camera.")
        @unknown default:
            onError?("Unable to access camera.")
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("No camera available.")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(metadataOutput) { session.addOutput(metadataOutput) }
            session.commitConfiguration()
        } catch {
            onError?("Camera setup failed: \(error.localizedDescription)")
            return
        }

        guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
            onError?("QR code scanning is not supported on this device.")
            return
        }
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer?.addSublayer(layer)
        previewLayer = layer
        captureSession = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasScanned,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }
        hasScanned = true
        captureSession?.stopRunning()
        onScan?(value)
    }
}
