package relay.feature.servers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import relay.protocol.ConnectionConfig
import relay.protocol.PairingCode
import relay.protocol.PairingURL
import relay.session.PairingController
import relay.session.PairingError
import java.io.File

/**
 * Drives the pairing sheet: validates host/port/code, builds a [PairingURL],
 * redeems it via [PairingController], and translates errors to actionable
 * messages.
 *
 * Linux counterpart of the Android `PairingViewModel`. The class body is a
 * faithful copy — it was already platform-free — and the ONLY divergence is in
 * [createController], where Android reads `android.os.Build.MODEL` for the
 * device name. That name becomes the minted token's label
 * (`"<device> (paired)"`), so it is what the operator sees and revokes in
 * `claude-relay token list`; on Linux the hostname is the meaningful equivalent.
 */
class PairingViewModel(
    private val controllerFactory: () -> PairingController,
) {
    var host by mutableStateOf("")
    var port by mutableStateOf("9200")
    var useTLS by mutableStateOf(false)
    var code by mutableStateOf("")
    var errorMessage by mutableStateOf<String?>(null)
    var isPairing by mutableStateOf(false)

    /**
     * True when host is non-blank, port parses in 1..65535, and the code
     * normalizes (hyphens and lowercase are accepted).
     */
    val isValid: Boolean
        get() {
            val trimmedHost = host.trim()
            if (trimmedHost.isEmpty()) return false
            val portNumber = port.toIntOrNull() ?: return false
            if (portNumber < 1 || portNumber > 65535) return false
            return PairingCode.normalize(code) != null
        }

    /**
     * Validates, redeems, and returns the saved [ConnectionConfig] on success or
     * null on failure. The controller persists the config and token, so the
     * caller need only connect.
     */
    suspend fun pair(): ConnectionConfig? {
        errorMessage = null
        val trimmedHost = host.trim()
        if (trimmedHost.isEmpty()) {
            errorMessage = "Host is required."
            return null
        }
        val portNumber = port.toIntOrNull()
        if (portNumber == null || portNumber < 1 || portNumber > 65535) {
            errorMessage = "Port must be a number between 1 and 65535."
            return null
        }
        val normalized = PairingCode.normalize(code)
        if (normalized == null) {
            errorMessage = "That code is not a valid pairing code."
            return null
        }

        val url = PairingURL(host = trimmedHost, port = portNumber, useTLS = useTLS, code = normalized)
        val controller = controllerFactory()

        isPairing = true
        return try {
            val config = controller.pair(url)
            errorMessage = null
            config
        } catch (e: PairingError) {
            errorMessage = messageFor(e, trimmedHost, useTLS)
            null
        } catch (e: Exception) {
            errorMessage = "Pairing failed: ${e.message ?: e::class.simpleName}"
            null
        } finally {
            isPairing = false
        }
    }

    companion object {

        /** Translates a [PairingError] to an actionable message. */
        fun messageFor(error: PairingError, host: String, useTLS: Boolean): String {
            return when (error) {
                is PairingError.InvalidCode ->
                    "That code is invalid or has expired. Run `claude-relay setup` again for a fresh code."
                is PairingError.RateLimited ->
                    "Too many attempts from this device. Wait a minute and try again."
                is PairingError.TlsRequired ->
                    "$host requires a secure connection (wss://). Enable TLS on the server, then pair again."
                is PairingError.Unreachable ->
                    "Could not reach $host. Check you are on the same network as the Mac."
                is PairingError.TimedOut ->
                    "The server did not respond. Check it is running with `claude-relay status`."
                is PairingError.Server ->
                    "Pairing failed (${error.code}): ${error.text}"
            }
        }

        /** Builds a production [PairingController] from the real stores. */
        fun createController(viewModel: ServersViewModel): PairingController {
            return PairingController(
                store = object : relay.session.ConnectionStoreAdapter {
                    override suspend fun add(connection: ConnectionConfig) =
                        viewModel.addOrUpdateInternal(connection, null)
                },
                tokenStore = object : relay.session.TokenStoreAdapter {
                    override fun saveToken(token: String, connectionId: java.util.UUID) {
                        viewModel.saveTokenInternal(token, connectionId)
                    }
                },
                deviceName = deviceName(),
                platform = "linux",
                connectionFactory = { relay.net.RelayConnection() },
            )
        }

        /**
         * The machine's hostname, for the paired token's label.
         *
         * Deliberately avoids `InetAddress.getLocalHost().hostName`: that
         * performs a reverse DNS lookup and can block for seconds — or throw —
         * on a host with no resolvable name, which is exactly the LAN setup this
         * client targets. `$HOSTNAME` and `/etc/hostname` are both local reads.
         */
        internal fun deviceName(): String {
            System.getenv("HOSTNAME")?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            runCatching { File("/etc/hostname").readText().trim() }
                .getOrNull()?.takeIf { it.isNotEmpty() }?.let { return it }
            return "Linux"
        }
    }
}
