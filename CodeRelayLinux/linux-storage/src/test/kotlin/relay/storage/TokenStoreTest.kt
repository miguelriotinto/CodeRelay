package relay.storage

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

/**
 * The security-critical store. These tests exist mainly to pin two properties
 * that would be silent, serious regressions if they broke: the secret must never
 * reach a command line, and a keyring failure must never degrade to plaintext.
 */
class TokenStoreTest {

    /** Records every invocation so tests can assert on argv and stdin. */
    private class FakeRunner(
        var exitCode: Int = 0,
        var stdout: String = "",
        var stderr: String = "",
        var throwOnRun: Boolean = false,
    ) : TokenStore.CommandRunner {
        data class Invocation(val command: List<String>, val stdin: String?)

        val invocations = mutableListOf<Invocation>()

        override fun run(command: List<String>, stdin: String?): TokenStore.CommandResult {
            invocations += Invocation(command, stdin)
            if (throwOnRun) throw java.io.IOException("secret-tool not found")
            return TokenStore.CommandResult(exitCode, stdout, stderr)
        }
    }

    private val connectionId = UUID.fromString("3f2504e0-4f89-11d3-9a0c-0305e82c3301")

    // ---- the property that matters most ----

    /**
     * A secret passed in argv is world-readable through `/proc/<pid>/cmdline`
     * for the lifetime of the process. That would be strictly worse than the
     * plaintext file this class exists to replace.
     */
    @Test
    fun `secret is passed on stdin and never appears in argv`() {
        val runner = FakeRunner()
        TokenStore(runner).saveToken("super-secret-token-value", connectionId)

        val call = runner.invocations.single()
        assertEquals("super-secret-token-value", call.stdin, "secret must go to stdin")
        assertTrue(
            call.command.none { it.contains("super-secret-token-value") },
            "secret leaked into argv: ${call.command}",
        )
    }

    @Test
    fun `bedrock secret also stays out of argv`() {
        val runner = FakeRunner()
        TokenStore(runner).saveBedrockToken("bedrock-key-abc123")

        val call = runner.invocations.single()
        assertEquals("bedrock-key-abc123", call.stdin)
        assertTrue(call.command.none { it.contains("bedrock-key-abc123") })
    }

    /**
     * Never silently fall back to disk. "My keyring is locked" must not quietly
     * become "my relay token is in plaintext in my home directory" — a relay
     * token grants full session access to the user's machine.
     */
    @Test
    fun `save throws when the keyring is unreachable`() {
        val runner = FakeRunner(throwOnRun = true)
        assertThrows(TokenStore.KeyringUnavailableException::class.java) {
            TokenStore(runner).saveToken("t", connectionId)
        }
    }

    @Test
    fun `save throws when the keyring refuses the write`() {
        val runner = FakeRunner(exitCode = 1, stderr = "org.freedesktop.DBus.Error.NoReply")
        val error = assertThrows(TokenStore.KeyringUnavailableException::class.java) {
            TokenStore(runner).saveToken("t", connectionId)
        }
        assertTrue(error.message!!.contains("NoReply"), "should surface the D-Bus reason")
    }

    @Test
    fun `failure message does not contain the secret`() {
        val runner = FakeRunner(exitCode = 1, stderr = "denied")
        val error = assertThrows(TokenStore.KeyringUnavailableException::class.java) {
            TokenStore(runner).saveToken("do-not-log-me", connectionId)
        }
        assertFalse(error.message!!.contains("do-not-log-me"))
    }

    // ---- lookup behaviour ----

    @Test
    fun `load returns the stored secret`() {
        val runner = FakeRunner(stdout = "my-token")
        assertEquals("my-token", TokenStore(runner).loadToken(connectionId))
    }

    /**
     * A stray newline in a bearer token produces a 401 that is extremely hard to
     * diagnose from the server side — it looks exactly like a wrong token.
     */
    @Test
    fun `load trims a trailing newline`() {
        val runner = FakeRunner(stdout = "my-token\n")
        assertEquals("my-token", TokenStore(runner).loadToken(connectionId))
    }

    @Test
    fun `load returns null on a miss`() {
        val runner = FakeRunner(exitCode = 1)
        assertNull(TokenStore(runner).loadToken(connectionId))
    }

    @Test
    fun `load returns null rather than empty string`() {
        val runner = FakeRunner(stdout = "\n")
        assertNull(
            TokenStore(runner).loadToken(connectionId),
            "an empty secret must read as absent, not as a valid empty token",
        )
    }

    @Test
    fun `load returns null when secret-tool is missing`() {
        val runner = FakeRunner(throwOnRun = true)
        assertNull(TokenStore(runner).loadToken(connectionId))
    }

    // ---- key scoping ----

    @Test
    fun `token is scoped by service and connection id`() {
        val runner = FakeRunner()
        TokenStore(runner).saveToken("t", connectionId)

        val argv = runner.invocations.single().command
        assertTrue(argv.containsAll(listOf("service", TokenStore.SERVICE_NAME)))
        assertTrue(argv.containsAll(listOf("account", connectionId.toString().lowercase())))
    }

    @Test
    fun `bedrock uses its own reserved account`() {
        val runner = FakeRunner()
        TokenStore(runner).saveBedrockToken("k")
        assertTrue(runner.invocations.single().command.contains(TokenStore.BEDROCK_ACCOUNT))
    }

    /**
     * The Bedrock account name must not be able to collide with a connection
     * account, or clearing one would clear the other.
     */
    @Test
    fun `bedrock account is not a valid uuid`() {
        assertThrows(IllegalArgumentException::class.java) {
            UUID.fromString(TokenStore.BEDROCK_ACCOUNT)
        }
    }

    @Test
    fun `saving an empty bedrock token clears it instead of storing empty`() {
        val runner = FakeRunner()
        TokenStore(runner).saveBedrockToken("")
        assertEquals("clear", runner.invocations.single().command[1])
    }

    @Test
    fun `delete does not throw when the entry is absent`() {
        val runner = FakeRunner(exitCode = 1)
        TokenStore(runner).deleteToken(connectionId)
        assertEquals("clear", runner.invocations.single().command[1])
    }
}
