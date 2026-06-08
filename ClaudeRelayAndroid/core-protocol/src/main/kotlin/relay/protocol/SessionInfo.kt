package relay.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.util.UUID

/**
 * Encodes [SessionState] as its hyphenated wire [SessionState.raw]; decodes via
 * [SessionState.fromRaw] (unknown values fall back to `CREATED`).
 */
internal object SessionStateSerializer : KSerializer<SessionState> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("relay.protocol.SessionState", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: SessionState) = encoder.encodeString(value.raw)
    override fun deserialize(decoder: Decoder): SessionState = SessionState.fromRaw(decoder.decodeString())
}

/**
 * Encodes [ActivityState] as its modern wire [ActivityState.raw]; decodes via
 * [ActivityState.fromRaw], which also accepts the legacy `claude_*` aliases.
 */
internal object ActivityStateSerializer : KSerializer<ActivityState> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("relay.protocol.ActivityState", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ActivityState) = encoder.encodeString(value.raw)
    override fun deserialize(decoder: Decoder): ActivityState = ActivityState.fromRaw(decoder.decodeString())
}

/**
 * Metadata about a ClaudeRelay session.
 *
 * Ports `SessionInfo.swift`. `cols`/`rows` are `UInt16` in Swift → [UShort] here.
 * `createdAt` is a reference-date [Double] (see [ReferenceDateDoubleSerializer]).
 */
@Serializable
data class SessionInfo(
    @Serializable(with = UuidSerializer::class) val id: UUID,
    val name: String? = null,
    @Serializable(with = SessionStateSerializer::class) val state: SessionState,
    val tokenId: String,
    @Serializable(with = ReferenceDateDoubleSerializer::class) val createdAt: Double,
    val cols: UShort,
    val rows: UShort,
    @Serializable(with = ActivityStateSerializer::class) val activity: ActivityState? = null,
    val agent: String? = null,
)
