package relay.feature.servers

import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import relay.protocol.ConnectionConfig
import relay.protocol.PairingCode
import relay.protocol.PairingURL
import relay.session.PairingController
import relay.session.PairingError

/**
 * Drives the pairing sheet: validates fields (host, port, code), builds a
 * [PairingURL], redeems it via [PairingController], and translates errors to
 * actionable UI messages.
 *
 * Ports `PairingViewModel.swift`. The controller is injected via
 * [controllerFactory] so tests can substitute a fake without real network I/O.
 * The factory is invoked on each [pair] call (not at construction) so a failed
 * pair can be retried without rebuilding the view model.
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
     * True when the fields are valid: host is non-blank after trimming, port
     * parses as a valid Int (1..65535), and code normalizes.
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
     * Validates fields, builds a [PairingURL], redeems it via the controller,
     * and returns the saved [ConnectionConfig] on success or null on failure.
     * Errors are exposed via [errorMessage]. The controller persists the config
     * and token, so the caller need only connect via the existing onConnect path.
     *
     * Ports `PairingViewModel.pair()`.
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
        /**
         * Translates a [PairingError] to an actionable message. Ports
         * `PairingViewModel.message(for:host:useTLS:)`.
         */
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

        /**
         * Builds a production [PairingController] from real stores injected via
         * [ServersViewModel]. The device name is [Build.MODEL] (e.g. "Pixel 8 Pro",
         * "SM-S928U"), platform is "android".
         */
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
                deviceName = Build.MODEL,
                platform = "android",
                connectionFactory = {
                    relay.net.RelayConnection()
                },
            )
        }
    }
}
