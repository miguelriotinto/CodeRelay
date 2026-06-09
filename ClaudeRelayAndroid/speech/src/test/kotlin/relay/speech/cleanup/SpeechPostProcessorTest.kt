package relay.speech.cleanup

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import relay.speech.ProcessedText
import relay.speech.SpeechProcessingOptions

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/SpeechPostProcessorTests.swift`.
 *
 * The enhance/clean operations are injected as suspend lambdas via fakes; the
 * tests pin the EXACT Swift branch order (short-circuit → enhance →
 * refused-special-case → clean → passthrough, never-throws).
 */
class SpeechPostProcessorTest {

    /** Stub cleaner: records calls, returns [result] or throws if [shouldThrow]. */
    private class StubCleaner {
        var result: String = "cleaned-default"
        var shouldThrow: Boolean = false
        var callCount: Int = 0

        suspend fun clean(text: String): String {
            callCount++
            if (shouldThrow) throw RuntimeException("cleaner boom")
            return result
        }
    }

    /** Mock enhancer: records calls/last-token/last-region, returns [resultToReturn] or throws [errorToThrow]. */
    private class MockEnhancer {
        var resultToReturn: String = "enhanced-default"
        var errorToThrow: Throwable? = null
        var callCount: Int = 0
        var lastToken: String? = null
        var lastRegion: String? = null

        suspend fun enhance(text: String, bearerToken: String, region: String): String {
            callCount++
            lastToken = bearerToken
            lastRegion = region
            errorToThrow?.let { throw it }
            return resultToReturn
        }
    }

    private fun makeProcessor(
        cleaner: StubCleaner = StubCleaner(),
        enhancer: MockEnhancer = MockEnhancer(),
    ): SpeechPostProcessor = SpeechPostProcessor(
        enhance = { t, token, region -> enhancer.enhance(t, token, region) },
        clean = { t -> cleaner.clean(t) },
    )

    @Test
    fun `empty input returns empty`() = runTest {
        val result = makeProcessor().process("", SpeechProcessingOptions())
        assertEquals(ProcessedText.Empty, result)
    }

    @Test
    fun `single word short-circuits to empty before any work`() = runTest {
        val cleaner = StubCleaner()
        val enhancer = MockEnhancer()
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
        )
        val result = makeProcessor(cleaner, enhancer).process("hello", opts)
        assertEquals(ProcessedText.Empty, result)
        assertEquals(0, cleaner.callCount)
        assertEquals(0, enhancer.callCount)
    }

    @Test
    fun `known hallucination returns empty before any work`() = runTest {
        val cleaner = StubCleaner()
        val enhancer = MockEnhancer()
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
        )
        val result = makeProcessor(cleaner, enhancer).process("Thank you", opts)
        assertEquals(ProcessedText.Empty, result)
        assertEquals(0, cleaner.callCount)
        assertEquals(0, enhancer.callCount)
    }

    @Test
    fun `passthrough when both flags disabled`() = runTest {
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = false,
            promptEnhancementEnabled = false,
        )
        val result = makeProcessor().process("hello world", opts)
        assertEquals(ProcessedText.Passthrough("hello world"), result)
    }

    @Test
    fun `cleanup case returns cleaned`() = runTest {
        val cleaner = StubCleaner().apply { result = "cleaned" }
        val result = makeProcessor(cleaner = cleaner).process("um hello", SpeechProcessingOptions())
        assertEquals(ProcessedText.Cleaned("cleaned"), result)
        assertEquals(1, cleaner.callCount)
    }

    @Test
    fun `cleanup failure falls back to passthrough`() = runTest {
        val cleaner = StubCleaner().apply { shouldThrow = true }
        val result = makeProcessor(cleaner = cleaner).process("um hello", SpeechProcessingOptions())
        assertEquals(ProcessedText.Passthrough("um hello"), result)
    }

    @Test
    fun `enhancement takes precedence over cleanup`() = runTest {
        val cleaner = StubCleaner().apply { result = "cleaned" }
        val enhancer = MockEnhancer().apply { resultToReturn = "enhanced" }
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
            // Non-default region — the AWS Bedrock endpoint construction depends on
            // it, so assert it reaches enhance() (SpeechPostProcessor.kt:44 passes
            // `options.bedrockRegion` through).
            bedrockRegion = "eu-west-1",
        )
        val result = makeProcessor(cleaner, enhancer).process("hello world", opts)
        assertEquals(ProcessedText.Enhanced("enhanced"), result)
        assertEquals(0, cleaner.callCount)
        assertEquals(1, enhancer.callCount)
        assertEquals("token", enhancer.lastToken)
        assertEquals("eu-west-1", enhancer.lastRegion)
    }

    @Test
    fun `enhancement refusal returns refused and does NOT fall through to cleanup`() = runTest {
        val cleaner = StubCleaner().apply { result = "cleaned" }
        val enhancer = MockEnhancer().apply { errorToThrow = EnhancerError.Refused }
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
        )
        val result = makeProcessor(cleaner, enhancer).process("hello world", opts)
        assertEquals(ProcessedText.Refused(original = "hello world"), result)
        assertEquals(0, cleaner.callCount)
    }

    @Test
    fun `enhancement other error falls back to cleanup`() = runTest {
        val cleaner = StubCleaner().apply { result = "cleaned" }
        val enhancer = MockEnhancer().apply { errorToThrow = RuntimeException("timeout") }
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
        )
        val result = makeProcessor(cleaner, enhancer).process("hello world", opts)
        assertEquals(ProcessedText.Cleaned("cleaned"), result)
    }

    @Test
    fun `enhancement other error with cleanup disabled falls back to passthrough`() = runTest {
        val enhancer = MockEnhancer().apply { errorToThrow = RuntimeException("timeout") }
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = false,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
        )
        val result = makeProcessor(enhancer = enhancer).process("hello world", opts)
        assertEquals(ProcessedText.Passthrough("hello world"), result)
    }

    @Test
    fun `empty token skips enhancement and uses cleanup`() = runTest {
        val cleaner = StubCleaner().apply { result = "cleaned" }
        val enhancer = MockEnhancer()
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "",
        )
        val result = makeProcessor(cleaner, enhancer).process("hello world", opts)
        assertEquals(ProcessedText.Cleaned("cleaned"), result)
        assertEquals(0, enhancer.callCount)
    }

    @Test
    fun `never throws when both enhance and clean throw`() = runTest {
        val cleaner = StubCleaner().apply { shouldThrow = true }
        val enhancer = MockEnhancer().apply { errorToThrow = RuntimeException("boom") }
        val opts = SpeechProcessingOptions(
            smartCleanupEnabled = true,
            promptEnhancementEnabled = true,
            bedrockBearerToken = "token",
        )
        val result = makeProcessor(cleaner, enhancer).process("hello world", opts)
        // Enhancer throws (non-refusal) -> cleanup -> cleaner throws -> passthrough original.
        assertEquals(ProcessedText.Passthrough("hello world"), result)
    }
}
