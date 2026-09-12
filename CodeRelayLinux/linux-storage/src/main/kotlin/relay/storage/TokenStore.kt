package relay.storage

import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Stores relay bearer tokens and the Bedrock API key in the desktop keyring.
 *
 * Linux counterpart of the Android `TokenStore`, which uses
 * `EncryptedSharedPreferences`. The public API is identical — `saveToken` /
 * `loadToken` / `deleteToken` / `saveBedrockToken` / `loadBedrockToken` — so
 * shared call sites compile against either.
 *
 * Backed by the **Secret Service** (D-Bus: gnome-keyring, KWallet, …) through
 * `secret-tool` from libsecret. Two properties of that choice are load-bearing:
 *
 *  1. **The secret never appears in a command line.** `secret-tool store` reads
 *     it from stdin. An argv-passed secret is world-readable via `/proc/<pid>/cmdline`
 *     for the lifetime of the process, which would be strictly worse than the
 *     plaintext file this class exists to avoid.
 *  2. **There is no disk fallback.** If the keyring is unavailable, writes throw
 *     [KeyringUnavailableException] and the caller surfaces an error. Silently
 *     degrading to a file would turn "my keyring is locked" into "my relay token
 *     is in plaintext in my home directory", without the user ever being told.
 *     A relay token grants full session access to the user's machine — including
 *     every session belonging to every other token (`attachSession` transfers
 *     ownership across tokens by design), so it is exactly as sensitive as an SSH key.
 *
 * Attribute schema matches Android's key layout so the two are conceptually the
 * same store: `service` is constant, `account` is the connection UUID (or the
 * literal `bedrock` for the API key).
 */
class TokenStore(
    private val runner: CommandRunner = DefaultCommandRunner,
) {

    /** Thrown when the keyring cannot be reached or refuses a write. */
    class KeyringUnavailableException(message: String, cause: Throwable? = null) :
        RuntimeException(message, cause)

    /** Persists the relay bearer [token] for [connectionId]. */
    fun saveToken(token: String, connectionId: UUID) {
        store(account = connectionId.toString().lowercase(), secret = token, label = "CodeRelay relay token")
    }

    /** Returns the relay bearer token for [connectionId], or null if absent. */
    fun loadToken(connectionId: UUID): String? =
        lookup(account = connectionId.toString().lowercase())

    /** Removes the stored token for [connectionId]. Absent is not an error. */
    fun deleteToken(connectionId: UUID) {
        clear(account = connectionId.toString().lowercase())
    }

    /** Persists the AWS Bedrock bearer token used by the prompt enhancer. */
    fun saveBedrockToken(token: String) {
        if (token.isEmpty()) {
            clear(account = BEDROCK_ACCOUNT)
            return
        }
        store(account = BEDROCK_ACCOUNT, secret = token, label = "CodeRelay Bedrock token")
    }

    /** Returns the stored Bedrock token, or null. */
    fun loadBedrockToken(): String? = lookup(account = BEDROCK_ACCOUNT)

    /** True when a working Secret Service is reachable. Used to warn early, in Settings. */
    fun isKeyringAvailable(): Boolean =
        runCatching { runner.run(listOf(SECRET_TOOL, "--version"), null).exitCode == 0 }
            .getOrDefault(false)

    // ---- secret-tool plumbing ----

    private fun store(account: String, secret: String, label: String) {
        val result = try {
            runner.run(
                listOf(SECRET_TOOL, "store", "--label=$label", "service", SERVICE_NAME, "account", account),
                // stdin, NOT argv — see the class doc.
                stdin = secret,
            )
        } catch (e: Exception) {
            throw KeyringUnavailableException(
                "Cannot reach the desktop keyring (is libsecret installed and a keyring running?)", e,
            )
        }
        if (result.exitCode != 0) {
            // stderr may name the D-Bus error; it never contains the secret.
            throw KeyringUnavailableException(
                "Keyring refused to store the secret (exit ${result.exitCode}): ${result.stderr.trim()}",
            )
        }
    }

    /**
     * A miss and a failure are both null here, deliberately: `secret-tool lookup`
     * exits non-zero for "not found", and callers of `loadToken` already treat
     * null as "not configured yet" and prompt. Distinguishing them would only
     * matter for diagnostics, and [isKeyringAvailable] covers that.
     */
    private fun lookup(account: String): String? {
        val result = runCatching {
            runner.run(listOf(SECRET_TOOL, "lookup", "service", SERVICE_NAME, "account", account), null)
        }.getOrNull() ?: return null
        if (result.exitCode != 0) return null
        // secret-tool emits the secret with no trailing newline, but a keyring
        // that stored one (or a value round-tripped through a shell) would add
        // one; a stray newline in a bearer token produces a 401 that is very
        // hard to diagnose from the server side.
        return result.stdout.trimEnd('\n', '\r').takeIf { it.isNotEmpty() }
    }

    private fun clear(account: String) {
        runCatching {
            runner.run(listOf(SECRET_TOOL, "clear", "service", SERVICE_NAME, "account", account), null)
        }
    }

    /** Result of running an external command. */
    data class CommandResult(val exitCode: Int, val stdout: String, val stderr: String)

    /**
     * Seam over process execution so the store is unit-testable without a
     * keyring — the tests inject a fake and assert on the argv and stdin,
     * particularly that the secret is never in the argv.
     */
    interface CommandRunner {
        fun run(command: List<String>, stdin: String?): CommandResult
    }

    object DefaultCommandRunner : CommandRunner {
        override fun run(command: List<String>, stdin: String?): CommandResult {
            val process = ProcessBuilder(command).redirectErrorStream(false).start()
            if (stdin != null) {
                process.outputStream.use { it.write(stdin.toByteArray(Charsets.UTF_8)) }
            } else {
                process.outputStream.close()
            }
            val out = process.inputStream.bufferedReader().use { it.readText() }
            val err = process.errorStream.bufferedReader().use { it.readText() }
            // A keyring prompting for an unlock password can block indefinitely;
            // bound it so the UI thread's caller cannot hang forever.
            if (!process.waitFor(KEYRING_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                return CommandResult(exitCode = -1, stdout = "", stderr = "timed out")
            }
            return CommandResult(process.exitValue(), out, err)
        }
    }

    companion object {
        private const val SECRET_TOOL = "secret-tool"
        private const val KEYRING_TIMEOUT_SECONDS = 30L

        /** Matches the Android store's service name so the two agree conceptually. */
        const val SERVICE_NAME = "com.coderemote.relay"

        /** Account attribute for the Bedrock key; every other account is a connection UUID. */
        const val BEDROCK_ACCOUNT = "bedrock"
    }
}
