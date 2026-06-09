package relay.speech.cleanup

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Pure-helper tests for [CloudPromptEnhancer]. The network call itself cannot run
 * headless, but the refusal detection, Bearer redaction, request build, and
 * response parse are all pure functions ported from
 * `Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift`.
 */
class CloudPromptEnhancerTest {

    // MARK: - Constants pinned to the Swift source

    @Test
    fun `model id and inference constants match swift source`() {
        assertEquals("us.anthropic.claude-haiku-4-5-20251001-v1:0", CloudPromptEnhancer.DEFAULT_MODEL_ID)
        assertEquals(512, CloudPromptEnhancer.MAX_TOKENS)
        assertEquals(0.3, CloudPromptEnhancer.TEMPERATURE)
    }

    @Test
    fun `default enhancer uses default model id`() {
        assertEquals(CloudPromptEnhancer.DEFAULT_MODEL_ID, CloudPromptEnhancer().modelId)
    }

    @Test
    fun `refusal prefix and phrase set sizes match swift`() {
        assertEquals(18, CloudPromptEnhancer.refusalPrefixes.size)
        assertEquals(6, CloudPromptEnhancer.refusalPhrases.size)
    }

    // MARK: - Refusal detection

    @Test
    fun `detects refusal by prefix case insensitively`() {
        assertTrue(CloudPromptEnhancer.detectRefusal("I cannot enhance this vague request"))
        assertTrue(CloudPromptEnhancer.detectRefusal("i can't enhance that"))
        assertTrue(CloudPromptEnhancer.detectRefusal("Please provide the file you want reviewed"))
        assertTrue(CloudPromptEnhancer.detectRefusal("What specifically do you want?"))
    }

    @Test
    fun `detects refusal by phrase substring`() {
        assertTrue(CloudPromptEnhancer.detectRefusal("The request is unclear to me"))
        assertTrue(CloudPromptEnhancer.detectRefusal("To help I need more context about the task"))
    }

    @Test
    fun `accepts a genuine enhanced prompt`() {
        assertFalse(
            CloudPromptEnhancer.detectRefusal(
                "Review the repository and identify simple performance improvements.",
            ),
        )
        assertFalse(CloudPromptEnhancer.detectRefusal("List the files in the current directory."))
    }

    // MARK: - Bearer redaction

    @Test
    fun `redacts bearer token from non-json error body`() {
        val body = "Auth failed for Authorization: Bearer sk-abc123XYZ._-/= rest of message"
        val sanitized = CloudPromptEnhancer.sanitizeBedrockError(body)
        assertFalse(sanitized.contains("sk-abc123XYZ"), "Token must be redacted")
        assertTrue(sanitized.contains("Bearer [REDACTED]"))
    }

    @Test
    fun `extracts message field from json error body`() {
        val body = """{"message":"The provided model identifier is invalid","__type":"ValidationException"}"""
        assertEquals("The provided model identifier is invalid", CloudPromptEnhancer.sanitizeBedrockError(body))
    }

    @Test
    fun `caps sanitized error at 200 chars`() {
        val long = "Bearer-free error " + "x".repeat(500)
        assertEquals(200, CloudPromptEnhancer.sanitizeBedrockError(long).length)
    }

    // MARK: - Request build

    @Test
    fun `request body matches bedrock converse shape`() {
        val body = CloudPromptEnhancer.buildRequestBody("list the files")

        val systemText = body["system"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content
        assertEquals(CloudPromptEnhancer.SYSTEM_PROMPT, systemText)

        val message = body["messages"]!!.jsonArray[0].jsonObject
        assertEquals("user", message["role"]!!.jsonPrimitive.content)
        val userText = message["content"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content
        assertEquals("Enhance this into a clear prompt:\nlist the files", userText)

        val config = body["inferenceConfig"]!!.jsonObject
        assertEquals(512, config["maxTokens"]!!.jsonPrimitive.content.toInt())
        assertEquals(0.3, config["temperature"]!!.jsonPrimitive.content.toDouble())
    }

    // MARK: - Response parse

    @Test
    fun `parses text from converse response`() {
        val response = """
            {"output":{"message":{"role":"assistant","content":[{"text":"  Review the repo.  "}]}}}
        """.trimIndent()
        assertEquals("Review the repo.", CloudPromptEnhancer.parseResponse(response))
    }

    @Test
    fun `parse throws invalid response on bad shape`() {
        try {
            CloudPromptEnhancer.parseResponse("""{"unexpected":true}""")
            throw AssertionError("expected InvalidResponse")
        } catch (e: EnhancerError.InvalidResponse) {
            // expected
        }
    }
}
