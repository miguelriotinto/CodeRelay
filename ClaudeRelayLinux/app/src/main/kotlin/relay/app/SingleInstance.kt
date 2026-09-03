package relay.app

import java.io.File
import java.io.RandomAccessFile
import java.net.StandardProtocolFamily
import java.net.UnixDomainSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.FileLock
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.Timer
import java.util.TimerTask

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
 * ### Who is primary is decided by a lock, not by a race on the socket file
 *
 * "Connect, else unlink and bind" alone lets two launches a few milliseconds
 * apart both fail to connect, both unlink, and both bind — two instances, one
 * of them on an orphaned inode. So the primary first takes an exclusive
 * `flock` on `coderelay.lock` in the same directory and holds it for its
 * lifetime. A second launch that cannot connect and cannot lock knows a primary
 * is *starting* and retries the connect briefly instead of binding. Only the
 * lock holder ever unlinks the socket, on bind and on [release].
 *
 * ### Where the socket lives
 *
 * `$XDG_RUNTIME_DIR` (per-user, mode 0700, tmpfs, cleared at logout). Without
 * it, a 0700 directory under the user's own state dir — never a predictable
 * path in world-writable `/tmp`, where another local user could pre-create it
 * and receive forwarded pairing URLs.
 *
 * ### Wire format and bounds
 *
 * One line per argument, UTF-8, newline terminated, connection closed. The
 * reader caps the message at [MAX_MESSAGE_BYTES] and every socket operation on
 * both sides has a deadline ([IO_DEADLINE_MS]), so a local peer that connects
 * and never finishes cannot wedge the accept loop, and a second launch cannot
 * hang forever waiting for a primary that stopped reading.
 */
class SingleInstance(
    private val directory: File = defaultDirectory(),
) {
    private val socketFile = File(directory, "coderelay.sock")
    private val lockFile = File(directory, "coderelay.lock")

    private var lock: FileLock? = null
    private var lockChannel: RandomAccessFile? = null

    /** Result of [claim]. */
    sealed interface Claim {
        /** This process owns the socket; [server] receives forwarded launches. */
        data class Primary(val server: ServerSocketChannel) : Claim

        /** Another instance is running and received our argv; exit now. */
        data object Forwarded : Claim
    }

    /** Either becomes the primary instance or forwards [args] to it. */
    fun claim(args: List<String>): Claim {
        ensureDirectory()
        val address = UnixDomainSocketAddress.of(socketFile.toPath())

        if (forward(address, args)) return Claim.Forwarded

        if (!tryLock()) {
            // A primary is between "locked" and "bound": give it a moment.
            repeat(CONNECT_RETRIES) {
                Thread.sleep(CONNECT_RETRY_MS)
                if (forward(address, args)) return Claim.Forwarded
            }
            // It never came up (or died holding nothing); take over.
            if (!tryLock()) error("another CodeRelay instance holds ${lockFile.path} but is not listening")
        }

        runCatching { socketFile.delete() }
        val server = ServerSocketChannel.open(StandardProtocolFamily.UNIX)
        server.bind(address)
        return Claim.Primary(server)
    }

    /** Sends [args] to a listening primary. False when nobody is listening. */
    private fun forward(address: UnixDomainSocketAddress, args: List<String>): Boolean {
        val channel = runCatching { SocketChannel.open(address) }.getOrNull() ?: return false
        return channel.use {
            withDeadline(it) {
                runCatching {
                    it.write(ByteBuffer.wrap(encode(args)))
                    it.shutdownOutput()
                    // Wait for the primary to close, so the handover is known to
                    // have been read before this process exits.
                    it.read(ByteBuffer.allocate(1))
                }.isSuccess
            }
        }
    }

    /** Removes the socket file — only if this process is the primary. */
    fun release() {
        if (lock == null) return
        runCatching { socketFile.delete() }
        runCatching { lock?.release() }
        runCatching { lockChannel?.close() }
        lock = null
        lockChannel = null
    }

    private fun tryLock(): Boolean {
        if (lock != null) return true
        val raf = RandomAccessFile(lockFile, "rw")
        val acquired = runCatching { raf.channel.tryLock() }.getOrNull()
        if (acquired == null) {
            raf.close()
            return false
        }
        lock = acquired
        lockChannel = raf
        return true
    }

    private fun ensureDirectory() {
        if (directory.isDirectory) return
        directory.mkdirs()
        runCatching {
            Files.setPosixFilePermissions(directory.toPath(), PosixFilePermissions.fromString("rwx------"))
        }
    }

    companion object {
        /** Bound on one forwarded message; argv is a URL and a flag or two. */
        const val MAX_MESSAGE_BYTES = 64 * 1024

        /** Every socket read/write on either side must finish within this. */
        const val IO_DEADLINE_MS = 3_000L

        private const val CONNECT_RETRIES = 10
        private const val CONNECT_RETRY_MS = 100L

        private val deadlines = Timer("coderelay-instance-deadline", true)

        fun defaultDirectory(): File {
            val runtime = System.getenv("XDG_RUNTIME_DIR")?.takeIf { it.isNotBlank() }
            if (runtime != null) return File(runtime)
            val state = System.getenv("XDG_STATE_HOME")?.takeIf { it.isNotBlank() }
                ?: File(System.getProperty("user.home"), ".local/state").path
            return File(state, "coderelay")
        }

        fun encode(args: List<String>): ByteArray =
            args.joinToString("") { it.replace("\n", "") + "\n" }.toByteArray(StandardCharsets.UTF_8)

        /** Inverse of [encode]. Empty lines (a trailing newline) are dropped. */
        fun decode(bytes: ByteArray): List<String> =
            String(bytes, StandardCharsets.UTF_8).split('\n').filter { it.isNotEmpty() }

        /**
         * Reads one forwarded launch from an accepted [channel], bounded by
         * [MAX_MESSAGE_BYTES] and [IO_DEADLINE_MS], and closes it (which
         * releases the sender).
         */
        fun readLaunch(channel: SocketChannel): List<String> = channel.use {
            withDeadline(it) {
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteBuffer.allocate(4096)
                while (out.size() < MAX_MESSAGE_BYTES) {
                    val n = runCatching { it.read(buffer) }.getOrDefault(-1)
                    if (n < 0) break
                    buffer.flip()
                    out.write(buffer.array(), 0, n)
                    buffer.clear()
                }
                decode(out.toByteArray())
            }
        }

        /**
         * Runs [block] with the channel force-closed after [IO_DEADLINE_MS].
         * Unix-domain channels have no read timeout; closing from another thread
         * is the supported way to interrupt a blocking read.
         */
        private fun <T> withDeadline(channel: SocketChannel, block: () -> T): T {
            val task = object : TimerTask() {
                override fun run() { runCatching { channel.close() } }
            }
            deadlines.schedule(task, IO_DEADLINE_MS)
            try {
                return block()
            } finally {
                task.cancel()
            }
        }
    }
}
