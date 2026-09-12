package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ConnectionConfigTest {
    @Test fun `wsUrl is ws without TLS using default port`() {
        val config = ConnectionConfig(name = "dev", host = "192.168.1.10")
        assertEquals(9200.toUShort(), config.port)
        assertEquals("ws://192.168.1.10:9200", config.wsUrl)
    }

    @Test fun `wsUrl is wss with TLS and explicit port`() {
        val config = ConnectionConfig(name = "prod", host = "relay.example.com", port = 443u, useTLS = true)
        assertEquals("wss://relay.example.com:443", config.wsUrl)
    }
}
