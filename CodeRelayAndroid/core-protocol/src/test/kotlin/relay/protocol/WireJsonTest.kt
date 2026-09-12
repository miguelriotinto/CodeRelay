package relay.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.util.UUID

class WireJsonTest {
    @Serializable private data class Holder(@Serializable(with = UuidSerializer::class) val id: UUID)

    @Test fun `uuid encodes as lowercase hyphenated string`() {
        val id = UUID.fromString("550E8400-E29B-41D4-A716-446655440000")
        assertEquals(
            """{"id":"550e8400-e29b-41d4-a716-446655440000"}""",
            WireJson.instance.encodeToString(Holder(id)),
        )
    }

    @Test fun `uuid round-trips`() {
        val id = UUID.randomUUID()
        val back = WireJson.instance.decodeFromString<Holder>(WireJson.instance.encodeToString(Holder(id)))
        assertEquals(id, back.id)
    }
}
