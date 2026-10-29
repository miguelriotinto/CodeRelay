package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

class ConnectionConfigListTest {
    @Test fun preFeatureBookmarksDecodeEnabledWithNoIdentity() {
        val id = UUID.randomUUID()
        val list = ConnectionConfigList.decodeLenient("""[{"id":"$id","name":"a","host":"h","port":9200,"useTLS":false}]""")
        assertEquals(1, list.size)
        assertTrue(list[0].enabled)
        assertNull(list[0].instanceId)
        assertNull(list[0].displayName)
    }

    @Test fun oneBadElementDoesNotWipeTheList() {
        // The stores decoded all-or-nothing; one future-shaped bookmark dropped
        // every bookmark and the next save overwrote the list.
        val good = UUID.randomUUID()
        val list = ConnectionConfigList.decodeLenient(
            """[{"id":"$good","name":"a","host":"h"},{"id":"x","name":5,"host":[]},"junk"]""",
        )
        assertEquals(listOf(good), list.map { it.id })
    }

    @Test fun wrongTypedOptionalFieldsFallBackToDefaults() {
        val id = UUID.randomUUID()
        val list = ConnectionConfigList.decodeLenient(
            """[{"id":"$id","name":"a","host":"h","enabled":"yes","instanceId":12,"displayName":false}]""",
        )
        assertTrue(list.single().enabled)
        assertNull(list.single().instanceId)
        assertNull(list.single().displayName)
    }

    @Test fun multiServerFieldsRoundTrip() {
        val c = ConnectionConfig(name = "a", host = "h", enabled = false, instanceId = UUID.randomUUID(), displayName = "studio")
        val json = WireJson.instance.encodeToString(kotlinx.serialization.builtins.ListSerializer(ConnectionConfig.serializer()), listOf(c))
        assertEquals(listOf(c), ConnectionConfigList.decodeLenient(json))
    }

    @Test fun garbageIsEmpty() = assertEquals(emptyList<ConnectionConfig>(), ConnectionConfigList.decodeLenient("not json"))
}
