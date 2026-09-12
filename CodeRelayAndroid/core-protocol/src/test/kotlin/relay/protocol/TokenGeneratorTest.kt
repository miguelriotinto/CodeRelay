package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class TokenGeneratorTest {
    @Test fun `plaintext is 43 chars base64url without padding or unsafe chars`() {
        val (plaintext, _) = TokenGenerator.generate()
        assertEquals(43, plaintext.length)
        assertFalse(plaintext.contains('='), "no padding")
        assertFalse(plaintext.contains('+'), "no + (base64url uses -)")
        assertFalse(plaintext.contains('/'), "no / (base64url uses _)")
    }

    @Test fun `hash is 64 lowercase hex chars`() {
        val (plaintext, hash) = TokenGenerator.generate()
        assertEquals(64, hash.length)
        assertTrue(hash.all { it in "0123456789abcdef" }, "lowercase hex only")
        assertEquals(hash, TokenGenerator.hash(plaintext))
    }

    @Test fun `validate matches the right token and rejects others`() {
        val (plaintext, hash) = TokenGenerator.generate()
        assertTrue(TokenGenerator.validate(plaintext, hash))
        assertFalse(TokenGenerator.validate("not-the-token", hash))
    }

    @Test fun `hash matches known SHA-256 vector`() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            TokenGenerator.hash("abc"),
        )
    }
}
