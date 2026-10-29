package relay.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.util.UUID

/**
 * Decodes a stored bookmark list element by element. The stores used to decode
 * the whole list in one call, so one bookmark written in another shape (a
 * future build, then a downgrade) failed the decode, the store returned an
 * empty list, and the next save overwrote every bookmark. Wrong-typed optional
 * multi-server fields fall back to their defaults for the same reason.
 */
object ConnectionConfigList {
    fun decodeLenient(json: String): List<ConnectionConfig> = decodeLenientOrNull(json).orEmpty()

    /** Null when [json] is not a JSON array at all (a store can then fall back to its legacy key). */
    fun decodeLenientOrNull(json: String): List<ConnectionConfig>? {
        val array = runCatching { WireJson.instance.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: return null
        return array.mapNotNull(::decodeOne)
    }

    private fun decodeOne(element: JsonElement): ConnectionConfig? {
        val obj = element as? JsonObject ?: return null
        val cleaned = JsonObject(obj.toMutableMap().apply {
            if ((this["enabled"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull == null) remove("enabled")
            if (!isUuidString(this["instanceId"])) remove("instanceId")
            if ((this["displayName"] as? JsonPrimitive)?.isString != true) remove("displayName")
        })
        return runCatching { WireJson.instance.decodeFromJsonElement(ConnectionConfig.serializer(), cleaned) }.getOrNull()
    }

    private fun isUuidString(element: JsonElement?): Boolean {
        val p = element as? JsonPrimitive ?: return false
        return p.isString && runCatching { UUID.fromString(p.content) }.isSuccess
    }
}
