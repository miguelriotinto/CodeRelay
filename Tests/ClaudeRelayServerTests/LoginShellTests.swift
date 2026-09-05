import XCTest
@testable import ClaudeRelayServer

/// `LoginShell.choose` — the shell `PTYSession` execs on Linux and the login
/// identity it establishes (`docs/linux-server-spec.md` AD-3). Pure, so the
/// fallback order is pinned without touching the passwd database.
final class LoginShellTests: XCTestCase {

    private func exists(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    func testPasswdShellWinsWhenExecutable() {
        let shell = LoginShell.choose(
            pwShell: "/usr/bin/zsh", envShell: "/bin/bash", userName: "miguel",
            isExecutable: exists(["/usr/bin/zsh", "/bin/bash"]))
        XCTAssertEqual(shell.path, "/usr/bin/zsh")
        XCTAssertEqual(shell.argv0, "-zsh", "login-shell marker so the profile runs")
        XCTAssertEqual(shell.userName, "miguel")
    }

    func testFallsBackToEnvShellWhenPasswdShellIsMissing() {
        let shell = LoginShell.choose(
            pwShell: "/usr/bin/fish", envShell: "/bin/bash", userName: "u",
            isExecutable: exists(["/bin/bash"]))
        XCTAssertEqual(shell.path, "/bin/bash")
        XCTAssertEqual(shell.argv0, "-bash")
    }

    func testSkipsNologinAndFalseEvenThoughTheyExist() {
        let shell = LoginShell.choose(
            pwShell: "/usr/bin/nologin", envShell: "/bin/false", userName: "u",
            isExecutable: exists(["/usr/bin/nologin", "/bin/false", "/bin/sh"]))
        XCTAssertEqual(shell.path, "/bin/sh")
        XCTAssertEqual(shell.argv0, "-sh")
    }

    func testPrefersBashOverShWhenNeitherSourceIsSet() {
        let shell = LoginShell.choose(
            pwShell: nil, envShell: nil, userName: "u",
            isExecutable: exists(["/bin/bash", "/bin/sh"]))
        XCTAssertEqual(shell.path, "/bin/bash")
    }

    func testEmptyStringsAreNotCandidates() {
        let shell = LoginShell.choose(
            pwShell: "", envShell: "", userName: "u",
            isExecutable: { _ in true })
        XCTAssertEqual(shell.path, "/bin/bash")
    }

    func testLastResortIsShEvenIfNothingIsExecutable() {
        let shell = LoginShell.choose(pwShell: nil, envShell: nil, userName: "u", isExecutable: { _ in false })
        XCTAssertEqual(shell.path, "/bin/sh")
        XCTAssertEqual(shell.argv0, "-sh")
    }

    func testResolveOnThisHostReturnsAnExecutableShell() {
        let shell = LoginShell.resolve()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell.path), shell.path)
        XCTAssertTrue(shell.argv0.hasPrefix("-"))
        XCTAssertFalse(shell.userName.isEmpty)
    }
}
