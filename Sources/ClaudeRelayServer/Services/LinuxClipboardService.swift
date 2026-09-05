#if os(Linux)
import Foundation
import ClaudeRelayKit

/// Host clipboard for the Linux server: device → host image paste lands in the
/// compositor's CLIPBOARD selection.
///
/// There is no clipboard API on Linux, only the display server's selection
/// protocol, and the tool every native app shells out to is `wl-clipboard`
/// (`wl-copy`) under Wayland or `xclip` under X11. This mirrors the Linux
/// client's `DesktopClipboard`: image bytes go to the tool on **stdin**, never
/// argv — `/proc/<pid>/cmdline` is world-readable and the clipboard is the
/// user's data.
///
/// The server usually runs as a systemd *user* service, whose environment is
/// not a login shell's: `WAYLAND_DISPLAY` is only present if the session
/// imported it into the user manager (uwsm and Omarchy's Hyprland session do).
/// When it is missing, the compositor socket is found by probing
/// `$XDG_RUNTIME_DIR/wayland-N` so a paste still works without the operator
/// hand-editing the unit. `pasteImage` returns `false` — surfaced to the device
/// as `paste_image_result{success:false}` — when no tool or no display is
/// reachable, exactly as a failed `NSPasteboard` write would.
public struct LinuxClipboardService: ClipboardService {

    /// Seam for tests. Production runs real processes.
    public struct Runner: Sendable {
        /// Runs `command` with `stdin`; true on exit 0.
        public var run: @Sendable (_ command: [String], _ stdin: Data, _ environment: [String: String]) -> Bool
        /// Whether `binary` resolves on `PATH`.
        public var exists: @Sendable (_ binary: String) -> Bool

        public init(
            run: @escaping @Sendable ([String], Data, [String: String]) -> Bool,
            exists: @escaping @Sendable (String) -> Bool
        ) {
            self.run = run
            self.exists = exists
        }

        public static let process = Runner(run: Self.runProcess, exists: Self.binaryExists)

        @Sendable private static func runProcess(
            _ command: [String], _ stdin: Data, _ environment: [String: String]
        ) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            // `wl-copy` forks a child that keeps serving the selection and the
            // parent exits once it has read stdin, so this returns promptly.
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        @Sendable private static func binaryExists(_ binary: String) -> Bool {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            return path.split(separator: ":").contains { dir in
                FileManager.default.isExecutableFile(atPath: "\(dir)/\(binary)")
            }
        }
    }

    private let runner: Runner
    private let environment: [String: String]

    public init(
        runner: Runner = .process,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.environment = environment
    }

    public func pasteImage(_ imageData: Data) -> Bool {
        if let env = waylandEnvironment(), runner.exists("wl-copy") {
            return runner.run(["wl-copy", "--type", "image/png"], imageData, env)
        }
        if let display = environment["DISPLAY"], !display.isEmpty, runner.exists("xclip") {
            return runner.run(
                ["xclip", "-selection", "clipboard", "-t", "image/png", "-i"],
                imageData, environment)
        }
        return false
    }

    /// The environment `wl-copy` needs, or nil when no Wayland compositor is
    /// reachable. Prefers the inherited `WAYLAND_DISPLAY`; otherwise probes the
    /// runtime directory for the conventional socket names.
    func waylandEnvironment() -> [String: String]? {
        if let display = environment["WAYLAND_DISPLAY"], !display.isEmpty {
            return environment
        }
        guard let runtimeDir = environment["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty else {
            return nil
        }
        for candidate in ["wayland-1", "wayland-0"] {
            if FileManager.default.fileExists(atPath: "\(runtimeDir)/\(candidate)") {
                var env = environment
                env["WAYLAND_DISPLAY"] = candidate
                return env
            }
        }
        return nil
    }
}
#endif
