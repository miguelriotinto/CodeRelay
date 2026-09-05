import XCTest
import Foundation
import CPTYShim
@testable import ClaudeRelayServer

/// Guards the PTY master fd against being inherited across `exec`.
///
/// `forkpty` closes the master in the child it forks, so a session's own shell
/// never holds its own master. What it cannot know about is every master created
/// *before* it: those live in the server's fd table, and without `FD_CLOEXEC`
/// each one survives the `execv("/usr/bin/login", …)` in `PTYSession.init`.
/// Session N's shell therefore inherits N−1 masters.
///
/// Two failures fall out of that one missing flag, which is why it earns a test
/// rather than a comment:
///
/// - **PTY exhaustion.** The server closing its master does not free the kernel
///   pty pair while another session's shell still references it. `ptmx` is a
///   fixed pool (`kern.tty.ptmx_max`, 511 by default), so a long-lived server
///   that churns sessions eventually cannot fork one at all.
/// - **Process leak.** The shell on a leaked pty never observes its master
///   close, so it never receives EOF/SIGHUP and never exits — it outlives even
///   the server that spawned it, reparenting to launchd. Measured on the dev
///   machine before the fix: 38 orphaned `login -fp` processes, 28 already
///   reparented to pid 1 by earlier server restarts.
final class PTYMasterFDInheritanceTests: XCTestCase {

    private var sessions: [PTYSession] = []

    override func tearDown() async throws {
        for session in sessions {
            await session.terminate()
        }
        sessions = []
    }

    private func makeSession() throws -> PTYSession {
        let session = try PTYSession(sessionId: UUID(), cols: 80, rows: 24, scrollbackSize: 8192)
        sessions.append(session)
        return session
    }

    /// The descriptors an `exec`'d child of this process inherits, as the child
    /// itself reports them by listing `/dev/fd`.
    ///
    /// This is a **probe child**, not a session shell, and that is deliberate.
    /// Inheritance is a property of *this* process's fd table at `exec` time, so
    /// any child observes it — while a session's own shell cannot be asked:
    /// `PTYSession` execs setuid `login`, whose fd table a non-root test may not
    /// read (the same EPERM that forces `currentWorkingDirectory()` to descend
    /// to a readable descendant), and on this machine `login -fp` under a test
    /// harness echoes commands without running them. A plain `/bin/sh` of our
    /// own uid answers reliably and measures the identical invariant.
    ///
    /// Spawned with a bare `posix_spawn`, deliberately **not**
    /// `Foundation.Process`. `Process` sets `POSIX_SPAWN_CLOEXEC_DEFAULT`, which
    /// closes every descriptor it was not explicitly told to keep — its children
    /// inherit nothing whatever the flags say, so a `Process`-based probe *passed
    /// against the unfixed code*. Plain `posix_spawn` inherits every descriptor
    /// not marked `FD_CLOEXEC`, which is exactly the `execv` semantics
    /// `PTYSession`'s child goes through and therefore the property under test.
    /// (`fork()` itself is unavailable to Swift.)
    ///
    /// Output goes through a temp file rather than a pipe: creating a pipe would
    /// add descriptors to the very table being measured.
    private func inheritedFDs() throws -> Set<String> {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pty-fd-probe-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("sh"), strdup("-c"), strdup("ls /dev/fd > \(outputPath)"), nil
        ]
        defer { for arg in argv where arg != nil { free(arg) } }

        let spawnResult = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&pid, "/bin/sh", nil, nil, buffer.baseAddress!, environ)
        }
        XCTAssertEqual(spawnResult, 0, "posix_spawn failed for the fd probe")
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        let text = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Creating PTY sessions must not add descriptors to what a subsequently
    /// `exec`'d child inherits.
    ///
    /// The assertion is **differential** — the same probe runs before and after
    /// the sessions exist, and only the growth is asserted. An absolute count
    /// would encode incidental descriptors of the test host (`Process` pipes,
    /// XCTest's own fds), making it brittle for reasons unrelated to the leak.
    /// The delta isolates exactly what the sessions contributed.
    ///
    /// Three sessions rather than one, so the pre-fix delta is 3: that also
    /// fails a partial fix which closes only the most recent master.
    func testPTYMastersAreNotInheritedByExecdChildren() async throws {
        let before = try inheritedFDs()

        for _ in 0..<3 {
            let session = try makeSession()
            await session.startReading()
        }

        let after = try inheritedFDs()
        let leaked = after.subtracting(before)

        XCTAssertTrue(leaked.isEmpty, """
            an exec'd child inherited \(leaked.count) descriptor(s) (\(leaked.sorted().joined(separator: ", "))) \
            that appeared only after 3 PTY sessions were created — those are the sessions' pty masters. \
            Each keeps its pty pair alive after the server closes its own copy (exhausting the \
            \(Self.ptmxMax)-entry ptmx pool), and the shell on it never sees EOF, so it outlives the server
            """)
    }

    /// The master fd is opened close-on-exec, which is the mechanism behind the
    /// assertion above.
    ///
    /// Kept alongside it rather than folded into it: the differential test
    /// depends on `/dev/fd` being listable and on `Process` not itself perturbing
    /// the table, whereas this reads the flag straight off the descriptor. If the
    /// probe ever becomes unreliable on some host, the invariant is still
    /// covered here.
    func testMasterFDIsCloseOnExec() async throws {
        let session = try makeSession()
        await session.startReading()

        let flags = await session._testOnly_masterFDFlags
        XCTAssertNotEqual(flags, -1, "F_GETFD failed on the master fd")
        XCTAssertEqual(flags & FD_CLOEXEC, FD_CLOEXEC,
                       "master fd is not FD_CLOEXEC — every later session's shell will inherit it")
    }

    /// `kern.tty.ptmx_max` on stock macOS. Quoted in the failure message so the
    /// bound on the leak appears next to the count.
    private static let ptmxMax = 511
}
