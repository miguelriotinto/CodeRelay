package relay.feature.servers

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import relay.protocol.PairingConnection
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import relay.session.ConnectionStoreAdapter
import relay.session.PairingController
import relay.session.PairingError
import relay.session.TokenStoreAdapter
import java.util.UUID

class PairingViewModelTest {

    @Test
    fun `invalid port yields an error and no pairing`() = runTest {
        var factoryCalled = false
        val vm = PairingViewModel(
            controllerFactory = {
                factoryCalled = true
                throw IllegalStateException("Controller should not be created")
            },
        )

        vm.host = "test.local"
        vm.port = "abc"
        vm.code = "K7QP2M4X"

        val result = vm.pair()

        assertNull(result)
        assertNotNull(vm.errorMessage)
        assertTrue(vm.errorMessage!!.contains("Port"))
        assertFalse(factoryCalled)
    }

    @Test
    fun `invalid code yields an error`() = runTest {
        var factoryCalled = false
        val vm = PairingViewModel(
            controllerFactory = {
                factoryCalled = true
                throw IllegalStateException("Controller should not be created")
            },
        )

        vm.host = "test.local"
        vm.port = "9200"
        vm.code = "123"

        val result = vm.pair()

        assertNull(result)
        assertNotNull(vm.errorMessage)
        assertTrue(vm.errorMessage!!.contains("not a valid pairing code"))
        assertFalse(factoryCalled)
    }

    @Test
    fun `invalidCode error maps to a fresh-code message`() = runTest {
        val vm = PairingViewModel(
            controllerFactory = {
                makeControllerThatReturnsError(401, "Invalid code")
            },
        )

        vm.host = "test.local"
        vm.port = "9200"
        vm.code = "K7QP2M4X"

        val result = vm.pair()

        assertNull(result)
        assertNotNull(vm.errorMessage)
        assertTrue(vm.errorMessage!!.contains("expired") || vm.errorMessage!!.contains("invalid"))
    }

    @Test
    fun `rateLimited error maps to wait message`() = runTest {
        val vm = PairingViewModel(
            controllerFactory = {
                makeControllerThatReturnsError(429, "Too many requests")
            },
        )

        vm.host = "test.local"
        vm.port = "9200"
        vm.code = "K7QP2M4X"

        val result = vm.pair()

        assertNull(result)
        assertNotNull(vm.errorMessage)
        assertTrue(vm.errorMessage!!.contains("too many", ignoreCase = true) ||
            vm.errorMessage!!.contains("attempts", ignoreCase = true))
    }

    @Test
    fun `whitespace-only host is rejected`() = runTest {
        var factoryCalled = false
        val vm = PairingViewModel(
            controllerFactory = {
                factoryCalled = true
                throw IllegalStateException("Controller should not be created")
            },
        )

        vm.host = "   "
        vm.port = "9200"
        vm.code = "K7QP2M4X"

        val result = vm.pair()

        assertNull(result)
        assertNotNull(vm.errorMessage)
        assertEquals("Host is required.", vm.errorMessage)
        assertFalse(factoryCalled)
    }

    @Test
    fun `successful pairing returns config`() = runTest {
        val vm = PairingViewModel(
            controllerFactory = {
                makeControllerThatSucceeds()
            },
        )

        vm.host = "test.local"
        vm.port = "9200"
        vm.code = "K7QP2M4X"

        val result = vm.pair()

        assertNotNull(result)
        assertEquals("test.local", result!!.host)
        assertEquals(9200.toUShort(), result.port)
        assertFalse(result.useTLS)
        assertNull(vm.errorMessage)
    }

    @Test
    fun `isValid requires non-blank host, valid port, and valid code`() {
        val vm = PairingViewModel(
            controllerFactory = { throw IllegalStateException("Not used") },
        )

        vm.host = ""
        vm.port = "9200"
        vm.code = "K7QP2M4X"
        assertFalse(vm.isValid)

        vm.host = "test.local"
        vm.port = "abc"
        vm.code = "K7QP2M4X"
        assertFalse(vm.isValid)

        vm.host = "test.local"
        vm.port = "9200"
        vm.code = "123"
        assertFalse(vm.isValid)

        vm.host = "test.local"
        vm.port = "9200"
        vm.code = "K7QP2M4X"
        assertTrue(vm.isValid)
    }

    // MARK: - Helpers

    private fun makeControllerThatReturnsError(code: Int, message: String): PairingController {
        return PairingController(
            store = object : ConnectionStoreAdapter {
                override suspend fun add(connection: ConnectionConfig) =
                    throw IllegalStateException("Store should not be called when pairing fails")
            },
            tokenStore = object : TokenStoreAdapter {
                override fun saveToken(token: String, connectionId: UUID) {}
            },
            deviceName = "test-device",
            platform = "android",
            connectionFactory = {
                object : PairingConnection {
                    override val generation = 1L
                    override val isConnected = true
                    override suspend fun connect(config: ConnectionConfig, token: String) {}
                    override suspend fun disconnect() {}
                    override suspend fun send(message: ClientMessage) {}
                    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
                        handler(ServerMessage.Error(code, message))
                        return UUID.randomUUID()
                    }
                    override fun removeSubscriber(id: UUID) {}
                }
            },
        )
    }

    private fun makeControllerThatSucceeds(): PairingController {
        return PairingController(
            store = object : ConnectionStoreAdapter {
                override suspend fun add(connection: ConnectionConfig) = listOf(connection)
            },
            tokenStore = object : TokenStoreAdapter {
                override fun saveToken(token: String, connectionId: UUID) {}
            },
            deviceName = "test-device",
            platform = "android",
            connectionFactory = {
                object : PairingConnection {
                    override val generation = 1L
                    override val isConnected = true
                    override suspend fun connect(config: ConnectionConfig, token: String) {}
                    override suspend fun disconnect() {}
                    override suspend fun send(message: ClientMessage) {}
                    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
                        handler(ServerMessage.PairSuccess(
                            token = "test-token",
                            tokenId = UUID.randomUUID().toString(),
                            label = "test.local",
                        ))
                        return UUID.randomUUID()
                    }
                    override fun removeSubscriber(id: UUID) {}
                }
            },
        )
    }
}
