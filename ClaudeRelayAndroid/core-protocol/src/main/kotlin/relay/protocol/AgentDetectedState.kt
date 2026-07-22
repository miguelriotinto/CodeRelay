package relay.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Fine-grained coding-agent state parsed from the session's terminal screen by
 * the server. Ports `AgentDetectedState.swift`. Distinct from [ActivityState]
 * (which only tracks whether output is flowing). [fromRaw] is tolerant: an
 * unrecognized value from a newer server decodes to [UNKNOWN] rather than
 * throwing, so an older client never fails to parse a `session_activity`.
 */
enum class AgentDetectedState(val raw: String) {
    /** Agent is running and waiting for user input (herdr "idle"/"done"). */
    IDLE("idle"),

    /** Agent is actively producing output / thinking. */
    WORKING("working"),

    /** Agent is asking a question / permission prompt — needs attention. */
    BLOCKED("blocked"),

    /** State could not be determined. */
    UNKNOWN("unknown");

    /**
     * Whether this state should raise a "needs attention" affordance. Only
     * [BLOCKED] demands the user act; [IDLE] merely means "done, no rush".
     */
    val needsAttention: Boolean get() = this == BLOCKED

    companion object {
        fun fromRaw(value: String): AgentDetectedState =
            entries.firstOrNull { it.raw == value } ?: UNKNOWN
    }
}

/**
 * Encodes [AgentDetectedState] as its wire [AgentDetectedState.raw]; decodes via
 * [AgentDetectedState.fromRaw] (unknown values fall back to [AgentDetectedState.UNKNOWN]).
 */
internal object AgentDetectedStateSerializer : KSerializer<AgentDetectedState> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("relay.protocol.AgentDetectedState", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: AgentDetectedState) = encoder.encodeString(value.raw)
    override fun deserialize(decoder: Decoder): AgentDetectedState =
        AgentDetectedState.fromRaw(decoder.decodeString())
}
