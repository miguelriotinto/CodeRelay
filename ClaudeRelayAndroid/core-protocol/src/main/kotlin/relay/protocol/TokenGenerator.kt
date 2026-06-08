package relay.protocol

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * Generates cryptographically secure API tokens and provides hashing/validation
 * utilities.
 *
 * Ports `TokenGenerator.swift`: 32 secure-random bytes → Base64URL (no padding,
 * 43 chars) plaintext, plus its lowercase-hex SHA-256 digest (64 chars). The
 * Swift type also builds a `TokenInfo`; here [generate] returns the
 * `(plaintext, hash)` pair the Android client needs.
 */
object TokenGenerator {
    private val secureRandom = SecureRandom()
    private val urlEncoder = Base64.getUrlEncoder().withoutPadding()

    /**
     * Generates a new random token.
     *
     * @return `Pair(plaintext, hash)` — the 43-char Base64URL plaintext and its
     *   64-char lowercase-hex SHA-256 digest.
     */
    fun generate(): Pair<String, String> {
        val bytes = ByteArray(32)
        secureRandom.nextBytes(bytes)
        val plaintext = urlEncoder.encodeToString(bytes)
        return plaintext to hash(plaintext)
    }

    /** Computes the lowercase-hex SHA-256 digest of [token]. */
    fun hash(token: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    /** Validates [token] against a previously stored SHA-256 hex [storedHash]. */
    fun validate(token: String, storedHash: String): Boolean = hash(token) == storedHash
}
