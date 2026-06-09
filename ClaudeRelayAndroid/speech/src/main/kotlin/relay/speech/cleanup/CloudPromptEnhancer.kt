package relay.speech.cleanup

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Protocol for cloud-based prompt enhancement — enables mock injection and is the
 * target of [SpeechPostProcessor]'s `enhance` lambda.
 *
 * Mirrors Swift `CloudEnhancing`.
 */
fun interface CloudEnhancing {
    suspend fun enhance(text: String, bearerToken: String, region: String): String
}

/**
 * Calls the AWS Bedrock Converse API with Claude Haiku to enhance transcribed
 * speech into a clear, actionable prompt. Requires a bearer token.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift`. Makes
 * real network calls (cannot run headless), but the JSON request build, response
 * parse, refusal-detection, and Bearer-redaction helpers are pure and unit-tested.
 *
 * @property modelId the Bedrock model/inference-profile ID. Defaults to
 *   [DEFAULT_MODEL_ID]; override per instance to target a newer Haiku.
 */
class CloudPromptEnhancer(
    val modelId: String = DEFAULT_MODEL_ID,
    private val client: OkHttpClient = defaultClient(),
) : CloudEnhancing {

    override suspend fun enhance(text: String, bearerToken: String, region: String): String {
        if (bearerToken.isEmpty()) throw EnhancerError.MissingBearerToken

        val url = "https://bedrock-runtime.$region.amazonaws.com/model/$modelId/converse"

        val request = Request.Builder()
            .url(url)
            .addHeader("Content-Type", "application/json")
            .addHeader("Authorization", "Bearer $bearerToken")
            .post(buildRequestBody(text).toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()

        val (statusCode, responseBody) = withContext(Dispatchers.IO) {
            client.newCall(request).execute().use { response ->
                response.code to (response.body?.string() ?: "")
            }
        }

        if (statusCode != 200) {
            throw EnhancerError.BedrockError(statusCode, sanitizeBedrockError(responseBody))
        }

        val enhanced = parseResponse(responseBody)

        if (detectRefusal(enhanced)) throw EnhancerError.Refused

        return enhanced
    }

    companion object {
        /**
         * Bedrock cross-region inference profile for Claude Haiku. On-demand
         * throughput requires an inference profile ID, not the raw model ID.
         */
        const val DEFAULT_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

        const val MAX_TOKENS = 512
        const val TEMPERATURE = 0.3
        private const val TIMEOUT_SECONDS = 15L

        private val JSON_MEDIA_TYPE = "application/json".toMediaType()
        private val json = Json { ignoreUnknownKeys = true }

        private fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .callTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .connectTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .writeTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .build()

        /** System prompt that guides Haiku to enhance while staying faithful to intent. */
        val SYSTEM_PROMPT = """
            You are a prompt enhancement engine. Your job is to take rough speech-to-text input and sharpen it into a clear, well-structured instruction — while staying faithful to the speaker's original intent.

            Rules:
            - Stay close to the original meaning — enhance clarity, do not change the task
            - Remove filler words, hesitation, and vague hedging
            - Make implicit expectations explicit (e.g. "do a review" → "review and identify issues")
            - Add reasonable scope qualifiers when the speaker's intent is obvious (e.g. "improve performance" → "identify performance improvement opportunities")
            - Preserve ALL technical details exactly (file names, function names, error messages, paths)
            - Keep it concise — one focused instruction, not a paragraph
            - Do NOT invent requirements the speaker did not mention
            - Do NOT add commentary, explanation, or preamble
            - Output ONLY the enhanced prompt, nothing else

            Example:
            Input: "please do a review of this repo and improve the performance"
            Output: "Review the repository and identify simple performance improvement opportunities. Focus on obvious inefficiencies and provide concise, actionable suggestions."
        """.trimIndent()

        /** Build the Bedrock Converse request body. Pure — testable without a network. */
        fun buildRequestBody(text: String): JsonObject = buildJsonObject {
            putJsonArray("system") {
                addJsonObject { put("text", SYSTEM_PROMPT) }
            }
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject { put("text", "Enhance this into a clear prompt:\n$text") }
                    }
                }
            }
            put(
                "inferenceConfig",
                buildJsonObject {
                    put("maxTokens", MAX_TOKENS)
                    put("temperature", TEMPERATURE)
                },
            )
        }

        /**
         * Parse the Bedrock Converse response to extract
         * `output.message.content[0].text`. Pure. Throws [EnhancerError.InvalidResponse]
         * on any shape mismatch.
         */
        fun parseResponse(body: String): String {
            try {
                val text = json.parseToJsonElement(body)
                    .jsonObject["output"]!!
                    .jsonObject["message"]!!
                    .jsonObject["content"]!!
                    .jsonArray[0]
                    .jsonObject["text"]!!
                    .jsonPrimitive.content
                return text.trim()
            } catch (e: Exception) {
                throw EnhancerError.InvalidResponse
            }
        }

        /** Prefixes that reveal Haiku is refusing / asking for clarification instead of enhancing. */
        val refusalPrefixes = listOf(
            "I cannot enhance",
            "I can't enhance",
            "I'm unable to enhance",
            "I need actual",
            "I need more",
            "Need actual",
            "Need more",
            "This is not",
            "This isn't",
            "This doesn't appear",
            "This does not appear",
            "If you have a task",
            "Please provide",
            "I'd need",
            "I would need",
            "Could you clarify",
            "Can you clarify",
            "What specifically",
        )

        /** Substrings that reveal Haiku is asking clarifying questions instead of enhancing. */
        val refusalPhrases = listOf(
            "could you clarify",
            "is unclear",
            "what is \"this\"",
            "provide those details",
            "need more context",
            "need more details",
        )

        /**
         * Returns true if the enhanced output is actually a refusal / clarifying
         * question rather than a rewritten prompt. Pure, case-insensitive.
         */
        fun detectRefusal(enhanced: String): Boolean {
            val lowered = enhanced.lowercase()
            if (refusalPrefixes.any { lowered.startsWith(it.lowercase()) }) return true
            if (refusalPhrases.any { lowered.contains(it) }) return true
            return false
        }

        /**
         * Strips auth material and returns at most 200 characters of the Bedrock
         * error body. When the response is JSON-shaped we extract the `message`
         * field; otherwise we return a length-capped copy with any `Bearer <token>`
         * fragments redacted. Pure.
         */
        fun sanitizeBedrockError(body: String): String {
            try {
                val msg = json.parseToJsonElement(body).jsonObject["message"]?.jsonPrimitive?.content
                if (msg != null) return msg.take(200)
            } catch (_: Exception) {
                // Not JSON-shaped; fall through to redaction.
            }
            val truncated = body.take(200)
            return truncated.replace(
                Regex("Bearer [A-Za-z0-9+/=._-]+"),
                "Bearer [REDACTED]",
            )
        }
    }
}

/** Errors thrown by [CloudPromptEnhancer]. Mirrors Swift `EnhancerError`. */
sealed class EnhancerError(message: String) : Exception(message) {
    data object MissingBearerToken :
        EnhancerError("Bearer token not configured. Add it in Settings.")

    data object InvalidResponse : EnhancerError("Invalid response from Bedrock")
    data object Refused : EnhancerError("Could not enhance — input was unclear.")
    data class BedrockError(val statusCode: Int, val sanitizedMessage: String) :
        EnhancerError("Bedrock error $statusCode: $sanitizedMessage")
}
