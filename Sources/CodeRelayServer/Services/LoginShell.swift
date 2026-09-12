import Foundation

/// What `PTYSession` execs in the child: the account's login shell and the
/// identity `login(1)` would have established for it.
///
/// Resolved in the **parent**, before `forkpty`, because `getpwuid` may allocate
/// and consult NSS — neither is safe between fork and exec. The child receives
/// only the resulting C strings.
///
/// On macOS the shell is spawned through `login -fp`, which picks the account
/// shell itself; only `userName` is consumed there. On Linux `login` requires
/// root, so the server execs `path` directly with `argv0` — the `-`-prefixed
/// basename that makes a shell run its login profile.
struct LoginShell: Equatable {
    let path: String
    let argv0: String
    let userName: String

    /// The current process's account, from the environment first (as
    /// `login -fp` honoured `$USER`) and the passwd database second.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> LoginShell {
        var pwShell: String?
        var pwName: String?
        if let entry = getpwuid(getuid()) {
            if let shell = entry.pointee.pw_shell { pwShell = String(cString: shell) }
            if let name = entry.pointee.pw_name { pwName = String(cString: name) }
        }
        return choose(
            pwShell: pwShell,
            envShell: environment["SHELL"],
            userName: environment["USER"] ?? pwName ?? "unknown",
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Pure selection, so the fallback order is unit-testable: the passwd shell,
    /// then `$SHELL`, then bash, then sh — the first that actually exists and
    /// is executable. A passwd entry can name a shell that was uninstalled, and
    /// `nologin` is a real shell path that must be skipped rather than trusted.
    static func choose(
        pwShell: String?,
        envShell: String?,
        userName: String,
        isExecutable: (String) -> Bool
    ) -> LoginShell {
        let candidates = [pwShell, envShell, "/bin/bash", "/usr/bin/bash", "/bin/sh"]
        let path = candidates
            .compactMap { $0 }
            .filter { !$0.isEmpty && !$0.hasSuffix("/nologin") && !$0.hasSuffix("/false") }
            .first(where: isExecutable) ?? "/bin/sh"
        let basename = path.split(separator: "/").last.map(String.init) ?? "sh"
        return LoginShell(path: path, argv0: "-" + basename, userName: userName)
    }
}
