package relay.feature.settings

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Verifies the exact `.drop(1).debounce(500)` pipeline `AppSettings` installs for
 * the Bedrock token (after seeding) reproduces the iOS
 * `$bedrockBearerToken.dropFirst().debounce(500ms)` semantic
 * (AppSettings.swift:18-24):
 *  - the seed value (the StateFlow's current value, replayed to the collector) is
 *    NOT written;
 *  - rapid edits within one window collapse into a single write of the final value.
 *
 * The real DataStore + EncryptedSharedPreferences round-trip is instrumented and
 * DEVICE-DEFERRED; this exercises only the headless flow shape, which is the
 * load-bearing part of the contract. The never-completing collector is launched on
 * the test scope and explicitly cancelled before the test body returns; `runCurrent`
 * pumps it so it subscribes and drops the replayed seed before the first mutation,
 * defeating StateFlow conflation.
 */
@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class BedrockDebounceFlowTest {

    @Test
    fun `seed value is dropped and only the final edit is written`() = runTest {
        // Seed already applied, mirroring AppSettings installing the collector
        // AFTER runMigrations() set the seed.
        val token = MutableStateFlow("seed-from-store")
        val writes = mutableListOf<String>()

        val job = token.drop(1)
            .debounce(AppSettings.BEDROCK_DEBOUNCE_MS)
            .onEach { writes.add(it) }
            .launchIn(this)

        // Pump so the collector subscribes and consumes (drops) the replayed seed
        // value BEFORE we mutate — otherwise StateFlow conflation could collapse
        // the seed and the first edit together.
        runCurrent()
        assertEquals(emptyList<String>(), writes, "seed must not be written (dropFirst)")

        // Rapid typing: three edits inside one debounce window.
        token.value = "p"
        advanceTimeBy(100)
        runCurrent()
        token.value = "pa"
        advanceTimeBy(100)
        runCurrent()
        token.value = "pass"
        // Cross the debounce window so the final value emits.
        advanceTimeBy(AppSettings.BEDROCK_DEBOUNCE_MS + 1)
        runCurrent()

        // Only the final value is written once (debounce collapse).
        assertEquals(listOf("pass"), writes)

        job.cancel()
    }
}
