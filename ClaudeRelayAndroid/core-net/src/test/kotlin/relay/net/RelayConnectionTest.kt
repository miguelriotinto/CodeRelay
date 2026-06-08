package relay.net

import kotlinx.coroutines.runBlocking
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString.Companion.toByteString
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import relay.protocol.ServerMessage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class RelayConnectionTest {

    private lateinit var server: MockWebServer

    @BeforeEach
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach
    fun tearDown() {
        server.shutdown()
    }

    private fun wsUrlFor(): String {
        val httpUrl = server.url("/relay")
        return "ws://${httpUrl.host}:${httpUrl.port}/relay"
    }

    /** Enqueues a server-side WebSocket upgrade and captures the server's [WebSocket]. */
    private fun enqueueServerSocket(opened: CountDownLatch? = null): AtomicReference<WebSocket> {
        val ref = AtomicReference<WebSocket>()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                ref.set(webSocket)
                opened?.countDown()
            }
        }
        server.enqueue(MockResponse().withWebSocketUpgrade(listener))
        return ref
    }

    @Test
    fun `binary server frame is delivered to onTerminalOutput`() {
        val opened = CountDownLatch(1)
        val serverRef = enqueueServerSocket(opened)

        val conn = RelayConnection()
        val received = CountDownLatch(1)
        val payload = byteArrayOf(1, 2, 3, 4, 5)
        var got: ByteArray? = null
        conn.onTerminalOutput = { bytes ->
            got = bytes
            received.countDown()
        }

        runBlocking { conn.connectRaw(wsUrlFor()) }

        assert(opened.await(5, TimeUnit.SECONDS)) { "server socket never opened" }
        serverRef.get().send(payload.toByteString())

        assert(received.await(5, TimeUnit.SECONDS)) { "onTerminalOutput was not invoked" }
        assertArrayEquals(payload, got)
        runBlocking { conn.disconnect() }
    }

    @Test
    fun `generation increments on each connect`() {
        enqueueServerSocket()
        enqueueServerSocket()

        val conn = RelayConnection()
        assertEquals(0L, conn.generation)

        runBlocking { conn.connectRaw(wsUrlFor()) }
        assertEquals(1L, conn.generation)

        runBlocking { conn.connectRaw(wsUrlFor()) }
        assertEquals(2L, conn.generation)

        runBlocking { conn.disconnect() }
    }

    @Test
    fun `undecodable text frame is dropped without tearing down the connection`() {
        val opened = CountDownLatch(1)
        val serverRef = enqueueServerSocket(opened)

        val conn = RelayConnection()
        // Records every server message that reaches a subscriber, in order.
        val delivered = mutableListOf<ServerMessage>()
        val sawValid = CountDownLatch(1)
        conn.addServerMessageSubscriber { msg ->
            synchronized(delivered) { delivered.add(msg) }
            if (msg is ServerMessage.SessionDetached) sawValid.countDown()
        }

        runBlocking { conn.connectRaw(wsUrlFor()) }
        assert(opened.await(5, TimeUnit.SECONDS)) { "server socket never opened" }

        // Garbage text: decodeServer throws → runCatching drops it. No subscriber,
        // no teardown.
        serverRef.get().send("not json {")

        // A valid frame sent AFTER the garbage proves the connection is still live
        // and that the bad frame was a silent drop (not a tear-down). Because the
        // confinement dispatcher processes frames in order, once the valid frame
        // surfaces we know the garbage frame was fully handled (and dropped).
        serverRef.get().send("""{"type":"session_detached","payload":{}}""")
        assert(sawValid.await(5, TimeUnit.SECONDS)) { "valid frame after garbage was not delivered" }

        // The ONLY thing that reached a subscriber is the valid frame.
        val snapshot = synchronized(delivered) { delivered.toList() }
        assertEquals(listOf<ServerMessage>(ServerMessage.SessionDetached), snapshot) {
            "garbage frame must not reach a subscriber"
        }
        assertEquals(RelayConnection.ConnectionState.CONNECTED, conn.state)
        assertEquals(1L, conn.generation) { "garbage frame must not bump generation" }

        runBlocking { conn.disconnect() }
    }

    @Test
    fun `pong text frame routes to measurePingRtt and not to subscribers`() {
        // Server-side listener that echoes a pong as soon as it sees the client's
        // ping text frame, so measurePingRtt resolves via the pendingPong slot.
        val opened = CountDownLatch(1)
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                opened.countDown()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (text.contains("\"type\":\"ping\"")) {
                    webSocket.send("""{"type":"pong","payload":{}}""")
                }
            }
        }
        server.enqueue(MockResponse().withWebSocketUpgrade(listener))

        val conn = RelayConnection()
        val subscriberFired = AtomicBoolean(false)
        conn.addServerMessageSubscriber { subscriberFired.set(true) }

        runBlocking { conn.connectRaw(wsUrlFor()) }
        assert(opened.await(5, TimeUnit.SECONDS)) { "server socket never opened" }

        val rtt = runBlocking { conn.measurePingRtt() }

        assertNotNull(rtt) { "pong should resolve the in-flight ping" }
        assertTrue(rtt!! >= 0.0)
        assertFalse(subscriberFired.get()) { "pong must not reach a server-message subscriber" }

        runBlocking { conn.disconnect() }
    }

    @Test
    fun `frame from a superseded generation is dropped`() {
        val openedA = CountDownLatch(1)
        val serverRefA = enqueueServerSocket(openedA)
        val openedB = CountDownLatch(1)
        val serverRefB = enqueueServerSocket(openedB)

        val conn = RelayConnection()
        val terminalBytes = AtomicReference<ByteArray?>(null)
        val gotOutput = CountDownLatch(1)
        conn.onTerminalOutput = { bytes ->
            terminalBytes.set(bytes)
            gotOutput.countDown()
        }

        // First connection — generation 1. Capture its server-side socket.
        runBlocking { conn.connectRaw(wsUrlFor()) }
        assert(openedA.await(5, TimeUnit.SECONDS)) { "socket A never opened" }
        val socketA = serverRefA.get()

        // Second connection supersedes the first — generation becomes 2 and the
        // gen-1 listener's captured `gen` no longer matches.
        runBlocking { conn.connectRaw(wsUrlFor()) }
        assert(openedB.await(5, TimeUnit.SECONDS)) { "socket B never opened" }
        assertEquals(2L, conn.generation)

        // A frame arriving on the OLD socket carries the stale gen-1 callback and
        // must be dropped by the `gen != generation` bail.
        socketA.send(byteArrayOf(9, 9, 9).toByteString())

        // The frame should NOT surface. Wait briefly to give a (wrongly) delivered
        // frame time to arrive, then assert nothing came through.
        assertFalse(gotOutput.await(750, TimeUnit.MILLISECONDS)) {
            "stale-generation frame must not reach onTerminalOutput"
        }
        // A live frame on the CURRENT socket still works, proving the conn is fine.
        serverRefB.get().send(byteArrayOf(1, 2, 3).toByteString())
        assert(gotOutput.await(5, TimeUnit.SECONDS)) { "current-gen frame was not delivered" }
        assertArrayEquals(byteArrayOf(1, 2, 3), terminalBytes.get())

        runBlocking { conn.disconnect() }
    }

    // MARK: - Cleartext gate (Fix C2)
    //
    // The unbypassable chokepoint: `connect` enforces CleartextPolicy BEFORE
    // opening the socket. Every connect path (auto-connect, deep-link attach,
    // status probe) funnels through here, so none can skip the gate.

    @Test
    fun `connect refuses cleartext to a public host`() {
        val conn = RelayConnection()
        val config = ConnectionConfig(name = "public", host = "8.8.8.8", useTLS = false)
        assertThrows(CleartextPolicyException::class.java) {
            runBlocking { conn.connect(config, "tok") }
        }
        // Gate ran before any socket work — state is still untouched.
        assertEquals(RelayConnection.ConnectionState.DISCONNECTED, conn.state)
        assertEquals(0L, conn.generation) { "rejected config must not open a socket" }
    }

    @Test
    fun `connect refuses cleartext to a CGNAT host`() {
        val conn = RelayConnection()
        // Tailscale CGNAT 100.64/10 is NON-private → cleartext rejected.
        val config = ConnectionConfig(name = "cgnat", host = "100.64.0.1", useTLS = false)
        assertThrows(CleartextPolicyException::class.java) {
            runBlocking { conn.connect(config, "tok") }
        }
        assertEquals(0L, conn.generation)
    }

    @Test
    fun `connect to a private host does not throw the policy exception`() {
        // A private host that won't actually accept a socket — but the cleartext
        // gate must NOT be what stops it. We assert the thrown type (if any) is
        // never CleartextPolicyException. 192.0.2.0/24 is TEST-NET-1 but we use a
        // private RFC1918 host the policy permits; the connect attempt against a
        // dead port fails at the transport layer, not the gate.
        val conn = RelayConnection()
        val config = ConnectionConfig(name = "lan", host = "192.168.1.5", port = 1u, useTLS = false)
        try {
            runBlocking { conn.connect(config, "tok") }
        } catch (e: Throwable) {
            assertTrue(e !is CleartextPolicyException) {
                "private host must pass the cleartext gate, got: $e"
            }
        }
        runBlocking { conn.disconnect() }
    }

    @Test
    fun `connect over TLS to a public host does not throw the policy exception`() {
        // useTLS=true is allowed to ANY host (including public) — TLS makes
        // cleartext scoping moot.
        val conn = RelayConnection()
        val config = ConnectionConfig(name = "tls", host = "8.8.8.8", port = 1u, useTLS = true)
        try {
            runBlocking { conn.connect(config, "tok") }
        } catch (e: Throwable) {
            assertTrue(e !is CleartextPolicyException) {
                "TLS to a public host must pass the cleartext gate, got: $e"
            }
        }
        runBlocking { conn.disconnect() }
    }

    @Test
    fun `requireAllowed seam enforces the policy directly`() {
        // The pure decision the chokepoint delegates to — unit-tested without a socket.
        // Private cleartext: ok.
        CleartextPolicy.requireAllowed(ConnectionConfig(name = "a", host = "192.168.0.10", useTLS = false))
        CleartextPolicy.requireAllowed(ConnectionConfig(name = "b", host = "127.0.0.1", useTLS = false))
        CleartextPolicy.requireAllowed(ConnectionConfig(name = "c", host = "mac.local", useTLS = false))
        // TLS to public: ok.
        CleartextPolicy.requireAllowed(ConnectionConfig(name = "d", host = "relay.example.com", useTLS = true))
        // Public cleartext: throws.
        assertThrows(CleartextPolicyException::class.java) {
            CleartextPolicy.requireAllowed(ConnectionConfig(name = "e", host = "relay.example.com", useTLS = false))
        }
        // CGNAT cleartext: throws.
        assertThrows(CleartextPolicyException::class.java) {
            CleartextPolicy.requireAllowed(ConnectionConfig(name = "f", host = "100.64.0.1", useTLS = false))
        }
    }
}
