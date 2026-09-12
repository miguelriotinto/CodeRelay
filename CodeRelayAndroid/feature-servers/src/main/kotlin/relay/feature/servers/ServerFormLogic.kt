package relay.feature.servers

import relay.protocol.ConnectionConfig
import java.util.UUID

/**
 * Pure, Context-free logic backing the server-list / add-edit screens, factored
 * out so it stays unit-testable on the plain JVM (no Android, no DataStore).
 *
 * Ports the validation + persistence decisions from
 * `AddEditServerViewModel.swift` and the add-or-replace-by-id list mutation that
 * `SavedConnectionStore` performs on iOS/Android.
 */
object ServerFormLogic {

    /** Default plaintext WebSocket port (matches the server's `wsPort` default). */
    const val DEFAULT_PLAINTEXT_PORT = "9200"

    /** Default TLS port (`wss://` over standard HTTPS). */
    const val DEFAULT_TLS_PORT = "443"

    /**
     * Host-non-empty validation, mirroring `AddEditServerViewModel.isValid`
     * (`!host.isEmpty`). The Save button is disabled when this is false.
     */
    fun isHostValid(host: String): Boolean = host.trim().isNotEmpty()

    /**
     * Returns the port to show after the "Use TLS" toggle flips, swapping only
     * the well-known defaults so a deliberate custom port is never clobbered:
     *  - turning TLS **on** while the port is still the plaintext default
     *    (or blank) switches it to [DEFAULT_TLS_PORT];
     *  - turning TLS **off** while the port is the TLS default switches it back
     *    to [DEFAULT_PLAINTEXT_PORT];
     *  - any other (custom) port is returned unchanged.
     */
    fun portForTLSChange(currentPort: String, useTLS: Boolean): String {
        val trimmed = currentPort.trim()
        return if (useTLS) {
            if (trimmed.isEmpty() || trimmed == DEFAULT_PLAINTEXT_PORT) DEFAULT_TLS_PORT else currentPort
        } else {
            if (trimmed == DEFAULT_TLS_PORT) DEFAULT_PLAINTEXT_PORT else currentPort
        }
    }

    /**
     * Parses a port string to a [UShort], mirroring Swift's
     * `UInt16(port), portNumber >= 1`. Returns null when not a valid 1…65535
     * port — Save is blocked in that case.
     */
    fun parsePort(port: String): UShort? {
        val value = port.trim().toIntOrNull() ?: return null
        if (value < 1 || value > UShort.MAX_VALUE.toInt()) return null
        return value.toUShort()
    }

    /**
     * Builds the [ConnectionConfig] to persist, mirroring
     * `AddEditServerViewModel.save()`:
     *  - reuses [existingId] in edit mode, mints a fresh [UUID] in add mode;
     *  - falls back to the host as the display name when [name] is blank.
     *
     * Returns null when host or port are invalid (Save stays a no-op).
     */
    fun buildConfig(
        existingId: UUID?,
        name: String,
        host: String,
        port: String,
        useTLS: Boolean,
    ): ConnectionConfig? {
        if (!isHostValid(host)) return null
        val portNumber = parsePort(port) ?: return null
        val trimmedHost = host.trim()
        val trimmedName = name.trim()
        return ConnectionConfig(
            id = existingId ?: UUID.randomUUID(),
            name = trimmedName.ifEmpty { trimmedHost },
            host = trimmedHost,
            port = portNumber,
            useTLS = useTLS,
        )
    }

    /**
     * Add-or-replace-by-id, mirroring `SavedConnectionStore.add`: replaces the
     * existing entry with the same [ConnectionConfig.id] in place, else appends.
     * Returns a new list; the input is not mutated.
     */
    fun upsert(existing: List<ConnectionConfig>, config: ConnectionConfig): List<ConnectionConfig> {
        val result = existing.toMutableList()
        val index = result.indexOfFirst { it.id == config.id }
        if (index >= 0) result[index] = config else result.add(config)
        return result
    }
}
