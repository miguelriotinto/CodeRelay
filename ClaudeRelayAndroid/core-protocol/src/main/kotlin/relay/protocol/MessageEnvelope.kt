package relay.protocol

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID

/**
 * Wire-format envelope that frames a [ClientMessage] or [ServerMessage] as
 * `{"type":"<type>","payload":{...}}`.
 *
 * Ports `MessageEnvelope.swift` plus the per-message `encodePayload` / `decode`
 * logic from `ClientMessage.swift` and `ServerMessage.swift`. Encoding builds
 * the payload object by hand so the omission rules match Swift exactly:
 * - `protocolVersion` / `name` / `agent` are emitted only when non-null.
 * - `skipReplay` is emitted only when `true`.
 * - empty-payload messages (`ping`/`pong`/`session_detach`/`session_list`/…)
 *   serialize as `"payload":{}`.
 *
 * Field order within each payload mirrors the Swift coding-key order so the
 * encoded bytes are identical.
 */
object MessageEnvelope {

    // MARK: - Encoding (client → wire)

    /** Encodes a [ClientMessage] to its `{"type":..,"payload":..}` wire string. */
    fun encodeClient(message: ClientMessage): String {
        val payload = buildJsonObject {
            when (message) {
                is ClientMessage.AuthRequest -> {
                    put("token", JsonPrimitive(message.token))
                    message.protocolVersion?.let { put("protocolVersion", JsonPrimitive(it)) }
                }
                is ClientMessage.SessionCreate -> {
                    message.name?.let { put("name", JsonPrimitive(it)) }
                    message.cols?.let { put("cols", JsonPrimitive(it.toInt())) }
                    message.rows?.let { put("rows", JsonPrimitive(it.toInt())) }
                }
                is ClientMessage.SessionAttach ->
                    put("sessionId", JsonPrimitive(message.sessionId.toWireString()))
                is ClientMessage.SessionResume -> {
                    put("sessionId", JsonPrimitive(message.sessionId.toWireString()))
                    if (message.skipReplay) put("skipReplay", JsonPrimitive(true))
                }
                ClientMessage.SessionDetach -> Unit
                is ClientMessage.SessionTerminate ->
                    put("sessionId", JsonPrimitive(message.sessionId.toWireString()))
                ClientMessage.SessionList -> Unit
                ClientMessage.SessionListAll -> Unit
                is ClientMessage.SessionRename -> {
                    put("sessionId", JsonPrimitive(message.sessionId.toWireString()))
                    put("name", JsonPrimitive(message.name))
                }
                is ClientMessage.Resize -> {
                    put("cols", JsonPrimitive(message.cols.toInt()))
                    put("rows", JsonPrimitive(message.rows.toInt()))
                }
                ClientMessage.Refresh -> Unit
                is ClientMessage.PasteImage ->
                    put("data", JsonPrimitive(message.data))
                ClientMessage.Ping -> Unit
                is ClientMessage.RegisterPushToken -> {
                    put("platform", JsonPrimitive(message.platform.raw))
                    put("token", JsonPrimitive(message.token))
                    put("deviceId", JsonPrimitive(message.deviceId))
                    put("enabled", JsonPrimitive(message.enabled))
                    put("notifyOnFinished", JsonPrimitive(message.notifyOnFinished))
                }
                is ClientMessage.UnregisterPushToken ->
                    put("deviceId", JsonPrimitive(message.deviceId))
            }
        }
        val envelope = buildJsonObject {
            put("type", JsonPrimitive(message.typeString))
            put("payload", payload)
        }
        return WireJson.instance.encodeToString(JsonObject.serializer(), envelope)
    }

    // MARK: - Decoding (wire → server)

    /**
     * Decodes a server-sent `{"type":..,"payload":..}` wire string into a
     * [ServerMessage].
     *
     * Throws [IllegalArgumentException] on ANY malformed input: an unknown
     * `type`, a missing/wrong-typed field, a non-object `payload`, or any other
     * parse/decode failure. The unknown-type case keeps its original message
     * (`"Unknown server message type: <type>"`); every other failure is
     * rethrown as `"malformed server message: <cause>"`. Callers in the net
     * layer wrap this in `runCatching`.
     */
    fun decodeServer(text: String): ServerMessage = try {
        val root = WireJson.instance.parseToJsonElement(text).jsonObject
        val type = root.getValue("type").jsonPrimitive.content
        val payload = root["payload"]?.jsonObject ?: JsonObject(emptyMap())
        when (type) {
            "auth_success" -> ServerMessage.AuthSuccess(payload.intOrNull("protocolVersion"))
            "auth_failure" -> ServerMessage.AuthFailure(payload.string("reason"))
            "session_created" -> ServerMessage.SessionCreated(
                payload.uuid("sessionId"), payload.uShort("cols"), payload.uShort("rows"),
            )
            "session_attached" -> ServerMessage.SessionAttached(
                payload.uuid("sessionId"), payload.string("state"),
            )
            "session_resumed" -> ServerMessage.SessionResumed(payload.uuid("sessionId"))
            "replay_complete" -> ServerMessage.ReplayComplete(payload.uuid("sessionId"))
            "session_detached" -> ServerMessage.SessionDetached
            "session_terminated" -> ServerMessage.SessionTerminated(
                payload.uuid("sessionId"), payload.string("reason"),
            )
            "session_expired" -> ServerMessage.SessionExpired(payload.uuid("sessionId"))
            "session_state" -> ServerMessage.SessionStateMsg(
                payload.uuid("sessionId"), payload.string("state"),
            )
            "session_activity" -> ServerMessage.SessionActivity(
                sessionId = payload.uuid("sessionId"),
                activity = ActivityState.fromRaw(payload.string("activity")),
                agent = payload.stringOrNull("agent"),
                agentState = payload.stringOrNull("agentState")?.let(AgentDetectedState::fromRaw),
                title = payload.stringOrNull("title"),
            )
            "session_stolen" -> ServerMessage.SessionStolen(payload.uuid("sessionId"))
            "session_renamed" -> ServerMessage.SessionRenamed(
                payload.uuid("sessionId"), payload.string("name"),
            )
            "session_list_result" -> ServerMessage.SessionList(payload.sessions("sessions"))
            "session_list_all_result" -> ServerMessage.SessionListAll(payload.sessions("sessions"))
            "resize_ack" -> ServerMessage.ResizeAck(payload.uShort("cols"), payload.uShort("rows"))
            "paste_image_result" -> ServerMessage.PasteImageResult(payload.getValue("success").jsonPrimitive.boolean)
            "pong" -> ServerMessage.Pong
            "error" -> ServerMessage.Error(payload.int("code"), payload.string("message"))
            else -> throw IllegalArgumentException("Unknown server message type: $type")
        }
    } catch (e: IllegalArgumentException) {
        // Unknown-type (and any other IllegalArgumentException) propagates as-is — never double-wrapped.
        throw e
    } catch (e: Exception) {
        // Missing/wrong-typed fields, non-object payload, parse errors, etc.
        throw IllegalArgumentException("malformed server message: ${e.message}", e)
    }

    // MARK: - JsonObject field helpers

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.stringOrNull(key: String): String? = this[key]?.jsonPrimitive?.content
    private fun JsonObject.int(key: String): Int = getValue(key).jsonPrimitive.int
    private fun JsonObject.intOrNull(key: String): Int? = this[key]?.jsonPrimitive?.int
    private fun JsonObject.uuid(key: String): UUID = UUID.fromString(string(key))

    // Trusted source: the server only emits valid UInt16 cols/rows, so we narrow Int→UShort
    // without range validation — adding it could reject otherwise-valid frames.
    private fun JsonObject.uShort(key: String): UShort = getValue(key).jsonPrimitive.int.toUShort()
    private fun JsonObject.sessions(key: String): List<SessionInfo> =
        WireJson.instance.decodeFromJsonElement(ListSerializer(SessionInfo.serializer()), getValue(key))
}
