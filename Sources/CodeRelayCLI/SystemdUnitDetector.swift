import Foundation

/// Which definition of `claude-relay.service` is in effect for the user.
enum SystemdUnitOwner: Equatable {
    /// `/usr/lib/systemd/user/claude-relay.service`, installed by the package.
    case packaged
    /// `~/.config/systemd/user/claude-relay.service`, written by `claude-relay load`.
    case user
    case none
}

/// Works out which systemd unit file owns the relay service so the CLI acts on
/// the right one — the Linux counterpart of `ServiceManagerDetector`.
///
/// There is one unit name and up to two files. Unlike the two launchd labels on
/// macOS, both files existing is **not** a hazard: systemd's unit search path
/// makes `~/.config/systemd/user/` shadow `/usr/lib/systemd/user/`, so at most
/// one definition is active and one process binds the port. What the CLI must
/// get right instead is *whose file it is*: `unload` may delete a unit `load`
/// wrote, never the package's, and on a packaged install `load` enables the
/// packaged unit rather than writing a shadowing copy.
///
/// | Origin                | Unit path                                      |
/// | --------------------- | ---------------------------------------------- |
/// | package (PKGBUILD)    | `/usr/lib/systemd/user/claude-relay.service`   |
/// | `claude-relay load`   | `~/.config/systemd/user/claude-relay.service`  |
struct SystemdUnitDetector: Equatable {

    static let unitName = "claude-relay.service"
    static let packagedUnitPath = "/usr/lib/systemd/user/\(unitName)"
    /// Marker `load` writes into its unit so `unload` can tell it apart from a
    /// unit the operator authored by hand at the same path.
    static let cliMarker = "# Installed by `claude-relay load`"

    static var userUnitDirectory: String {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return "\(configHome)/systemd/user"
    }
    static var userUnitPath: String { "\(userUnitDirectory)/\(unitName)" }

    let packagedUnitExists: Bool
    let userUnitExists: Bool
    /// True when the user unit carries `cliMarker`. Meaningless if it does not exist.
    let userUnitWrittenByCLI: Bool

    init(packagedUnitExists: Bool, userUnitExists: Bool, userUnitWrittenByCLI: Bool) {
        self.packagedUnitExists = packagedUnitExists
        self.userUnitExists = userUnitExists
        self.userUnitWrittenByCLI = userUnitWrittenByCLI
    }

    /// Reads the real filesystem. Injected values are used by tests.
    static func detect() -> SystemdUnitDetector {
        let fm = FileManager.default
        let userExists = fm.fileExists(atPath: userUnitPath)
        let marked = userExists
            && ((try? String(contentsOfFile: userUnitPath, encoding: .utf8))?.contains(cliMarker) ?? false)
        return SystemdUnitDetector(
            packagedUnitExists: fm.fileExists(atPath: packagedUnitPath),
            userUnitExists: userExists,
            userUnitWrittenByCLI: marked)
    }

    /// The definition systemd will use: the user file shadows the packaged one.
    var owner: SystemdUnitOwner {
        if userUnitExists { return .user }
        if packagedUnitExists { return .packaged }
        return .none
    }

    /// True when a user unit is hiding the packaged one — worth a line in
    /// `status`, since the operator may not expect an upgrade of the package to
    /// have no effect.
    var packagedUnitShadowed: Bool { userUnitExists && packagedUnitExists }

    var activeUnitPath: String? {
        switch owner {
        case .user:     return Self.userUnitPath
        case .packaged: return Self.packagedUnitPath
        case .none:     return nil
        }
    }

    /// A message to print instead of acting, or nil when `verb` is right.
    func nudge(for verb: ServiceVerb) -> String? {
        switch owner {
        case .user, .packaged:
            // Every verb is valid: `load` on a packaged install enables the
            // packaged unit rather than shadowing it (SystemdService.load), and
            // `unload` on one disables it while leaving the package's file.
            return nil

        case .none:
            switch verb {
            case .load:
                return nil
            case .unload:
                return "No service is installed — nothing to unload."
            case .start, .stop, .restart:
                return """
                No service is installed yet, so there is nothing to \(verb.rawValue).
                Install and start it with:
                  claude-relay setup
                """
            }
        }
    }
}
