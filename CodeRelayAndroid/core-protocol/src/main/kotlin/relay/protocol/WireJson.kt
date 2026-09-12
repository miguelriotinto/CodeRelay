package relay.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Canonical lowercase, hyphenated wire string for a [UUID] — matching Swift's
 * `Codable` `UUID` representation on the WebSocket path. Single source of truth
 * for the UUID→wire rule, shared by [UuidSerializer] and [MessageEnvelope].
 */
internal fun UUID.toWireString(): String = toString().lowercase()

/**
 * Serializes [UUID] as a canonical lowercase, hyphenated string — matching
 * Swift's `Codable` `UUID` representation on the WebSocket path.
 */
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("relay.protocol.UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.toWireString())
    }

    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
}

/**
 * Serializes a reference-date timestamp as a raw [Double].
 *
 * The WebSocket path uses Swift's default `JSONEncoder`, which encodes `Date`
 * as a `Double` of seconds since the reference date (2001-01-01), NOT ISO-8601.
 * This serializer is the identity over `Double`; conversion of the reference-date
 * value (if any) is validated against a live server frame in Task 9.
 */
object ReferenceDateDoubleSerializer : KSerializer<Double> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("relay.protocol.ReferenceDate", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Double) {
        encoder.encodeDouble(value)
    }

    override fun deserialize(decoder: Decoder): Double = decoder.decodeDouble()
}

/**
 * The single configured [Json] instance for the wire protocol.
 *
 * - [Json.ignoreUnknownKeys]: tolerate fields a future server adds.
 * - [Json.encodeDefaults] `= false`: defaults are omitted, matching Swift's
 *   `encodeIfPresent` / conditional-encode semantics.
 * - [Json.explicitNulls] `= false`: nullable properties at their default `null`
 *   are omitted entirely rather than emitted as `"key":null`.
 *
 * No `namingStrategy` is configured — Kotlin property names map 1:1 to the
 * Swift wire field names (e.g. `tokenId`, `protocolVersion`, `skipReplay`).
 */
object WireJson {
    val instance: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        explicitNulls = false
    }
}
