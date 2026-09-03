package relay.app

import java.io.File
import java.net.StandardProtocolFamily
import java.net.UnixDomainSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.nio.charset.StandardCharsets

/**
 * One running CodeRelay per user session.
 *
 * Every `coderelay://` click and every "New Session" desktop action starts a
 * fresh process with the request in argv. Without this, each one opened a
 * second window on a second connection — Android avoids that with
 * `launchMode="singleTop"` + `onNewIntent`, macOS with URL events delivered to
 * the running app. On Linux the equivalent is a socket the first instance
 * listens on: a later launch connects, hands over its argv, and exits.
 *
 * The socket lives in `$XDG_RUNTIME_DIR` (per-user, tmpfs, cleared at logout)
 * so a stale file from a crash cannot outlive the session — and a stale file
 * within the session is detected by the failed connect and replaced.
 *
 * Wire format is deliberately trivial: one line per argument, UTF-8, newline
 * terminated, connection closed. Arguments never contain newlines (they are
 * URLs and flags), and the reader caps the message so a hostile local process
 * cannot make the app allocate unboundedly.
 */
class SingleInstance(
    private val socketFile: File = defaultSocketFile(),
) {

    /** Result of [claim]. */
    sealed interface Claim {
        /** This process owns the socket; [server] receives forwarded launches. */
        data class Primary(val server: ServerSocketChannel) : Claim

        /** Another instance is running and received our argv; exit now. */
        data object Forwarded : Claim
    }

    /**
     * Either becomes the primary instance or forwards [args] to it.
     *
     * Order matters: try to *connect* first. A live listener means we are the
     * second process, and we must hand over and exit. Only when nobody answers
     * do we unlink whatever is there and bind — which is also what recovers
     * from a socket file left behind by a crash.
     */
    fun claim(args: List<String>): Claim {
        socketFile.parentFile?.mkdirs()
        val address = UnixDomainSocketAddress.of(socketFile.toPath())

        if (forward(address, args)) return Claim.Forwarded

        runCatching { socketFile.delete() }
        val server = ServerSocketChannel.open(StandardProtocolFamily.UNIX)
        server.bind(address)
        return Claim.Primary(server)
    }

    /** Sends [args] to a listening primary. False when nobody is listening. */
    private fun forward(address: UnixDomainSocketAddress, args: List<String>): Boolean {
        val channel = runCatching { SocketChannel.open(address) }.getOrNull() ?: return false
        return channel.use {
            runCatching {
                it.write(ByteBuffer.wrap(encode(args)))
                it.shutdownOutput()
                // Wait for the primary to close, so the handover is known to have
                // been read before this process exits.
                it.read(ByteBuffer.allocate(1))
            }.isSuccess
        }
    }

    /** Removes the socket file. Call on quit so the next launch binds cleanly. */
    fun release() {
        runCatching { socketFile.delete() }
    }

    companion object {
        /** Bound on one forwarded message; argv is a URL and a flag or two. */
        const val MAX_MESSAGE_BYTES = 64 * 1024

        fun defaultSocketFile(): File {
            val runtime = System.getenv("XDG_RUNTIME_DIR")?.takeIf { it.isNotBlank() }
                ?: "/tmp/coderelay-${System.getProperty("user.name")}"
            return File(runtime, "coderelay.sock")
        }

        fun encode(args: List<String>): ByteArray =
            args.joinToString("") { it.replace("\n", "") + "\n" }.toByteArray(StandardCharsets.UTF_8)

        /** Inverse of [encode]. Empty lines (a trailing newline) are dropped. */
        fun decode(bytes: ByteArray): List<String> =
            String(bytes, StandardCharsets.UTF_8).split('\n').filter { it.isNotEmpty() }

        /**
         * Reads one forwarded launch from an accepted [channel], bounded by
         * [MAX_MESSAGE_BYTES], and closes it (which releases the sender).
         */
        fun readLaunch(channel: SocketChannel): List<String> = channel.use {
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteBuffer.allocate(4096)
            while (out.size() < MAX_MESSAGE_BYTES) {
                val n = it.read(buffer)
                if (n < 0) break
                buffer.flip()
                out.write(buffer.array(), 0, n)
                buffer.clear()
            }
            decode(out.toByteArray())
        }
    }
}
