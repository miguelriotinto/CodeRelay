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

    /**
     * Host-non-empty validation, mirroring `AddEditServerViewModel.isValid`
     * (`!host.isEmpty`). The Save button is disabled when this is false.
     */
    fun isHostValid(host: String): Boolean = host.trim().isNotEmpty()

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
