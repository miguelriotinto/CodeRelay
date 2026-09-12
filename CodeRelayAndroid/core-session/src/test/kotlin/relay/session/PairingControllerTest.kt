package relay.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.PairingConnection
import relay.protocol.PairingURL
import relay.protocol.ServerMessage
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class PairingControllerTest {

    @Test
    fun `pair mints token and persists config plus token`() = runTest {
        val callLog = mutableListOf<String>()
        val connection = FakePairingConnection(callLog)
        val store = FakeConnectionStore()
        val tokenStore = FakeTokenStore()

        // Script PairSuccess
        connection.scriptedReply = ServerMessage.PairSuccess(
            token = "mint123",
            tokenId = "tokid456",
            label = "Pixel (paired)"
        )

        val controller = PairingController(
            store = store,
            tokenStore = tokenStore,
            deviceName = "TestDevice",
            platform = "android",
            connectionFactory = { connection },
            timeoutMs = 10_000L
        )

        val url = PairingURL.parse("coderelay://pair?host=test.local&port=9200&tls=0&code=ABC12345")!!
        val config = controller.pair(url)

        // Assert exactly one PairRequest sent
        assertEquals(1, connection.sentMessages.size)
        val pairReq = connection.sentMessages[0] as ClientMessage.PairRequest
        assertEquals("ABC12345", pairReq.code)
        assertEquals("TestDevice", pairReq.deviceName)
        assertEquals("android", pairReq.platform)

        // Assert ConnectionConfig persisted with correct fields
        assertEquals(1, store.savedConfigs.size)
        val savedConfig = store.savedConfigs[0]
        assertEquals("test.local", savedConfig.host)
        assertEquals(9200.toUShort(), savedConfig.port)
        assertEquals(false, savedConfig.useTLS)
        assertEquals("Pixel (paired)", savedConfig.name)

        // Assert token persisted for config.id
        assertEquals("mint123", tokenStore.tokens[savedConfig.id])

        // Assert connect and disconnect were called
        assertTrue(callLog.contains("connect"))
        assertTrue(callLog.contains("disconnect"))

        // Assert disconnect happened after send
        val connectIdx = callLog.indexOf("connect")
        val sendIdx = callLog.indexOf("send")
        val disconnectIdx = callLog.indexOf("disconnect")
        assertTrue(connectIdx < sendIdx)
        assertTrue(sendIdx < disconnectIdx)

        // Verify returned config matches
        assertEquals(savedConfig.id, config.id)
        assertEquals(savedConfig.name, config.name)
    }

    @Test
    fun `error 401 maps to InvalidCode and disconnects`() = runTest {
        val callLog = mutableListOf<String>()
        val connection = FakePairingConnection(callLog)
        val store = FakeConnectionStore()
        val tokenStore = FakeTokenStore()

        // Script Error(401)
        connection.scriptedReply = ServerMessage.Error(code = 401, message = "Invalid code")

        val controller = PairingController(
            store = store,
            tokenStore = tokenStore,
            deviceName = "TestDevice",
            platform = "android",
            connectionFactory = { connection },
            timeoutMs = 10_000L
        )

        val url = PairingURL.parse("coderelay://pair?host=test.local&port=9200&tls=0&code=BAD12345")!!

        assertThrows(PairingError.InvalidCode::class.java) {
            kotlinx.coroutines.runBlocking {
                controller.pair(url)
            }
        }

        // Assert disconnect was called
        assertTrue(callLog.contains("disconnect"))

        // Assert NOTHING persisted
        assertEquals(0, store.savedConfigs.size)
        assertEquals(0, tokenStore.tokens.size)
    }

    @Test
    fun `error 429 maps to RateLimited`() = runTest {
        val callLog = mutableListOf<String>()
        val connection = FakePairingConnection(callLog)
        val store = FakeConnectionStore()
        val tokenStore = FakeTokenStore()

        // Script Error(429)
        connection.scriptedReply = ServerMessage.Error(code = 429, message = "Rate limited")

        val controller = PairingController(
            store = store,
            tokenStore = tokenStore,
            deviceName = "TestDevice",
            platform = "android",
            connectionFactory = { connection },
            timeoutMs = 10_000L
        )

        val url = PairingURL.parse("coderelay://pair?host=test.local&port=9200&tls=0&code=RATE1234")!!

        assertThrows(PairingError.RateLimited::class.java) {
            kotlinx.coroutines.runBlocking {
                controller.pair(url)
            }
        }

        // Assert disconnect was called
        assertTrue(callLog.contains("disconnect"))

        // Assert NOTHING persisted
        assertEquals(0, store.savedConfigs.size)
        assertEquals(0, tokenStore.tokens.size)
    }

    @Test
    fun `silent server times out`() = runTest {
        val callLog = mutableListOf<String>()
        val connection = FakePairingConnection(callLog)
        val store = FakeConnectionStore()
        val tokenStore = FakeTokenStore()

        // Script NO reply (null means silent)
        connection.scriptedReply = null

        val controller = PairingController(
            store = store,
            tokenStore = tokenStore,
            deviceName = "TestDevice",
            platform = "android",
            connectionFactory = { connection },
            timeoutMs = 100L // Short timeout for fast test
        )

        val url = PairingURL.parse("coderelay://pair?host=test.local&port=9200&tls=0&code=DEAD1234")!!

        assertThrows(PairingError.TimedOut::class.java) {
            kotlinx.coroutines.runBlocking {
                controller.pair(url)
            }
        }

        // Assert disconnect was called
        assertTrue(callLog.contains("disconnect"))

        // Assert NOTHING persisted
        assertEquals(0, store.savedConfigs.size)
        assertEquals(0, tokenStore.tokens.size)
    }

    @Test
    fun `cleartext policy violation maps to TlsRequired`() = runTest {
        val callLog = mutableListOf<String>()
        val connection = FakePairingConnection(callLog)
        val store = FakeConnectionStore()
        val tokenStore = FakeTokenStore()

        // Script CleartextPolicyException on connect
        connection.connectError = relay.net.CleartextPolicyException("TLS required")

        val controller = PairingController(
            store = store,
            tokenStore = tokenStore,
            deviceName = "TestDevice",
            platform = "android",
            connectionFactory = { connection },
            timeoutMs = 10_000L
        )

        val url = PairingURL.parse("coderelay://pair?host=public.example.com&port=9200&tls=0&code=TLS12345")!!

        assertThrows(PairingError.TlsRequired::class.java) {
            kotlinx.coroutines.runBlocking {
                controller.pair(url)
            }
        }

        // Assert NOTHING persisted
        assertEquals(0, store.savedConfigs.size)
        assertEquals(0, tokenStore.tokens.size)
    }

    @Test
    fun `external coroutine cancellation disconnects and propagates CancellationException`() = runTest {
        val callLog = mutableListOf<String>()
        val connection = FakePairingConnection(callLog)
        val store = FakeConnectionStore()
        val tokenStore = FakeTokenStore()

        // Script NO reply (connection will wait indefinitely)
        connection.scriptedReply = null

        val controller = PairingController(
            store = store,
            tokenStore = tokenStore,
            deviceName = "TestDevice",
            platform = "android",
            connectionFactory = { connection },
            timeoutMs = 10_000L // Long timeout so we control cancellation timing
        )

        val url = PairingURL.parse("coderelay://pair?host=test.local&port=9200&tls=0&code=CANCEL12")!!

        // Launch pair() in a child coroutine
        val job = launch {
            controller.pair(url)
        }

        // Wait a moment for the job to reach the awaiting state (after send, before reply)
        kotlinx.coroutines.delay(50L)

        // Cancel the job
        job.cancel()
        job.join()

        // Assert disconnect was called despite cancellation
        assertTrue(callLog.contains("disconnect"), "disconnect() must run even when cancelled")

        // Assert the job was cancelled (CancellationException propagated, not remapped)
        assertTrue(job.isCancelled, "Job must be cancelled, not completed with PairingError")

        // Assert NOTHING persisted
        assertEquals(0, store.savedConfigs.size)
        assertEquals(0, tokenStore.tokens.size)
    }

    // MARK: - Test Doubles

    private class FakePairingConnection(
        private val callLog: MutableList<String>
    ) : PairingConnection {
        override val generation: Long = 1L
        override val isConnected: Boolean = true

        var scriptedReply: ServerMessage? = null
        var connectError: Exception? = null
        val sentMessages = mutableListOf<ClientMessage>()
        private val subscribers = ConcurrentHashMap<UUID, (ServerMessage) -> Unit>()

        override suspend fun connect(config: ConnectionConfig, token: String) {
            callLog.add("connect")
            connectError?.let { throw it }
        }

        override suspend fun disconnect() {
            callLog.add("disconnect")
        }

        override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
            val id = UUID.randomUUID()
            subscribers[id] = handler
            return id
        }

        override fun removeSubscriber(id: UUID) {
            subscribers.remove(id)
        }

        override suspend fun send(message: ClientMessage) {
            callLog.add("send")
            sentMessages.add(message)
            // Deliver scripted reply if present
            scriptedReply?.let { reply ->
                for (handler in subscribers.values) {
                    handler(reply)
                }
            }
            // If scriptedReply is null, do nothing (silence for timeout test)
        }
    }

    private class FakeConnectionStore : ConnectionStoreAdapter {
        val savedConfigs = mutableListOf<ConnectionConfig>()

        override suspend fun add(connection: ConnectionConfig): List<ConnectionConfig> {
            savedConfigs.add(connection)
            return savedConfigs.toList()
        }
    }

    private class FakeTokenStore : TokenStoreAdapter {
        val tokens = mutableMapOf<UUID, String>()

        override fun saveToken(token: String, connectionId: UUID) {
            tokens[connectionId] = token
        }
    }
}
