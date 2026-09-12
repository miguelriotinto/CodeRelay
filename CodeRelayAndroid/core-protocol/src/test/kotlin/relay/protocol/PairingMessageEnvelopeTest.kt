package relay.protocol

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue

class PairingMessageEnvelopeTest {
    @Test fun `pair_request encodes with code deviceName platform`() {
        val json = MessageEnvelope.encodeClient(
            ClientMessage.PairRequest(code = "K7QP2M4X", deviceName = "Pixel", platform = "android"))
        assertTrue(json.contains("\"type\":\"pair_request\""))
        assertTrue(json.contains("\"code\":\"K7QP2M4X\""))
        assertTrue(json.contains("\"deviceName\":\"Pixel\""))
        assertTrue(json.contains("\"platform\":\"android\""))
    }

    @Test fun `pair_success decodes token tokenId label`() {
        val msg = MessageEnvelope.decodeServer(
            "{\"type\":\"pair_success\",\"payload\":{\"token\":\"t\",\"tokenId\":\"id\",\"label\":\"Pixel (paired)\"}}")
        assertTrue(msg is ServerMessage.PairSuccess)
        val ps = msg as ServerMessage.PairSuccess
        assertEquals("t", ps.token)
        assertEquals("id", ps.tokenId)
        assertEquals("Pixel (paired)", ps.label)
    }

    @Test fun `type strings are registered`() {
        assertTrue(ClientMessage.ALL_TYPE_STRINGS.contains("pair_request"))
        assertTrue(ServerMessage.ALL_TYPE_STRINGS.contains("pair_success"))
    }
}
