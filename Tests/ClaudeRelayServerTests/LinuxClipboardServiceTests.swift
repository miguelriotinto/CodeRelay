#if os(Linux)
import XCTest
import Foundation
@testable import ClaudeRelayServer

/// `LinuxClipboardService` tool selection and environment handling, through
/// its `Runner` seam — no compositor needed (`docs/linux-server-spec.md` AD-5).
final class LinuxClipboardServiceTests: XCTestCase {

    /// Records every invocation; `available` names the binaries `exists` reports.
    private final class Recorder: @unchecked Sendable {
        var calls: [(command: [String], stdin: Data, environment: [String: String])] = []
        var available: Set<String>
        var result = true
        init(available: Set<String>) { self.available = available }

        var runner: LinuxClipboardService.Runner {
            LinuxClipboardService.Runner(
                run: { [self] command, stdin, env in
                    calls.append((command, stdin, env)); return result
                },
                exists: { [self] binary in available.contains(binary) })
        }
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testUsesWlCopyWithImageTypeOnStdinUnderWayland() {
        let recorder = Recorder(available: ["wl-copy", "xclip"])
        let service = LinuxClipboardService(
            runner: recorder.runner,
            environment: ["WAYLAND_DISPLAY": "wayland-1", "XDG_RUNTIME_DIR": "/run/user/1000"])

        XCTAssertTrue(service.pasteImage(png))
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].command, ["wl-copy", "--type", "image/png"])
        XCTAssertEqual(recorder.calls[0].stdin, png, "bytes travel on stdin, never argv")
        XCTAssertEqual(recorder.calls[0].environment["WAYLAND_DISPLAY"], "wayland-1")
    }

    func testProbesTheRuntimeDirectoryWhenWaylandDisplayIsUnset() throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdg-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        FileManager.default.createFile(atPath: runtime.appendingPathComponent("wayland-0").path, contents: nil)

        let recorder = Recorder(available: ["wl-copy"])
        let service = LinuxClipboardService(
            runner: recorder.runner,
            environment: ["XDG_RUNTIME_DIR": runtime.path])

        XCTAssertTrue(service.pasteImage(png))
        XCTAssertEqual(recorder.calls[0].environment["WAYLAND_DISPLAY"], "wayland-0",
                       "a systemd user service inherits no WAYLAND_DISPLAY; the socket is found by name")
    }

    func testPrefersWaylandOneOverWaylandZeroWhenBothSocketsExist() throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdg-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        for name in ["wayland-0", "wayland-1"] {
            FileManager.default.createFile(atPath: runtime.appendingPathComponent(name).path, contents: nil)
        }
        let service = LinuxClipboardService(
            runner: Recorder(available: ["wl-copy"]).runner,
            environment: ["XDG_RUNTIME_DIR": runtime.path])
        XCTAssertEqual(service.waylandEnvironment()?["WAYLAND_DISPLAY"], "wayland-1")
    }

    func testFallsBackToXclipUnderX11() {
        let recorder = Recorder(available: ["xclip"])
        let service = LinuxClipboardService(
            runner: recorder.runner,
            environment: ["DISPLAY": ":0"])

        XCTAssertTrue(service.pasteImage(png))
        XCTAssertEqual(recorder.calls[0].command, ["xclip", "-selection", "clipboard", "-t", "image/png", "-i"])
        XCTAssertEqual(recorder.calls[0].stdin, png)
    }

    func testReturnsFalseWithNoDisplayAtAll() {
        let recorder = Recorder(available: ["wl-copy", "xclip"])
        let service = LinuxClipboardService(runner: recorder.runner, environment: [:])
        XCTAssertFalse(service.pasteImage(png))
        XCTAssertTrue(recorder.calls.isEmpty, "nothing is run when no display is reachable")
    }

    func testReturnsFalseWhenTheToolIsMissing() {
        let recorder = Recorder(available: [])
        let service = LinuxClipboardService(
            runner: recorder.runner,
            environment: ["WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":0"])
        XCTAssertFalse(service.pasteImage(png))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testReportsTheToolsExitStatus() {
        let recorder = Recorder(available: ["wl-copy"])
        recorder.result = false
        let service = LinuxClipboardService(
            runner: recorder.runner,
            environment: ["WAYLAND_DISPLAY": "wayland-1"])
        XCTAssertFalse(service.pasteImage(png), "a failed wl-copy is a failed paste, surfaced to the device")
    }

    func testDefaultServiceIsTheLinuxOne() {
        XCTAssertTrue(DefaultClipboardService.make() is LinuxClipboardService)
    }
}
#endif
