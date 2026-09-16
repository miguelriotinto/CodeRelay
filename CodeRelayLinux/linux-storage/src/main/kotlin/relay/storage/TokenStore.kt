package relay.storage

import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Stores relay bearer tokens in the desktop keyring.
 *
 * Linux counterpart of the Android `TokenStore`, which uses
 * `EncryptedSharedPreferences`. The public API matches — `saveToken` /
 * `loadToken` / `deleteToken` / `deleteBedrockToken` (Linux additionally
 * reports success from the last one) — so shared call sites that ignore the
 * result compile against either.
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
 * same store: `service` is constant and `account` is the connection UUID. The
 * literal `bedrock` account is only ever *cleared* now — see [deleteBedrockToken].
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

    /**
     * Deletes the AWS Bedrock API key that builds before 2026-09 stored for the
     * on-device prompt enhancer. The optimizer is a relay feature now, so the
     * key has no reader; `AppEnvironment` calls this on every launch, off the
     * AWT thread, with no completion flag. On a locked keyring that still holds
     * the entry, libsecret's clear raises the unlock prompt; if the user
     * dismisses it, `secret-tool` exits non-zero, this returns false, and the
     * next launch prompts again — accepted, because there is no non-prompting
     * probe (`lookup` prompts too) and the entry exists only on machines that
     * once typed a Bedrock key. Once the entry is gone, `clear` is one cheap
     * exit-0 no-op per launch, bounded at 30 s wall clock.
     *
     * Never throws. Returns true when the keyring confirmed the entry is gone
     * (removed or absent) and false when it could not be reached, so a locked
     * keyring simply retries next launch.
     */
    fun deleteBedrockToken(): Boolean = clear(account = BEDROCK_ACCOUNT)

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

    /** True when `secret-tool clear` exited 0 — which it does on a miss too. */
    private fun clear(account: String): Boolean =
        runCatching {
            runner.run(listOf(SECRET_TOOL, "clear", "service", SERVICE_NAME, "account", account), null).exitCode == 0
        }.getOrDefault(false)

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

    /**
     * Runs `secret-tool` with a hard wall-clock bound. `waitFor` runs BEFORE the
     * pipes are drained, deliberately: a keyring prompting for an unlock
     * password keeps its stdout open, so reading to EOF first would block for
     * the life of the prompt and the timeout would never be reached.
     * secret-tool's whole output is one secret or one D-Bus error line — far
     * below the pipe buffer — so waiting first cannot deadlock on a full pipe.
     */
    class ProcessCommandRunner(private val timeoutSeconds: Long = KEYRING_TIMEOUT_SECONDS) : CommandRunner {
        override fun run(command: List<String>, stdin: String?): CommandResult {
            val process = ProcessBuilder(command).redirectErrorStream(false).start()
            if (stdin != null) {
                process.outputStream.use { it.write(stdin.toByteArray(Charsets.UTF_8)) }
            } else {
                process.outputStream.close()
            }
            if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                return CommandResult(exitCode = -1, stdout = "", stderr = "timed out")
            }
            val out = process.inputStream.bufferedReader().use { it.readText() }
            val err = process.errorStream.bufferedReader().use { it.readText() }
            return CommandResult(process.exitValue(), out, err)
        }
    }

    companion object {
        private const val SECRET_TOOL = "secret-tool"
        private const val KEYRING_TIMEOUT_SECONDS = 30L

        /** Matches the Android store's service name so the two agree conceptually. */
        const val SERVICE_NAME = "com.coderemote.relay"

        /** Account attribute older builds used for the Bedrock key; every other account is a connection UUID. */
        const val BEDROCK_ACCOUNT = "bedrock"

        val DefaultCommandRunner: CommandRunner = ProcessCommandRunner()
    }
}
