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
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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
        conn.disconnect()
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

        conn.disconnect()
    }
}
