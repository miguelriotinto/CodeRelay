import Foundation

/// Diagnostics that must not land on stdout.
///
/// Any command that can fail while `--json` is in effect has to route its
/// message here: a human-readable line written to stdout sits in the middle of
/// the JSON a caller is piping into a parser, so the failure corrupts the
/// success format instead of staying out of its way. Errors on stderr also
/// survive `> out.json` redirection, which is where an operator actually needs
/// to see them.
///
/// Matches the convention `ConfigCommands` already uses.
enum CLIOutput {

    /// Writes one diagnostic line to stderr.
    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Writes one progress line to stderr.
    ///
    /// Progress narration is not the command's result, so it belongs on the
    /// same channel as errors: `setup --json` may print "Starting via Homebrew
    /// services…" before it knows whether it has a pairing code to report, and
    /// that line must not end up inside the JSON a caller is parsing.
    static func note(_ message: String) {
        error(message)
    }
}
