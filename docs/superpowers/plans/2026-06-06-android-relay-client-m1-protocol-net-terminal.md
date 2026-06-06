# Android Relay Client — M1: Protocol, Networking & Live Terminal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working Android app that connects to a Claude Relay server, authenticates, creates/attaches a session, and shows a live, interactive terminal — proving the frozen wire protocol end-to-end.

**Architecture:** Standalone Kotlin/Compose client. Modules `:core-protocol` (wire models + envelope serializer), `:core-net` (OkHttp WebSocket transport with app-level ping/pong, quality, generation counter), `:core-storage` (encrypted token + bookmark storage), `:terminal` (Termux engine wrapped + replay protocol), and a thin `:app` to wire a single hard-coded connection for M1. Recovery is deferred to M2.

**Tech Stack:** Kotlin, Gradle KTS, Jetpack Compose + Material 3, OkHttp, kotlinx.serialization, Coroutines/StateFlow, Hilt, EncryptedSharedPreferences, Termux `terminal-emulator`+`terminal-view`, JUnit5 + Turbine + MockK.

**Swift source of truth (read these before porting):**
- `Sources/ClaudeRelayKit/Protocol/MessageEnvelope.swift`, `ClientMessage.swift`, `ServerMessage.swift`
- `Sources/ClaudeRelayKit/Models/SessionInfo.swift`, `SessionState.swift`, `ActivityState.swift`, `ConnectionQuality.swift`
- `Sources/ClaudeRelayClient/RelayConnection.swift`, `SessionController.swift`, `ConnectionConfig.swift`, `AuthManager.swift`

---

## File Structure (created in M1)

```
ClaudeRelayAndroid/
├── settings.gradle.kts
├── build.gradle.kts                          # root, version catalog refs
├── gradle/libs.versions.toml                 # version catalog
├── core-protocol/
│   └── src/main/kotlin/relay/protocol/
│       ├── ConnectionConfig.kt
│       ├── SessionState.kt
│       ├── ActivityState.kt
│       ├── ConnectionQuality.kt
│       ├── SessionInfo.kt
│       ├── ClientMessage.kt
│       ├── ServerMessage.kt
│       ├── MessageEnvelope.kt                 # custom serializer, type lookup
│       ├── WireJson.kt                        # configured Json instance + UUID/Double-date serializers
│       └── TokenGenerator.kt
│   └── src/test/kotlin/relay/protocol/        # unit + contract tests
├── core-net/
│   └── src/main/kotlin/relay/net/
│       ├── RelayConnection.kt
│       ├── SessionController.kt
│       ├── ResumeGuard.kt
│       └── NetworkConfinement.kt              # single-thread dispatcher helper
│   └── src/test/kotlin/relay/net/
├── core-storage/
│   └── src/main/kotlin/relay/storage/
│       ├── TokenStore.kt                      # EncryptedSharedPreferences
│       ├── SavedConnectionStore.kt            # DataStore
│       └── DeviceIdentifier.kt
│   └── src/test/kotlin/relay/storage/
├── terminal/
│   └── src/main/kotlin/relay/terminal/
│       ├── TerminalSessionVm.kt               # port of TerminalViewModel buffering machine
│       ├── ReplayProtocol.kt                  # bytes constants (RIS) + helpers
│       └── RelayTerminalView.kt               # wraps Termux TerminalView (later task)
│   └── src/test/kotlin/relay/terminal/
└── app/
    └── src/main/kotlin/relay/app/
        ├── RelayApplication.kt
        ├── MainActivity.kt
        └── M1DemoScreen.kt                    # hard-coded connect + terminal (replaced in M2)
```

---

## Task 1: Project scaffold

**Files:**
- Create: `ClaudeRelayAndroid/settings.gradle.kts`
- Create: `ClaudeRelayAndroid/build.gradle.kts`
- Create: `ClaudeRelayAndroid/gradle/libs.versions.toml`
- Create: `ClaudeRelayAndroid/core-protocol/build.gradle.kts`

- [ ] **Step 1: Create the Android project in Android Studio**

Use Android Studio → New Project → "No Activity", name `ClaudeRelayAndroid`, package `relay`, language Kotlin, build config Kotlin DSL, **minSdk = 28** (pin the spec's 26–28 range to 28 for simpler Keystore + foreground-service-type behavior), targetSdk = latest stable.

- [ ] **Step 2: Define the version catalog**

Create `gradle/libs.versions.toml` with the M1 dependencies:

```toml
[versions]
kotlin = "2.0.21"
coroutines = "1.9.0"
serialization = "1.7.3"
okhttp = "4.12.0"
compose-bom = "2024.10.00"
hilt = "2.52"
datastore = "1.1.1"
security-crypto = "1.1.0-alpha06"
junit5 = "5.11.3"
turbine = "1.2.0"
mockk = "1.13.13"

[libraries]
kotlinx-coroutines-core = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-core", version.ref = "coroutines" }
kotlinx-coroutines-android = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-android", version.ref = "coroutines" }
kotlinx-serialization-json = { module = "org.jetbrains.kotlinx:kotlinx-serialization-json", version.ref = "serialization" }
okhttp = { module = "com.squareup.okhttp3:okhttp", version.ref = "okhttp" }
okhttp-mockwebserver = { module = "com.squareup.okhttp3:mockwebserver", version.ref = "okhttp" }
datastore-preferences = { module = "androidx.datastore:datastore-preferences", version.ref = "datastore" }
security-crypto = { module = "androidx.security:security-crypto", version.ref = "security-crypto" }
junit5-api = { module = "org.junit.jupiter:junit-jupiter-api", version.ref = "junit5" }
junit5-engine = { module = "org.junit.jupiter:junit-jupiter-engine", version.ref = "junit5" }
turbine = { module = "app.cash.turbine:turbine", version.ref = "turbine" }
mockk = { module = "io.mockk:mockk", version.ref = "mockk" }
kotlinx-coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutines" }
```

- [ ] **Step 3: Configure `:core-protocol` module**

Create `core-protocol/build.gradle.kts`:

```kotlin
plugins {
    alias(libs.plugins.kotlin.jvm)            // pure-JVM module, no Android deps
    alias(libs.plugins.kotlin.serialization)
}
dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
}
tasks.test { useJUnitPlatform() }
```

(Define the `kotlin.jvm` and `kotlin.serialization` plugins in the `[plugins]` table of the catalog.)

- [ ] **Step 4: Verify the project builds**

Run: `./gradlew :core-protocol:compileKotlin`
Expected: BUILD SUCCESSFUL (empty module compiles).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(android): scaffold project + core-protocol module"
```

---

## Task 2: `WireJson` — configured Json + UUID & Double-date serializers

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/WireJson.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/WireJsonTest.kt`

> **Why this matters (from spec corrections):** the WS path uses Swift's default `JSONEncoder` → `Date` encodes as a **Double** (seconds since the reference date), NOT ISO-8601. UUID encodes as a canonical lowercase-hyphenated string. We need explicit serializers for both, and a `Json` instance that does NOT auto-rename fields.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.util.UUID

class WireJsonTest {
    @Serializable
    private data class Holder(
        @Serializable(with = UuidSerializer::class) val id: UUID,
    )

    @Test
    fun `uuid encodes as lowercase hyphenated string`() {
        val id = UUID.fromString("550E8400-E29B-41D4-A716-446655440000")
        val json = WireJson.instance.encodeToString(Holder(id))
        assertEquals("""{"id":"550e8400-e29b-41d4-a716-446655440000"}""", json)
    }

    @Test
    fun `uuid round-trips`() {
        val id = UUID.randomUUID()
        val json = WireJson.instance.encodeToString(Holder(id))
        val back = WireJson.instance.decodeFromString<Holder>(json)
        assertEquals(id, back.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.WireJsonTest"`
Expected: FAIL — `UuidSerializer` and `WireJson` unresolved.

- [ ] **Step 3: Implement `WireJson.kt`**

```kotlin
package relay.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.util.UUID

/** Canonical lowercase-hyphenated UUID string, matching Swift's `UUID` Codable. */
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: UUID) =
        encoder.encodeString(value.toString().lowercase())
    override fun deserialize(decoder: Decoder): UUID =
        UUID.fromString(decoder.decodeString())
}

/**
 * Swift's default JSONEncoder encodes `Date` as a Double: seconds since the
 * reference date (2001-01-01) on the WS path. We store the epoch-relative value
 * verbatim as a Double — M1 Task 9 (contract test) validates the exact value
 * against a captured live server frame. Until then, treat it as an opaque
 * "seconds" Double; the UI only needs relative ordering + uptime, not wall time.
 */
object ReferenceDateDoubleSerializer : KSerializer<Double> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RefDate", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Double) = encoder.encodeDouble(value)
    override fun deserialize(decoder: Decoder): Double = decoder.decodeDouble()
}

object WireJson {
    /** Field names are pinned via @SerialName; do NOT enable namingStrategy. */
    val instance: Json = Json {
        ignoreUnknownKeys = true        // forward-compat within a protocol version
        encodeDefaults = false          // matches Swift encodeIfPresent omission
        explicitNulls = false           // missing == null on decode; omit on encode
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.WireJsonTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(protocol): WireJson with UUID + reference-date serializers"
```

---

## Task 3: Enums — `SessionState`, `ActivityState`, `ConnectionQuality`

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/SessionState.kt`
- Create: `core-protocol/src/main/kotlin/relay/protocol/ActivityState.kt`
- Create: `core-protocol/src/main/kotlin/relay/protocol/ConnectionQuality.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/EnumsTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class EnumsTest {
    @Test fun `session state raw values are hyphenated`() {
        assertEquals("active-attached", SessionState.ACTIVE_ATTACHED.raw)
        assertEquals(SessionState.ACTIVE_DETACHED, SessionState.fromRaw("active-detached"))
    }
    @Test fun `session state terminal set`() {
        assertTrue(SessionState.TERMINATED.isTerminal)
        assertFalse(SessionState.ACTIVE_ATTACHED.isTerminal)
    }
    @Test fun `activity state decodes legacy claude names`() {
        assertEquals(ActivityState.AGENT_ACTIVE, ActivityState.fromRaw("claude_active"))
        assertEquals(ActivityState.AGENT_IDLE, ActivityState.fromRaw("claude_idle"))
        assertEquals(ActivityState.AGENT_ACTIVE, ActivityState.fromRaw("agent_active"))
    }
    @Test fun `activity state unknown defaults to active`() {
        assertEquals(ActivityState.ACTIVE, ActivityState.fromRaw("nonsense"))
    }
    @Test fun `activity state always encodes modern names`() {
        assertEquals("agent_active", ActivityState.AGENT_ACTIVE.raw)
    }
    @Test fun `connection quality thresholds`() {
        assertEquals(ConnectionQuality.EXCELLENT, ConnectionQuality.of(medianRttSec = 0.05, successRate = 1.0))
        assertEquals(ConnectionQuality.GOOD, ConnectionQuality.of(0.2, 0.83))
        assertEquals(ConnectionQuality.POOR, ConnectionQuality.of(0.5, 0.6))
        assertEquals(ConnectionQuality.VERY_POOR, ConnectionQuality.of(0.05, 0.4))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.EnumsTest"`
Expected: FAIL — unresolved references.

- [ ] **Step 3: Implement the three enums**

`SessionState.kt` (port of `SessionState.swift`):

```kotlin
package relay.protocol

enum class SessionState(val raw: String) {
    CREATED("created"),
    STARTING("starting"),
    ACTIVE_ATTACHED("active-attached"),
    ACTIVE_DETACHED("active-detached"),
    RESUMING("resuming"),
    EXITED("exited"),
    FAILED("failed"),
    TERMINATED("terminated"),
    EXPIRED("expired");

    val isTerminal: Boolean
        get() = this == EXITED || this == FAILED || this == TERMINATED || this == EXPIRED

    companion object {
        fun fromRaw(value: String): SessionState =
            entries.firstOrNull { it.raw == value } ?: CREATED
    }
}
```

`ActivityState.kt` (port of `ActivityState.swift`, incl. legacy decode):

```kotlin
package relay.protocol

enum class ActivityState(val raw: String) {
    ACTIVE("active"),
    IDLE("idle"),
    AGENT_ACTIVE("agent_active"),
    AGENT_IDLE("agent_idle");

    val isAgentRunning: Boolean get() = this == AGENT_ACTIVE || this == AGENT_IDLE
    val isAwaitingInput: Boolean get() = this == IDLE || this == AGENT_IDLE

    companion object {
        /** Accepts legacy claude_* values on decode; unknown -> ACTIVE (never throws). */
        fun fromRaw(value: String): ActivityState = when (value) {
            "active" -> ACTIVE
            "idle" -> IDLE
            "agent_active", "claude_active" -> AGENT_ACTIVE
            "agent_idle", "claude_idle" -> AGENT_IDLE
            else -> ACTIVE
        }
    }
}
```

`ConnectionQuality.kt` (port of `ConnectionQuality.swift` thresholds verbatim):

```kotlin
package relay.protocol

enum class ConnectionQuality {
    EXCELLENT, GOOD, POOR, VERY_POOR, DISCONNECTED;

    companion object {
        private const val EXCELLENT_RTT = 0.1
        private const val GOOD_RTT = 0.3
        private const val POOR_RTT = 0.8
        private const val MIN_SUCCESS = 0.5
        private const val GOOD_SUCCESS = 0.83
        private const val PERFECT_SUCCESS = 1.0

        fun of(medianRttSec: Double, successRate: Double): ConnectionQuality = when {
            successRate < MIN_SUCCESS -> VERY_POOR
            medianRttSec < EXCELLENT_RTT && successRate >= PERFECT_SUCCESS -> EXCELLENT
            medianRttSec < GOOD_RTT && successRate >= GOOD_SUCCESS -> GOOD
            medianRttSec < POOR_RTT && successRate >= MIN_SUCCESS -> POOR
            else -> VERY_POOR
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.EnumsTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(protocol): SessionState, ActivityState, ConnectionQuality"
```

---

## Task 4: `SessionInfo` model

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/SessionInfo.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/SessionInfoTest.kt`

> Port of `SessionInfo.swift`. Note `state`/`activity` serialize as their raw strings; `createdAt` is a Double; `name`/`activity`/`agent` optional.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import kotlinx.serialization.decodeFromString
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class SessionInfoTest {
    @Test fun `decodes a server session_info payload`() {
        val json = """
          {"id":"550e8400-e29b-41d4-a716-446655440000","name":"work",
           "state":"active-detached","tokenId":"abc123","createdAt":740000000.5,
           "cols":120,"rows":30,"activity":"agent_idle","agent":"claude"}
        """.trimIndent()
        val info = WireJson.instance.decodeFromString<SessionInfo>(json)
        assertEquals("work", info.name)
        assertEquals(SessionState.ACTIVE_DETACHED, info.state)
        assertEquals(ActivityState.AGENT_IDLE, info.activity)
        assertEquals("claude", info.agent)
        assertEquals(120, info.cols.toInt())
        assertEquals(740000000.5, info.createdAt)
    }
    @Test fun `decodes with optionals absent`() {
        val json = """
          {"id":"550e8400-e29b-41d4-a716-446655440000",
           "state":"created","tokenId":"abc","createdAt":1.0,"cols":80,"rows":24}
        """.trimIndent()
        val info = WireJson.instance.decodeFromString<SessionInfo>(json)
        assertNull(info.name); assertNull(info.activity); assertNull(info.agent)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.SessionInfoTest"`
Expected: FAIL — `SessionInfo` unresolved.

- [ ] **Step 3: Implement `SessionInfo.kt`**

```kotlin
package relay.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import java.util.UUID

private object SessionStateSerializer : KSerializer<SessionState> {
    override val descriptor = PrimitiveSerialDescriptor("SessionState", PrimitiveKind.STRING)
    override fun serialize(e: Encoder, v: SessionState) = e.encodeString(v.raw)
    override fun deserialize(d: Decoder) = SessionState.fromRaw(d.decodeString())
}
private object ActivityStateSerializer : KSerializer<ActivityState> {
    override val descriptor = PrimitiveSerialDescriptor("ActivityState", PrimitiveKind.STRING)
    override fun serialize(e: Encoder, v: ActivityState) = e.encodeString(v.raw)
    override fun deserialize(d: Decoder) = ActivityState.fromRaw(d.decodeString())
}

@Serializable
data class SessionInfo(
    @Serializable(with = UuidSerializer::class) val id: UUID,
    val name: String? = null,
    @Serializable(with = SessionStateSerializer::class) val state: SessionState,
    val tokenId: String,
    @Serializable(with = ReferenceDateDoubleSerializer::class) val createdAt: Double,
    val cols: UShort,
    val rows: UShort,
    @Serializable(with = ActivityStateSerializer::class) val activity: ActivityState? = null,
    val agent: String? = null,
)
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.SessionInfoTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(protocol): SessionInfo model"
```

---

## Task 5: `ClientMessage` + `ServerMessage` sealed interfaces

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/ClientMessage.kt`
- Create: `core-protocol/src/main/kotlin/relay/protocol/ServerMessage.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/MessageTypeTest.kt`

> Each message is a data class/object with a `typeString`. We do NOT use kotlinx polymorphism — the envelope serializer (Task 6) switches on `type` manually, mirroring Swift's `encodePayload`/`decode(typeString:)`.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class MessageTypeTest {
    @Test fun `client type strings`() {
        assertEquals("auth_request", ClientMessage.AuthRequest("t", 1).typeString)
        assertEquals("session_resume", ClientMessage.SessionResume(java.util.UUID.randomUUID(), true).typeString)
        assertEquals("ping", ClientMessage.Ping.typeString)
    }
    @Test fun `all 12 client type strings present`() {
        assertEquals(12, ClientMessage.ALL_TYPE_STRINGS.size)
    }
    @Test fun `all 18 server type strings present`() {
        assertEquals(18, ServerMessage.ALL_TYPE_STRINGS.size)
        assertTrue("session_list_result" in ServerMessage.ALL_TYPE_STRINGS)
    }
    @Test fun `client and server type strings are disjoint`() {
        assertTrue(ClientMessage.ALL_TYPE_STRINGS.intersect(ServerMessage.ALL_TYPE_STRINGS).isEmpty())
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.MessageTypeTest"`
Expected: FAIL — unresolved.

- [ ] **Step 3: Implement `ClientMessage.kt`** (port of `ClientMessage.swift`)

```kotlin
package relay.protocol

import java.util.UUID

sealed interface ClientMessage {
    val typeString: String

    data class AuthRequest(val token: String, val protocolVersion: Int? = null) : ClientMessage {
        override val typeString get() = "auth_request"
    }
    data class SessionCreate(val name: String? = null) : ClientMessage {
        override val typeString get() = "session_create"
    }
    data class SessionAttach(val sessionId: UUID) : ClientMessage {
        override val typeString get() = "session_attach"
    }
    data class SessionResume(val sessionId: UUID, val skipReplay: Boolean = false) : ClientMessage {
        override val typeString get() = "session_resume"
    }
    data object SessionDetach : ClientMessage { override val typeString get() = "session_detach" }
    data class SessionTerminate(val sessionId: UUID) : ClientMessage {
        override val typeString get() = "session_terminate"
    }
    data object SessionList : ClientMessage { override val typeString get() = "session_list" }
    data object SessionListAll : ClientMessage { override val typeString get() = "session_list_all" }
    data class SessionRename(val sessionId: UUID, val name: String) : ClientMessage {
        override val typeString get() = "session_rename"
    }
    data class Resize(val cols: UShort, val rows: UShort) : ClientMessage {
        override val typeString get() = "resize"
    }
    data class PasteImage(val data: String) : ClientMessage { override val typeString get() = "paste_image" }
    data object Ping : ClientMessage { override val typeString get() = "ping" }

    companion object {
        val ALL_TYPE_STRINGS: Set<String> = setOf(
            "auth_request", "session_create", "session_attach", "session_resume",
            "session_detach", "session_terminate", "session_list", "session_list_all",
            "session_rename", "resize", "paste_image", "ping",
        )
    }
}
```

- [ ] **Step 4: Implement `ServerMessage.kt`** (port of `ServerMessage.swift`)

```kotlin
package relay.protocol

import java.util.UUID

sealed interface ServerMessage {
    val typeString: String

    data class AuthSuccess(val protocolVersion: Int? = null) : ServerMessage { override val typeString get() = "auth_success" }
    data class AuthFailure(val reason: String) : ServerMessage { override val typeString get() = "auth_failure" }
    data class SessionCreated(val sessionId: UUID, val cols: UShort, val rows: UShort) : ServerMessage { override val typeString get() = "session_created" }
    data class SessionAttached(val sessionId: UUID, val state: String) : ServerMessage { override val typeString get() = "session_attached" }
    data class SessionResumed(val sessionId: UUID) : ServerMessage { override val typeString get() = "session_resumed" }
    data class ReplayComplete(val sessionId: UUID) : ServerMessage { override val typeString get() = "replay_complete" }
    data object SessionDetached : ServerMessage { override val typeString get() = "session_detached" }
    data class SessionTerminated(val sessionId: UUID, val reason: String) : ServerMessage { override val typeString get() = "session_terminated" }
    data class SessionExpired(val sessionId: UUID) : ServerMessage { override val typeString get() = "session_expired" }
    data class SessionStateMsg(val sessionId: UUID, val state: String) : ServerMessage { override val typeString get() = "session_state" }
    data class SessionActivity(val sessionId: UUID, val activity: ActivityState, val agent: String? = null) : ServerMessage { override val typeString get() = "session_activity" }
    data class SessionStolen(val sessionId: UUID) : ServerMessage { override val typeString get() = "session_stolen" }
    data class SessionRenamed(val sessionId: UUID, val name: String) : ServerMessage { override val typeString get() = "session_renamed" }
    data class SessionList(val sessions: List<SessionInfo>) : ServerMessage { override val typeString get() = "session_list_result" }
    data class SessionListAll(val sessions: List<SessionInfo>) : ServerMessage { override val typeString get() = "session_list_all_result" }
    data class ResizeAck(val cols: UShort, val rows: UShort) : ServerMessage { override val typeString get() = "resize_ack" }
    data class PasteImageResult(val success: Boolean) : ServerMessage { override val typeString get() = "paste_image_result" }
    data object Pong : ServerMessage { override val typeString get() = "pong" }
    data class Error(val code: Int, val message: String) : ServerMessage { override val typeString get() = "error" }

    companion object {
        val ALL_TYPE_STRINGS: Set<String> = setOf(
            "auth_success", "auth_failure", "session_created", "session_attached",
            "session_resumed", "replay_complete", "session_detached", "session_terminated",
            "session_expired", "session_state", "session_activity", "session_stolen",
            "session_renamed", "session_list_result", "session_list_all_result",
            "resize_ack", "paste_image_result", "pong", "error",
        )
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.MessageTypeTest"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(protocol): ClientMessage + ServerMessage sealed interfaces"
```

---

## Task 6: `MessageEnvelope` — encode/decode with manual payload switch

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/MessageEnvelopeTest.kt`

> The heart of wire fidelity. Encodes `{"type":..,"payload":{..}}`; payload built/parsed with explicit field handling matching Swift's `encodeIfPresent` rules (skipReplay only when true; protocolVersion/name/agent only when non-null). Decode routes on the type-origin map; unknown type throws.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.util.UUID

class MessageEnvelopeTest {
    @Test fun `encode auth_request with protocol version`() {
        val json = MessageEnvelope.encodeClient(ClientMessage.AuthRequest("tok", 1))
        assertEquals("""{"type":"auth_request","payload":{"token":"tok","protocolVersion":1}}""", json)
    }
    @Test fun `encode ping has empty payload object`() {
        assertEquals("""{"type":"ping","payload":{}}""", MessageEnvelope.encodeClient(ClientMessage.Ping))
    }
    @Test fun `encode session_resume omits skipReplay when false`() {
        val id = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        val json = MessageEnvelope.encodeClient(ClientMessage.SessionResume(id, skipReplay = false))
        assertEquals("""{"type":"session_resume","payload":{"sessionId":"550e8400-e29b-41d4-a716-446655440000"}}""", json)
    }
    @Test fun `encode session_resume includes skipReplay when true`() {
        val id = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        val json = MessageEnvelope.encodeClient(ClientMessage.SessionResume(id, skipReplay = true))
        assertTrue(json.contains("\"skipReplay\":true"))
    }
    @Test fun `decode auth_success`() {
        val msg = MessageEnvelope.decodeServer("""{"type":"auth_success","payload":{"protocolVersion":1}}""")
        assertEquals(ServerMessage.AuthSuccess(1), msg)
    }
    @Test fun `decode pong`() {
        assertEquals(ServerMessage.Pong, MessageEnvelope.decodeServer("""{"type":"pong","payload":{}}"""))
    }
    @Test fun `decode session_activity with legacy claude_active`() {
        val id = "550e8400-e29b-41d4-a716-446655440000"
        val msg = MessageEnvelope.decodeServer(
            """{"type":"session_activity","payload":{"sessionId":"$id","activity":"claude_active"}}"""
        ) as ServerMessage.SessionActivity
        assertEquals(ActivityState.AGENT_ACTIVE, msg.activity)
        assertNull(msg.agent)
    }
    @Test fun `decode unknown type throws`() {
        assertThrows(IllegalArgumentException::class.java) {
            MessageEnvelope.decodeServer("""{"type":"made_up","payload":{}}""")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.MessageEnvelopeTest"`
Expected: FAIL — `MessageEnvelope` unresolved.

- [ ] **Step 3: Implement `MessageEnvelope.kt`**

```kotlin
package relay.protocol

import kotlinx.serialization.json.*
import java.util.UUID

/**
 * Wire envelope: {"type":"<typeString>","payload":{...}}.
 * Manual payload construction/parsing mirrors Swift's encodePayload/decode,
 * including encodeIfPresent omission rules. Field names are camelCase.
 */
object MessageEnvelope {
    private fun uuid(v: UUID) = JsonPrimitive(v.toString().lowercase())

    fun encodeClient(msg: ClientMessage): String {
        val payload: JsonObject = buildJsonObject {
            when (msg) {
                is ClientMessage.AuthRequest -> {
                    put("token", msg.token)
                    msg.protocolVersion?.let { put("protocolVersion", it) }
                }
                is ClientMessage.SessionCreate -> msg.name?.let { put("name", it) }
                is ClientMessage.SessionAttach -> put("sessionId", uuid(msg.sessionId))
                is ClientMessage.SessionResume -> {
                    put("sessionId", uuid(msg.sessionId))
                    if (msg.skipReplay) put("skipReplay", true)
                }
                ClientMessage.SessionDetach -> {}
                is ClientMessage.SessionTerminate -> put("sessionId", uuid(msg.sessionId))
                ClientMessage.SessionList -> {}
                ClientMessage.SessionListAll -> {}
                is ClientMessage.SessionRename -> {
                    put("sessionId", uuid(msg.sessionId)); put("name", msg.name)
                }
                is ClientMessage.Resize -> { put("cols", msg.cols.toInt()); put("rows", msg.rows.toInt()) }
                is ClientMessage.PasteImage -> put("data", msg.data)
                ClientMessage.Ping -> {}
            }
        }
        return WireJson.instance.encodeToString(
            JsonObject.serializer(),
            buildJsonObject { put("type", msg.typeString); put("payload", payload) },
        )
    }

    fun decodeServer(text: String): ServerMessage {
        val root = WireJson.instance.parseToJsonElement(text).jsonObject
        val type = root["type"]!!.jsonPrimitive.content
        require(type in ServerMessage.ALL_TYPE_STRINGS) { "Unknown server message type: $type" }
        val p = root["payload"]?.jsonObject ?: JsonObject(emptyMap())
        fun id() = UUID.fromString(p["sessionId"]!!.jsonPrimitive.content)
        fun str(k: String) = p[k]!!.jsonPrimitive.content
        fun strOrNull(k: String) = p[k]?.jsonPrimitive?.contentOrNull
        fun int(k: String) = p[k]!!.jsonPrimitive.int
        return when (type) {
            "auth_success" -> ServerMessage.AuthSuccess(p["protocolVersion"]?.jsonPrimitive?.intOrNull)
            "auth_failure" -> ServerMessage.AuthFailure(str("reason"))
            "session_created" -> ServerMessage.SessionCreated(id(), int("cols").toUShort(), int("rows").toUShort())
            "session_attached" -> ServerMessage.SessionAttached(id(), str("state"))
            "session_resumed" -> ServerMessage.SessionResumed(id())
            "replay_complete" -> ServerMessage.ReplayComplete(id())
            "session_detached" -> ServerMessage.SessionDetached
            "session_terminated" -> ServerMessage.SessionTerminated(id(), str("reason"))
            "session_expired" -> ServerMessage.SessionExpired(id())
            "session_state" -> ServerMessage.SessionStateMsg(id(), str("state"))
            "session_activity" -> ServerMessage.SessionActivity(id(), ActivityState.fromRaw(str("activity")), strOrNull("agent"))
            "session_stolen" -> ServerMessage.SessionStolen(id())
            "session_renamed" -> ServerMessage.SessionRenamed(id(), str("name"))
            "session_list_result" -> ServerMessage.SessionList(decodeSessions(p))
            "session_list_all_result" -> ServerMessage.SessionListAll(decodeSessions(p))
            "resize_ack" -> ServerMessage.ResizeAck(int("cols").toUShort(), int("rows").toUShort())
            "paste_image_result" -> ServerMessage.PasteImageResult(p["success"]!!.jsonPrimitive.boolean)
            "pong" -> ServerMessage.Pong
            "error" -> ServerMessage.Error(int("code"), str("message"))
            else -> throw IllegalArgumentException("Unknown server message type: $type")
        }
    }

    private fun decodeSessions(p: JsonObject): List<SessionInfo> =
        WireJson.instance.decodeFromJsonElement(
            kotlinx.serialization.builtins.ListSerializer(SessionInfo.serializer()),
            p["sessions"] ?: JsonArray(emptyList()),
        )
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.MessageEnvelopeTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(protocol): MessageEnvelope encode/decode with fidelity rules"
```

---

## Task 7: `TokenGenerator` (parity utility)

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/TokenGenerator.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/TokenGeneratorTest.kt`

> Port of `TokenGenerator.swift`. The app never mints tokens (CLI does), but `hash`/`validate` parity is cheap and useful for tests.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class TokenGeneratorTest {
    @Test fun `generated token is 43 chars base64url no padding`() {
        val (plaintext, _) = TokenGenerator.generate()
        assertEquals(43, plaintext.length)
        assertFalse(plaintext.contains('='))
        assertFalse(plaintext.contains('+'))
        assertFalse(plaintext.contains('/'))
    }
    @Test fun `hash is 64 hex chars and validates`() {
        val hash = TokenGenerator.hash("hello")
        assertEquals(64, hash.length)
        assertTrue(TokenGenerator.validate("hello", hash))
        assertFalse(TokenGenerator.validate("world", hash))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.TokenGeneratorTest"`
Expected: FAIL.

- [ ] **Step 3: Implement `TokenGenerator.kt`**

```kotlin
package relay.protocol

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

object TokenGenerator {
    private val rng = SecureRandom()

    fun generate(): Pair<String, String> {
        val bytes = ByteArray(32).also { rng.nextBytes(it) }
        val plaintext = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        return plaintext to hash(plaintext)
    }

    fun hash(token: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(token.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    fun validate(token: String, storedHash: String): Boolean = hash(token) == storedHash
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.TokenGeneratorTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(protocol): TokenGenerator parity utility"
```

---

## Task 8: `ConnectionConfig`

**Files:**
- Create: `core-protocol/src/main/kotlin/relay/protocol/ConnectionConfig.kt`
- Test: `core-protocol/src/test/kotlin/relay/protocol/ConnectionConfigTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.util.UUID

class ConnectionConfigTest {
    @Test fun `builds ws url without tls`() {
        val c = ConnectionConfig(UUID.randomUUID(), "Home", "192.168.1.5", 9200u, false)
        assertEquals("ws://192.168.1.5:9200", c.wsUrl)
    }
    @Test fun `builds wss url with tls`() {
        val c = ConnectionConfig(UUID.randomUUID(), "Home", "relay.example.com", 443u, true)
        assertEquals("wss://relay.example.com:443", c.wsUrl)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.ConnectionConfigTest"`
Expected: FAIL.

- [ ] **Step 3: Implement `ConnectionConfig.kt`** (port of `ConnectionConfig.swift`)

```kotlin
package relay.protocol

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class ConnectionConfig(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val host: String,
    val port: UShort = 9200u,
    val useTLS: Boolean = false,
) {
    val wsUrl: String get() = (if (useTLS) "wss" else "ws") + "://$host:$port"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.ConnectionConfigTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(protocol): ConnectionConfig"
```

---

## Task 9: Contract test against a captured live server frame

**Files:**
- Create: `core-protocol/src/test/kotlin/relay/protocol/LiveFrameContractTest.kt`
- Create: `core-protocol/src/test/resources/captured_session_list_result.json` (captured at execution time)

> **Guards the two spec corrections.** Capture a REAL `session_list_result` frame from a running server (via a WS client, `wscat`, or a logging hook) and assert our decoder accepts it and that `createdAt` is the expected Double. This is the single most important fidelity test.

- [ ] **Step 1: Capture a real frame**

With a running server + token, connect a quick WS client (e.g. `npx wscat -c ws://<host>:9200`), send `{"type":"auth_request","payload":{"token":"<tok>","protocolVersion":1}}` then `{"type":"session_list","payload":{}}` (create a session first so the list is non-empty). Save the raw `session_list_result` text frame to `core-protocol/src/test/resources/captured_session_list_result.json`.

- [ ] **Step 2: Write the test**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class LiveFrameContractTest {
    private fun load(name: String) =
        javaClass.classLoader!!.getResource(name)!!.readText()

    @Test fun `decodes a captured live session_list_result`() {
        val msg = MessageEnvelope.decodeServer(load("captured_session_list_result.json"))
        assertTrue(msg is ServerMessage.SessionList)
        val sessions = (msg as ServerMessage.SessionList).sessions
        assertTrue(sessions.isNotEmpty(), "capture a frame with >=1 session")
        // createdAt must be a finite Double (NOT an ISO-8601 string the decoder would reject)
        assertTrue(sessions.first().createdAt.isFinite())
    }
}
```

- [ ] **Step 3: Run the test**

Run: `./gradlew :core-protocol:test --tests "relay.protocol.LiveFrameContractTest"`
Expected: PASS. **If it fails because `createdAt` is a string**, the server is on the ISO path — STOP and re-check the spec's Date Encoding Caveat; adjust `ReferenceDateDoubleSerializer` accordingly and document.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "test(protocol): contract test vs captured live server frame"
```

---

## Task 10: `:core-net` module + `NetworkConfinement`

**Files:**
- Create: `core-net/build.gradle.kts`
- Create: `core-net/src/main/kotlin/relay/net/NetworkConfinement.kt`
- Modify: `settings.gradle.kts` (include `:core-net`)

> Replaces Swift's `@MainActor` serial isolation: a single-thread confinement dispatcher every state mutation marshals onto.

- [ ] **Step 1: Configure `:core-net`**

`core-net/build.gradle.kts`:

```kotlin
plugins { alias(libs.plugins.kotlin.jvm) }
dependencies {
    api(project(":core-protocol"))
    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit5.api); testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
    testImplementation(libs.okhttp.mockwebserver)
}
tasks.test { useJUnitPlatform() }
```

- [ ] **Step 2: Implement `NetworkConfinement.kt`**

```kotlin
package relay.net

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors

/**
 * Single-thread confinement. All RelayConnection/SessionController state
 * mutations run here, replicating Swift @MainActor serial isolation without
 * pulling in Android's Main dispatcher (keeps :core-net a pure-JVM module,
 * unit-testable). The :app layer can swap this for Dispatchers.Main.immediate.
 */
object NetworkConfinement {
    val dispatcher: CoroutineDispatcher =
        Executors.newSingleThreadExecutor { r -> Thread(r, "relay-net").apply { isDaemon = true } }
            .asCoroutineDispatcher()
}
```

- [ ] **Step 3: Verify it compiles**

Run: `./gradlew :core-net:compileKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "chore(net): core-net module + confinement dispatcher"
```

---

## Task 11: `RelayConnection` — connect, send, receive loop, generation

**Files:**
- Create: `core-net/src/main/kotlin/relay/net/RelayConnection.kt`
- Test: `core-net/src/test/kotlin/relay/net/RelayConnectionTest.kt`

> Port of `RelayConnection.swift` (transport + generation + receive routing). Ping/pong + quality is the NEXT task so this one stays focused. Uses MockWebServer for the test.

- [ ] **Step 1: Write the failing test (echo connect + binary output routing)**

```kotlin
package relay.net

import app.cash.turbine.test
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString.Companion.toByteString
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class RelayConnectionTest {
    @Test fun `routes binary frames to onTerminalOutput`() = runTest {
        val server = MockWebServer()
        val received = CountDownLatch(1)
        var got: ByteArray? = null
        server.enqueue(okhttp3.mockwebserver.MockResponse().withWebSocketUpgrade(
            object : okhttp3.WebSocketListener() {
                override fun onOpen(ws: okhttp3.WebSocket, r: okhttp3.Response) {
                    ws.send("hi".toByteArray().toByteString())
                }
            }
        ))
        server.start()
        val url = server.url("/").toString().replace("http", "ws")
        val conn = RelayConnection()
        conn.onTerminalOutput = { got = it; received.countDown() }
        conn.connectRaw(url)              // test seam: connect by raw URL
        assertTrue(received.await(2, TimeUnit.SECONDS))
        assertArrayEquals("hi".toByteArray(), got)
        conn.disconnect(); server.shutdown()
    }
    @Test fun `generation increments on each connect`() = runTest {
        val conn = RelayConnection()
        val g0 = conn.generation
        conn.connectRaw("ws://127.0.0.1:1")  // fails to connect but bumps generation
        assertTrue(conn.generation > g0)
        conn.disconnect()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-net:test --tests "relay.net.RelayConnectionTest"`
Expected: FAIL — `RelayConnection` unresolved.

- [ ] **Step 3: Implement `RelayConnection.kt` (transport core)**

```kotlin
package relay.net

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.*
import okio.ByteString
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.ConnectionQuality
import relay.protocol.MessageEnvelope
import relay.protocol.ServerMessage

class RelayConnection(
    private val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + NetworkConfinement.dispatcher),
    private val client: OkHttpClient = OkHttpClient(),
) {
    enum class State { DISCONNECTED, CONNECTING, CONNECTED }

    private val _state = MutableStateFlow(State.DISCONNECTED)
    val state: StateFlow<State> = _state
    private val _quality = MutableStateFlow(ConnectionQuality.DISCONNECTED)
    val quality: StateFlow<ConnectionQuality> = _quality

    @Volatile var generation: Long = 0L; private set

    // Callbacks (set by coordinator); invoked on the confinement dispatcher.
    var onTerminalOutput: ((ByteArray) -> Unit)? = null
    var onSendFailed: (() -> Unit)? = null
    var onHealthyPing: (() -> Unit)? = null

    private val subscribers = LinkedHashMap<java.util.UUID, (ServerMessage) -> Unit>()
    fun addServerMessageSubscriber(h: (ServerMessage) -> Unit): java.util.UUID =
        java.util.UUID.randomUUID().also { subscribers[it] = h }
    fun removeSubscriber(id: java.util.UUID) { subscribers.remove(id) }

    private var webSocket: WebSocket? = null
    internal var pendingPong: CompletableDeferred<Boolean>? = null   // used in Task 12

    /** Test seam used by unit tests. Production calls connect(config, token). */
    fun connectRaw(wsUrl: String) {
        generation++
        val gen = generation
        _state.value = State.CONNECTING
        val req = Request.Builder().url(wsUrl).build()
        webSocket = client.newWebSocket(req, listener(gen))
        _state.value = State.CONNECTED
    }

    suspend fun connect(config: ConnectionConfig, token: String) {
        connectRaw(config.wsUrl)
        // auth happens in SessionController (Task 13)
    }

    private fun listener(gen: Long) = object : WebSocketListener() {
        override fun onMessage(ws: WebSocket, text: String) = onConfine(gen) {
            val msg = runCatching { MessageEnvelope.decodeServer(text) }.getOrNull() ?: return@onConfine
            if (msg is ServerMessage.Pong) { pendingPong?.complete(true); return@onConfine }
            subscribers.values.toList().forEach { it(msg) }
        }
        override fun onMessage(ws: WebSocket, bytes: ByteString) = onConfine(gen) {
            onTerminalOutput?.invoke(bytes.toByteArray())
        }
        override fun onFailure(ws: WebSocket, t: Throwable, r: Response?) = onConfine(gen) {
            handleReceiveFailure()
        }
        override fun onClosed(ws: WebSocket, code: Int, reason: String) = onConfine(gen) {
            handleReceiveFailure()
        }
    }

    /** Run on the confinement dispatcher, dropping callbacks from superseded sockets. */
    private fun onConfine(gen: Long, block: () -> Unit) {
        scope.launch { if (gen == generation) block() }
    }

    suspend fun send(msg: ClientMessage): Unit = withContext(scope.coroutineContext) {
        val ws = webSocket ?: run { onSendFailed?.invoke(); error("not connected") }
        val ok = ws.send(MessageEnvelope.encodeClient(msg))
        if (!ok) { onSendFailed?.invoke(); error("send failed") }
    }

    suspend fun sendBinary(data: ByteArray): Unit = withContext(scope.coroutineContext) {
        val ws = webSocket ?: run { onSendFailed?.invoke(); error("not connected") }
        if (!ws.send(ByteString.of(*data))) { onSendFailed?.invoke(); error("send failed") }
    }

    suspend fun sendResize(cols: UShort, rows: UShort) = send(ClientMessage.Resize(cols, rows))
    suspend fun sendPasteImage(base64: String) = send(ClientMessage.PasteImage(base64))

    private fun handleReceiveFailure() {
        webSocket = null
        _state.value = State.DISCONNECTED
        _quality.value = ConnectionQuality.DISCONNECTED
        pendingPong?.complete(false)
        onSendFailed?.invoke()
    }

    fun disconnect() {
        generation++
        webSocket?.close(1000, null); webSocket = null
        pendingPong?.complete(false)
        _state.value = State.DISCONNECTED
        _quality.value = ConnectionQuality.DISCONNECTED
    }

    suspend fun forceReconnect(config: ConnectionConfig, token: String) = connect(config, token)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-net:test --tests "relay.net.RelayConnectionTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(net): RelayConnection transport core + generation"
```

---

## Task 12: Ping/pong health monitor (10s interval, 6-window, 3-fail death)

**Files:**
- Modify: `core-net/src/main/kotlin/relay/net/RelayConnection.kt`
- Test: `core-net/src/test/kotlin/relay/net/RelayQualityTest.kt`

> Port of the keepalive + quality monitor + `recordRTT` + 3-consecutive-failure death detection. Make the timing injectable so tests don't wait 10s.

- [ ] **Step 1: Write the failing test (pure RTT bookkeeping via a test seam)**

```kotlin
package relay.net

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionQuality

class RelayQualityTest {
    @Test fun `window caps at six samples`() {
        val c = RelayConnection()
        repeat(8) { c.testRecordRtt(0.05) }
        assertEquals(6, c.testRttWindowCount)
    }
    @Test fun `three consecutive failures fire onSendFailed`() {
        val c = RelayConnection()
        var dead = false; c.onSendFailed = { dead = true }
        c.testRecordRtt(null); c.testRecordRtt(null); assertFalse(dead)
        c.testRecordRtt(null); c.testMarkDeadIfNeeded(); assertTrue(dead)
    }
    @Test fun `healthy ping resets failures and reports`() {
        val c = RelayConnection(); var healthy = 0; c.onHealthyPing = { healthy++ }
        c.testRecordRtt(null); c.testRecordRtt(0.05)
        assertEquals(0, c.testConsecutiveFailures); assertEquals(1, healthy)
    }
    @Test fun `quality computed from window`() {
        val c = RelayConnection(); repeat(6) { c.testRecordRtt(0.05) }
        assertEquals(ConnectionQuality.EXCELLENT, c.testComputeQuality())
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-net:test --tests "relay.net.RelayQualityTest"`
Expected: FAIL — test seams unresolved.

- [ ] **Step 3: Add the monitor to `RelayConnection.kt`**

Add fields and methods (mirroring `startQualityMonitor`/`recordRTT`/`computeQuality`/`markConnectionDead`, plus `measurePingRTT` single-flight + 5s pong timeout). Constants: `pingIntervalMs = 10_000`, `pongTimeoutMs = 5_000`, `windowSize = 6`, death at `consecutiveFailures >= 3`.

```kotlin
// --- add inside RelayConnection ---
private val rttWindow = ArrayDeque<Double?>()
private var consecutiveFailures = 0
private val windowSize = 6
private var activePing: Deferred<Double?>? = null
private var keepaliveJob: Job? = null

suspend fun isAlive(): Boolean = measurePingRtt() != null

suspend fun measurePingRtt(): Double? = withContext(scope.coroutineContext) {
    activePing?.let { return@withContext it.await() }
    val task = async { performPing() }
    activePing = task
    val r = task.await(); if (activePing === task) activePing = null
    r
}

private suspend fun performPing(): Double? {
    if (webSocket == null || _state.value != State.CONNECTED) return null
    val start = System.nanoTime()
    val deferred = CompletableDeferred<Boolean>()
    pendingPong = deferred
    if (!webSocket!!.send(MessageEnvelope.encodeClient(ClientMessage.Ping))) return null
    val got = withTimeoutOrNull(5_000) { deferred.await() } ?: false
    pendingPong = null
    return if (got) (System.nanoTime() - start) / 1_000_000_000.0 else null
}

private fun startQualityMonitor(gen: Long) {
    keepaliveJob?.cancel(); rttWindow.clear(); consecutiveFailures = 0
    _quality.value = ConnectionQuality.EXCELLENT
    keepaliveJob = scope.launch {
        while (isActive && gen == generation && _state.value == State.CONNECTED) {
            delay(10_000)
            if (gen != generation || _state.value != State.CONNECTED) return@launch
            recordRtt(measurePingRtt())
            if (consecutiveFailures >= 3) { markConnectionDead(); return@launch }
            _quality.value = computeQuality()
        }
    }
}

private fun recordRtt(rtt: Double?) {
    rttWindow.addLast(rtt); if (rttWindow.size > windowSize) rttWindow.removeFirst()
    if (rtt == null) consecutiveFailures++ else { consecutiveFailures = 0; onHealthyPing?.invoke() }
}

private fun computeQuality(): ConnectionQuality {
    if (rttWindow.isEmpty()) return ConnectionQuality.EXCELLENT
    val ok = rttWindow.filterNotNull()
    val rate = ok.size.toDouble() / rttWindow.size
    if (ok.isEmpty()) return ConnectionQuality.VERY_POOR
    val median = ok.sorted()[ok.size / 2]
    return ConnectionQuality.of(median, rate)
}

private fun markConnectionDead() {
    keepaliveJob?.cancel(); keepaliveJob = null
    generation++
    webSocket?.close(1000, null); webSocket = null
    pendingPong?.complete(false)
    _state.value = State.DISCONNECTED; _quality.value = ConnectionQuality.DISCONNECTED
    onSendFailed?.invoke()
}

// Test seams (mirror Swift _testOnly_*). Do not call from production.
internal fun testRecordRtt(rtt: Double?) = recordRtt(rtt)
internal val testRttWindowCount get() = rttWindow.size
internal val testConsecutiveFailures get() = consecutiveFailures
internal fun testComputeQuality() = computeQuality()
internal fun testMarkDeadIfNeeded() { if (consecutiveFailures >= 3) markConnectionDead() }
```

Also call `startQualityMonitor(gen)` at the end of `connectRaw`.

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-net:test --tests "relay.net.RelayQualityTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(net): ping/pong health monitor + quality + death detection"
```

---

## Task 13: `ResumeGuard` + `SessionController.sendAndWaitForResponse`

**Files:**
- Create: `core-net/src/main/kotlin/relay/net/ResumeGuard.kt`
- Create: `core-net/src/main/kotlin/relay/net/SessionController.kt`
- Test: `core-net/src/test/kotlin/relay/net/SessionControllerTest.kt`

> Port of `SessionController.swift`. Install subscriber BEFORE send; ResumeGuard ensures single resume; 10s timeout. Auth checks protocol version.

- [ ] **Step 1: Write the failing test (fake connection)**

```kotlin
package relay.net

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import relay.protocol.ServerMessage

class SessionControllerTest {
    @Test fun `authenticate succeeds on auth_success`() = runTest {
        val conn = FakeConnection()
        val sc = SessionController(conn)
        conn.autoRespond = { ServerMessage.AuthSuccess(1) }
        sc.authenticate("tok")
        assertTrue(sc.isAuthenticated)
    }
    @Test fun `authenticate throws on auth_failure`() = runTest {
        val conn = FakeConnection(); val sc = SessionController(conn)
        conn.autoRespond = { ServerMessage.AuthFailure("bad token") }
        assertThrows(SessionController.SessionException::class.java) { sc.authenticate("x") }
        assertFalse(sc.isAuthenticated)
    }
    @Test fun `createSession returns id`() = runTest {
        val conn = FakeConnection(); val sc = SessionController(conn)
        val id = java.util.UUID.randomUUID()
        conn.autoRespond = { ServerMessage.SessionCreated(id, 80u, 24u) }
        assertEquals(id, sc.createSession("test"))
    }
}
```

(Define `FakeConnection` as a test double implementing the small surface `SessionController` needs: `addServerMessageSubscriber`, `removeSubscriber`, `send`, `generation`. `autoRespond` synchronously feeds the subscriber after `send`.)

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-net:test --tests "relay.net.SessionControllerTest"`
Expected: FAIL.

- [ ] **Step 3: Implement `ResumeGuard.kt`**

```kotlin
package relay.net

import kotlinx.coroutines.CompletableDeferred
import relay.protocol.ServerMessage

/** Ensures a single resume of the response wait; mirrors Swift ResumeGuard. */
internal class ResumeGuard {
    val deferred = CompletableDeferred<ServerMessage>()
    @Volatile var pendingValue: ServerMessage? = null
    @Volatile private var resumed = false
    fun resumeReturning(v: ServerMessage) { if (!resumed) { resumed = true; deferred.complete(v) } }
    fun resumeThrowing(e: Throwable) { if (!resumed) { resumed = true; deferred.completeExceptionally(e) } }
}
```

- [ ] **Step 4: Implement `SessionController.kt`**

Port the Swift class: `authenticate`/`createSession`/`attachSession`/`resumeSession`/`listSessions`/`listAllSessions`/`renameSession`/`detach`, the `responseTypes` set, and `sendAndWaitForResponse` (install subscriber → send → check pendingValue → await with 10s timeout). Use `ClaudeRelayKit.protocolVersion = 1`, `minProtocolVersion = 0` as Kotlin constants (`object ProtocolVersions { const val CURRENT = 1; const val MIN = 0 }`).

```kotlin
package relay.net

import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import java.util.UUID

object ProtocolVersions { const val CURRENT = 1; const val MIN = 0 }

class SessionController(private val conn: ConnectionSurface) {
    class SessionException(msg: String) : Exception(msg) {
        val isNotAuthenticated get() = message?.contains("not authenticated", ignoreCase = true) == true
    }

    var sessionId: UUID? = null; private set
    var isAuthenticated = false; private set
    private var authenticatedGeneration = 0L
    val isAuthValid get() = isAuthenticated && authenticatedGeneration == conn.generation
    fun resetAuth() { isAuthenticated = false; sessionId = null }

    suspend fun authenticate(token: String) {
        when (val r = sendAndWait(ClientMessage.AuthRequest(token, ProtocolVersions.CURRENT))) {
            is ServerMessage.AuthSuccess -> {
                val sv = r.protocolVersion ?: 0
                if (sv < ProtocolVersions.MIN) { isAuthenticated = false; throw SessionException("incompatible version") }
                isAuthenticated = true; authenticatedGeneration = conn.generation
            }
            is ServerMessage.AuthFailure -> { isAuthenticated = false; throw SessionException("Authentication failed: ${r.reason}") }
            else -> throw SessionException("Unexpected: ${r.typeString}")
        }
    }

    suspend fun createSession(name: String? = null): UUID = when (val r = sendAndWait(ClientMessage.SessionCreate(name))) {
        is ServerMessage.SessionCreated -> r.sessionId.also { sessionId = it }
        is ServerMessage.Error -> throw SessionException(r.message)
        else -> throw SessionException("Unexpected: ${r.typeString}")
    }
    suspend fun attachSession(id: UUID) { when (val r = sendAndWait(ClientMessage.SessionAttach(id))) {
        is ServerMessage.SessionAttached -> sessionId = r.sessionId
        is ServerMessage.Error -> throw SessionException(r.message)
        else -> throw SessionException("Unexpected: ${r.typeString}") } }
    suspend fun resumeSession(id: UUID, skipReplay: Boolean = false) { when (val r = sendAndWait(ClientMessage.SessionResume(id, skipReplay))) {
        is ServerMessage.SessionResumed -> sessionId = r.sessionId
        is ServerMessage.Error -> throw SessionException(r.message)
        else -> throw SessionException("Unexpected: ${r.typeString}") } }
    suspend fun listSessions(): List<SessionInfo> = when (val r = sendAndWait(ClientMessage.SessionList)) {
        is ServerMessage.SessionList -> r.sessions
        is ServerMessage.Error -> throw SessionException(r.message)
        else -> throw SessionException("Unexpected: ${r.typeString}") }
    suspend fun listAllSessions(): List<SessionInfo> = when (val r = sendAndWait(ClientMessage.SessionListAll)) {
        is ServerMessage.SessionListAll -> r.sessions
        is ServerMessage.Error -> throw SessionException(r.message)
        else -> throw SessionException("Unexpected: ${r.typeString}") }
    suspend fun renameSession(id: UUID, name: String) { conn.send(ClientMessage.SessionRename(id, name)) }
    suspend fun detach() { when (val r = sendAndWait(ClientMessage.SessionDetach)) {
        is ServerMessage.SessionDetached -> sessionId = null
        is ServerMessage.Error -> throw SessionException(r.message)
        else -> throw SessionException("Unexpected: ${r.typeString}") } }

    private val responseTypes = setOf(
        "auth_success","auth_failure","session_created","session_attached","session_resumed",
        "session_detached","session_list_result","session_list_all_result","error")

    private suspend fun sendAndWait(msg: ClientMessage): ServerMessage {
        val guard = ResumeGuard()
        val subId = conn.addServerMessageSubscriber { m ->
            if (m.typeString in responseTypes) {
                if (!guard.deferred.isCompleted && guard.pendingValue == null) guard.resumeReturning(m)
                else guard.pendingValue = m
            }
        }
        try {
            conn.send(msg)
            guard.pendingValue?.let { return it }
            return withTimeoutOrNull(10_000) { guard.deferred.await() }
                ?: throw SessionException("The operation timed out.")
        } finally { conn.removeSubscriber(subId) }
    }
}

/** Minimal surface SessionController needs — RelayConnection implements it. */
interface ConnectionSurface {
    val generation: Long
    fun addServerMessageSubscriber(h: (ServerMessage) -> Unit): UUID
    fun removeSubscriber(id: UUID)
    suspend fun send(msg: ClientMessage)
}
```

(Make `RelayConnection` implement `ConnectionSurface` — its members already match.)

- [ ] **Step 5: Run to verify it passes**

Run: `./gradlew :core-net:test --tests "relay.net.SessionControllerTest"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(net): SessionController + ResumeGuard sendAndWait"
```

---

## Task 14: TLS/cleartext host scoping (`isPrivateNetworkHost`)

**Files:**
- Create: `core-net/src/main/kotlin/relay/net/CleartextPolicy.kt`
- Test: `core-net/src/test/kotlin/relay/net/CleartextPolicyTest.kt`

> Replicates iOS ATS scoping in app logic: `ws://` allowed only to RFC1918 / loopback / link-local / `.local`; everything else (incl. Tailscale CGNAT 100.64/10, ULA, public) requires `wss://`.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.net

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class CleartextPolicyTest {
    @Test fun `private hosts allow cleartext`() {
        listOf("192.168.1.5","10.0.0.1","172.16.0.1","127.0.0.1","mymac.local","[fe80::1]")
            .forEach { assertTrue(CleartextPolicy.isPrivateNetworkHost(it), it) }
    }
    @Test fun `public and cgnat hosts require tls`() {
        listOf("relay.example.com","8.8.8.8","100.64.0.1","[fc00::1]")
            .forEach { assertFalse(CleartextPolicy.isPrivateNetworkHost(it), it) }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :core-net:test --tests "relay.net.CleartextPolicyTest"`
Expected: FAIL.

- [ ] **Step 3: Implement `CleartextPolicy.kt`**

```kotlin
package relay.net

object CleartextPolicy {
    /** Mirrors iOS NSAllowsLocalNetworking scope. Used to gate ws:// at validation. */
    fun isPrivateNetworkHost(host: String): Boolean {
        val h = host.trim().removePrefix("[").removeSuffix("]").lowercase()
        if (h == "localhost" || h.endsWith(".local")) return true
        // IPv6 loopback / link-local / (reject ULA fc00::/7)
        if (h == "::1") return true
        if (h.startsWith("fe80:")) return true
        if (h.startsWith("fc") || h.startsWith("fd")) return false   // ULA -> needs TLS
        val o = h.split(".")
        if (o.size == 4 && o.all { it.toIntOrNull() in 0..255 }) {
            val a = o[0].toInt(); val b = o[1].toInt()
            if (a == 127) return true                       // loopback
            if (a == 10) return true                        // 10/8
            if (a == 192 && b == 168) return true           // 192.168/16
            if (a == 172 && b in 16..31) return true        // 172.16/12
            if (a == 169 && b == 254) return true           // link-local
            if (a == 100 && b in 64..127) return false      // CGNAT -> needs TLS
            return false                                    // other public IPv4
        }
        return false                                        // hostnames -> needs TLS
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-net:test --tests "relay.net.CleartextPolicyTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(net): cleartext host scoping mirroring iOS ATS"
```

---

## Task 15: `:core-storage` — TokenStore, SavedConnectionStore, DeviceIdentifier

**Files:**
- Create: `core-storage/build.gradle.kts`
- Create: `core-storage/src/main/kotlin/relay/storage/TokenStore.kt`
- Create: `core-storage/src/main/kotlin/relay/storage/SavedConnectionStore.kt`
- Create: `core-storage/src/main/kotlin/relay/storage/DeviceIdentifier.kt`
- Test: `core-storage/src/androidTest/kotlin/relay/storage/TokenStoreTest.kt`

> These need Android `Context` (EncryptedSharedPreferences/DataStore), so this is an **Android library module** and storage tests are **instrumented** (`androidTest`) — they run on an emulator/device. Port of `AuthManager` (token service `com.coderemote.relay`, account = connection UUID; Bedrock account `com.clauderelay.bedrock.bearerToken`) and `SavedConnectionStore`.

- [ ] **Step 1: Configure `:core-storage` (Android library)**

`core-storage/build.gradle.kts`:

```kotlin
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.android) }
android {
    namespace = "relay.storage"; compileSdk = 35
    defaultConfig { minSdk = 28; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
}
dependencies {
    api(project(":core-protocol"))
    implementation(libs.security.crypto)
    implementation(libs.datastore.preferences)
    implementation(libs.kotlinx.coroutines.android)
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
```

- [ ] **Step 2: Implement `TokenStore.kt`** (EncryptedSharedPreferences, AuthManager parity)

```kotlin
package relay.storage

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.UUID

class TokenStore(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "com.coderemote.relay",                 // matches iOS Keychain service name
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
    private val bedrockKey = "com.clauderelay.bedrock.bearerToken"

    fun saveToken(token: String, connectionId: UUID) =
        prefs.edit().putString(connectionId.toString(), token).apply()
    fun loadToken(connectionId: UUID): String? = prefs.getString(connectionId.toString(), null)
    fun deleteToken(connectionId: UUID) = prefs.edit().remove(connectionId.toString()).apply()

    fun saveBedrockToken(token: String) =
        if (token.isEmpty()) prefs.edit().remove(bedrockKey).apply()
        else prefs.edit().putString(bedrockKey, token).apply()
    fun loadBedrockToken(): String? = prefs.getString(bedrockKey, null)
}
```

- [ ] **Step 3: Implement `DeviceIdentifier.kt`** (generated UUID, persisted)

```kotlin
package relay.storage

import android.content.Context
import java.util.UUID

/** Stable per-device id (accepted divergence from iOS identifierForVendor): a UUID
 *  generated once and persisted. Namespaces per-device ownership keys. */
object DeviceIdentifier {
    private const val PREFS = "relay.device"; private const val KEY = "deviceId"
    fun get(context: Context): String {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return p.getString(KEY, null) ?: UUID.randomUUID().toString().also { p.edit().putString(KEY, it).apply() }
    }
}
```

- [ ] **Step 4: Implement `SavedConnectionStore.kt`** (DataStore JSON list + legacy migration stub)

```kotlin
package relay.storage

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.ListSerializer
import relay.protocol.ConnectionConfig
import relay.protocol.WireJson

private val Context.connStore by preferencesDataStore("saved_connections")

class SavedConnectionStore(private val context: Context) {
    private val key = stringPreferencesKey("connections_json")
    private val ser = ListSerializer(ConnectionConfig.serializer())

    suspend fun load(): List<ConnectionConfig> {
        val json = context.connStore.data.first()[key] ?: return emptyList()
        return runCatching { WireJson.instance.decodeFromString(ser, json) }.getOrDefault(emptyList())
    }
    suspend fun save(list: List<ConnectionConfig>) {
        context.connStore.edit { it[key] = WireJson.instance.encodeToString(ser, list) }
    }
}
```

- [ ] **Step 5: Write the instrumented test**

```kotlin
package relay.storage

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class TokenStoreTest {
    private val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
    @Test fun roundTripsToken() {
        val store = TokenStore(ctx); val id = UUID.randomUUID()
        store.saveToken("secret-token", id)
        assertEquals("secret-token", store.loadToken(id))
        store.deleteToken(id); assertNull(store.loadToken(id))
    }
    @Test fun bedrockEmptyDeletes() {
        val store = TokenStore(ctx); store.saveBedrockToken("abc")
        assertEquals("abc", store.loadBedrockToken()); store.saveBedrockToken("")
        assertNull(store.loadBedrockToken())
    }
}
```

- [ ] **Step 6: Run the instrumented test (emulator/device required)**

Run: `./gradlew :core-storage:connectedAndroidTest`
Expected: PASS (requires a running emulator or device).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(storage): TokenStore, SavedConnectionStore, DeviceIdentifier"
```

---

## Task 16: `TerminalSessionVm` — buffering + replay state machine

**Files:**
- Create: `terminal/build.gradle.kts`
- Create: `terminal/src/main/kotlin/relay/terminal/ReplayProtocol.kt`
- Create: `terminal/src/main/kotlin/relay/terminal/TerminalSessionVm.kt`
- Test: `terminal/src/test/kotlin/relay/terminal/TerminalSessionVmTest.kt`

> Port of `TerminalViewModel.swift` buffering machine — the part with real logic and no SwiftTerm dependency, so it is fully unit-testable. The Termux `TerminalView` wrapper is Task 17. **This closes the iOS test-coverage gap** (the Swift VM has no unit tests here).

- [ ] **Step 1: Configure `:terminal` (pure JVM for the VM; the view wrapper comes in a later Android-only file)**

`terminal/build.gradle.kts`:

```kotlin
plugins { alias(libs.plugins.kotlin.jvm) }
dependencies {
    api(project(":core-protocol"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit5.api); testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
tasks.test { useJUnitPlatform() }
```

- [ ] **Step 2: Write the failing test**

```kotlin
package relay.terminal

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class TerminalSessionVmTest {
    private fun vm(): Pair<TerminalSessionVm, MutableList<ByteArray>> {
        val out = mutableListOf<ByteArray>()
        val vm = TerminalSessionVm(); vm.onTerminalOutput = { out.add(it) }
        return vm to out
    }
    @Test fun `live bytes route only after terminalReady`() {
        val (vm, out) = vm()
        vm.receiveOutput("a".toByteArray()); assertTrue(out.isEmpty())  // buffered (not sized)
        vm.terminalReady()                                              // flush buffered
        assertEquals(1, out.size); assertArrayEquals("a".toByteArray(), out[0])
        vm.receiveOutput("b".toByteArray())                            // now live
        assertEquals(2, out.size)
    }
    @Test fun `replay buffers then flushes single contiguous blob on endReplay`() {
        val (vm, out) = vm(); vm.terminalReady(); out.clear()
        vm.beginReplay()
        vm.receiveOutput("foo".toByteArray()); vm.receiveOutput("bar".toByteArray())
        assertTrue(out.isEmpty(), "must not render incrementally during replay")
        vm.endReplay()
        assertEquals(1, out.size); assertArrayEquals("foobar".toByteArray(), out[0])
    }
    @Test fun `terminalReady during replay emits RIS only`() {
        val (vm, out) = vm(); vm.beginReplay(); vm.terminalReady()
        assertEquals(1, out.size); assertArrayEquals(ReplayProtocol.RIS, out[0])
    }
    @Test fun `pending buffer drops oldest beyond 4MB`() {
        val (vm, _) = vm()                              // not sized -> buffers
        val chunk = ByteArray(1 shl 20)                 // 1 MB
        repeat(5) { vm.receiveOutput(chunk) }           // 5 MB > 4 MB cap
        assertTrue(vm.pendingBytes <= 4 * 1024 * 1024)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `./gradlew :terminal:test --tests "relay.terminal.TerminalSessionVmTest"`
Expected: FAIL.

- [ ] **Step 4: Implement `ReplayProtocol.kt` and `TerminalSessionVm.kt`**

```kotlin
// ReplayProtocol.kt
package relay.terminal
object ReplayProtocol { val RIS = byteArrayOf(0x1B, 0x63) } // ESC c, Reset to Initial State
```

```kotlin
// TerminalSessionVm.kt  (port of TerminalViewModel buffering machine)
package relay.terminal

class TerminalSessionVm {
    var onTerminalOutput: ((ByteArray) -> Unit)? = null
    var onAwaitingInputChanged: ((Boolean) -> Unit)? = null

    private var terminalSized = false
    private var isReplaying = false
    private val pending = ArrayDeque<ByteArray>()
    var pendingBytes = 0; private set
    private val cap = 4 * 1024 * 1024

    fun receiveOutput(data: ByteArray) {
        val handler = onTerminalOutput
        if (!isReplaying && terminalSized && handler != null) {
            handler(data)
        } else {
            pending.addLast(data); pendingBytes += data.size
            while (pendingBytes > cap && pending.isNotEmpty()) pendingBytes -= pending.removeFirst().size
        }
        // input-prompt detection wired in Task (M2); kept out of M1 to stay focused
    }

    fun terminalReady() {
        if (terminalSized) return
        terminalSized = true
        if (isReplaying) { onTerminalOutput?.invoke(ReplayProtocol.RIS); return }
        flushPending()
    }

    fun beginReplay() { isReplaying = true }

    fun endReplay() {
        if (!isReplaying) return
        isReplaying = false
        if (terminalSized) flushPending()
    }

    private fun flushPending() {
        val handler = onTerminalOutput ?: return
        if (pending.isEmpty()) return
        val total = pendingBytes
        val combined = ByteArray(total); var off = 0
        for (c in pending) { c.copyInto(combined, off); off += c.size }
        pending.clear(); pendingBytes = 0
        handler(combined)
    }

    fun prepareForSwitch() {
        onTerminalOutput = null; onAwaitingInputChanged = null
        terminalSized = false; isReplaying = false; pending.clear(); pendingBytes = 0
    }
    fun prepareForReplay() = prepareForSwitch()
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `./gradlew :terminal:test --tests "relay.terminal.TerminalSessionVmTest"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(terminal): buffering + replay state machine (with tests iOS lacks)"
```

---

## Task 17: Vendor Termux engine + `RelayTerminalView` wrapper

**Files:**
- Create: `terminal/src/main/kotlin/relay/terminal/RelayTerminalView.kt`
- Vendor: Termux `terminal-emulator` + `terminal-view` as Android library deps (see Step 1)

> **Cannot be unit-tested** (needs an Android `View` + the Termux engine). Verification is manual via the M1 demo (Task 19). Vendor decision per spec.

- [ ] **Step 1: Add the Termux engine**

Two options — pick at execution time:
- **(a) Maven (preferred if a maintained mirror exists):** add `com.termux.termux-app:terminal-view` + `:terminal-emulator` from a published source.
- **(b) Vendor source:** copy the `terminal-emulator/` and `terminal-view/` Gradle modules from `github.com/termux/termux-app` (Apache-2.0) into `ClaudeRelayAndroid/vendor/`, strip non-essential deps, and `include(":terminal-view", ":terminal-emulator")` in `settings.gradle.kts`. Add a `NOTICE` crediting Termux.

Convert `:terminal` to an Android library module (it now needs `View`): change its `build.gradle.kts` to `android.library` + `kotlin.android`, keep the pure-Kotlin VM tests as `test/` (they still run as JVM unit tests).

- [ ] **Step 2: Implement `RelayTerminalView.kt`**

Wrap Termux's `TerminalView`/`TerminalSession`, wiring it to `TerminalSessionVm`:

```kotlin
package relay.terminal

import android.content.Context
import android.util.AttributeSet
import com.termux.view.TerminalView
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * Bridges the Termux TerminalView/emulator to TerminalSessionVm.
 * - Bytes from the relay (vm.onTerminalOutput) are fed to the emulator.
 * - User input from the view is forwarded to the relay via onInput.
 * - On first layout (size known) we call vm.terminalReady() once, and report
 *   cols/rows via onResize.
 */
class RelayTerminalView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null,
) : TerminalView(context, attrs) {

    var onInput: ((ByteArray) -> Unit)? = null
    var onResize: ((cols: UShort, rows: UShort) -> Unit)? = null
    private var vm: TerminalSessionVm? = null
    private var session: TerminalSession? = null
    private var reportedReady = false

    fun bind(vm: TerminalSessionVm) {
        this.vm = vm
        // Feed relay bytes into the emulator. Termux's TerminalSession exposes a
        // write path for output; here we route bytes straight to the emulator buffer.
        vm.onTerminalOutput = { bytes -> session?.let { feedOutput(it, bytes) } }
        // Create a session whose input callback forwards keystrokes to the relay.
        session = makeRelaySession()
        attachSession(session)
    }

    private fun feedOutput(s: TerminalSession, bytes: ByteArray) {
        // EXECUTION NOTE: use the emulator's process-output entry point.
        // In Termux this is TerminalSession.write/processOutput; confirm exact
        // signature against the vendored version and feed `bytes` verbatim
        // (NO String decoding — preserve byte fidelity).
        s.emulator?.append(bytes, bytes.size)
        onScreenUpdated()
    }

    private fun makeRelaySession(): TerminalSession {
        // Construct a TerminalSession that, instead of spawning a local PTY,
        // forwards stdin to onInput. EXECUTION NOTE: subclass or supply a client
        // so write(bytes) -> onInput?.invoke(bytes). Termux couples session to a
        // process; we use its emulator + buffer but override the input sink.
        TODO("Wire TerminalSession input sink to onInput at execution time (vendored API)")
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        super.onSizeChanged(w, h, ow, oh)
        val cols = mEmulator?.mColumns ?: return
        val rows = mEmulator?.mRows ?: return
        onResize?.invoke(cols.toUShort(), rows.toUShort())
        if (!reportedReady) { reportedReady = true; vm?.terminalReady() }
    }
}
```

> The `TODO` is the one execution-time integration point that depends on the vendored Termux API surface; the surrounding contract (byte-fidelity feed, ready-on-first-size, resize reporting) is fully specified.

- [ ] **Step 3: Verify it compiles**

Run: `./gradlew :terminal:compileDebugKotlin`
Expected: BUILD SUCCESSFUL once the `TODO` is implemented against the vendored API.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(terminal): RelayTerminalView wrapping Termux engine"
```

---

## Task 18: Keyboard accessory bar (special keys → raw bytes)

**Files:**
- Create: `terminal/src/main/kotlin/relay/terminal/KeyboardAccessory.kt`
- Create: `terminal/src/main/kotlin/relay/terminal/SpecialKeys.kt`
- Test: `terminal/src/test/kotlin/relay/terminal/SpecialKeysTest.kt`

> The byte sequences are pure data (unit-testable); the Compose bar itself is UI (manual verify). Port of `KeyboardAccessory.swift` byte maps.

- [ ] **Step 1: Write the failing test (byte maps)**

```kotlin
package relay.terminal

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class SpecialKeysTest {
    @Test fun `control and escape bytes`() {
        assertArrayEquals(byteArrayOf(0x1B), SpecialKeys.ESC)
        assertArrayEquals(byteArrayOf(0x09), SpecialKeys.TAB)
        assertArrayEquals(byteArrayOf(0x0D), SpecialKeys.RETURN)
        assertArrayEquals(byteArrayOf(0x03), SpecialKeys.CTRL_C)
        assertArrayEquals(byteArrayOf(0x0C), SpecialKeys.CTRL_L)
    }
    @Test fun `arrow sequences`() {
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x41), SpecialKeys.UP)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x44), SpecialKeys.LEFT)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew :terminal:test --tests "relay.terminal.SpecialKeysTest"`
Expected: FAIL.

- [ ] **Step 3: Implement `SpecialKeys.kt`**

```kotlin
package relay.terminal

object SpecialKeys {
    val RETURN = byteArrayOf(0x0D)
    val ESC = byteArrayOf(0x1B)
    val TAB = byteArrayOf(0x09)
    val BACKSPACE = byteArrayOf(0x7F)
    val UP = byteArrayOf(0x1B, 0x5B, 0x41)
    val DOWN = byteArrayOf(0x1B, 0x5B, 0x42)
    val RIGHT = byteArrayOf(0x1B, 0x5B, 0x43)
    val LEFT = byteArrayOf(0x1B, 0x5B, 0x44)
    val CTRL_C = byteArrayOf(0x03); val CTRL_R = byteArrayOf(0x12); val CTRL_A = byteArrayOf(0x01)
    val CTRL_E = byteArrayOf(0x05); val CTRL_D = byteArrayOf(0x04); val CTRL_Z = byteArrayOf(0x1A)
    val CTRL_L = byteArrayOf(0x0C); val CTRL_U = byteArrayOf(0x15)
    // Literal helper keys
    fun literal(ch: Char) = byteArrayOf(ch.code.toByte())  // | / ~ - _ 1 2 3
}
```

- [ ] **Step 4: Implement `KeyboardAccessory.kt` (Compose LazyRow)**

```kotlin
package relay.terminal

import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

data class AccessoryKey(val label: String, val bytes: ByteArray)

private val keys = listOf(
    AccessoryKey("esc", SpecialKeys.ESC), AccessoryKey("tab", SpecialKeys.TAB),
    AccessoryKey("⌃C", SpecialKeys.CTRL_C), AccessoryKey("⌃R", SpecialKeys.CTRL_R),
    AccessoryKey("⌃A", SpecialKeys.CTRL_A), AccessoryKey("⌃E", SpecialKeys.CTRL_E),
    AccessoryKey("⌃D", SpecialKeys.CTRL_D), AccessoryKey("⌃Z", SpecialKeys.CTRL_Z),
    AccessoryKey("⌃L", SpecialKeys.CTRL_L),
    AccessoryKey("↑", SpecialKeys.UP), AccessoryKey("↓", SpecialKeys.DOWN),
    AccessoryKey("←", SpecialKeys.LEFT), AccessoryKey("→", SpecialKeys.RIGHT),
    AccessoryKey("|", SpecialKeys.literal('|')), AccessoryKey("/", SpecialKeys.literal('/')),
    AccessoryKey("~", SpecialKeys.literal('~')), AccessoryKey("-", SpecialKeys.literal('-')),
    AccessoryKey("_", SpecialKeys.literal('_')),
)

@Composable
fun KeyboardAccessory(onKey: (ByteArray) -> Unit) {
    LazyRow {
        items(keys) { k -> Button(onClick = { onKey(k.bytes) }) { Text(k.label) } }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `./gradlew :terminal:test --tests "relay.terminal.SpecialKeysTest"`
Expected: PASS (compile of the Compose file verified by `:terminal:compileDebugKotlin`).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(terminal): keyboard accessory bar + special-key byte maps"
```

---

## Task 19: `:app` M1 demo — wire one connection to a live terminal

**Files:**
- Create: `app/build.gradle.kts`, `app/src/main/AndroidManifest.xml`
- Create: `app/src/main/kotlin/relay/app/RelayApplication.kt`, `MainActivity.kt`, `M1DemoScreen.kt`

> **Manual verification milestone** — the deliverable. No unit test (UI + live socket). Hard-codes a server config + token for M1; replaced by the real UI in M2.

- [ ] **Step 1: Manifest with INTERNET + cleartext NSC**

`AndroidManifest.xml` declares `<uses-permission android:name="android.permission.INTERNET"/>` and references a network-security-config that permits cleartext (app gates it via `CleartextPolicy`). Single `MainActivity`.

- [ ] **Step 2: Implement `M1DemoScreen.kt`**

A Composable that, on launch:
1. Builds `ConnectionConfig(host=<dev server>, port=9200, useTLS=false)`.
2. Validates with `CleartextPolicy.isPrivateNetworkHost` (LAN dev server → allowed).
3. `RelayConnection.connect(config, token)`; `SessionController.authenticate(token)`; `createSession("android-m1")`; sets `onTerminalOutput` → `TerminalSessionVm.receiveOutput`; `resumeSession` if attaching, else uses the created session.
4. Hosts `RelayTerminalView` (via `AndroidView`) bound to the VM, with `onInput` → `conn.sendBinary`, `onResize` → `conn.sendResize`, and the `KeyboardAccessory` below it sending bytes to `conn.sendBinary`.

- [ ] **Step 3: Build + install on device/emulator**

Run: `./gradlew :app:installDebug`
Expected: app installs.

- [ ] **Step 4: Manual verification (the M1 acceptance test)**

With the dev server running on the LAN:
1. Launch the app → it connects and shows a shell prompt.
2. Tap the on-screen keyboard, type `ls` + Return → output renders.
3. Tap `⌃C`, arrows, `tab` → behave correctly.
4. Rotate the device → terminal resizes, `resize` sent, content reflows.
5. Background + foreground the app → terminal still shows (recovery is M2; for M1, a fresh `resumeSession` with replay should restore scrollback in a single paint).

Record results in the task checklist. **M1 is done when steps 1–4 pass.** (Step 5 partial-pass is acceptable; full recovery lands in M2.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(app): M1 demo — live terminal over the relay protocol"
```

---

## M1 Self-Review Checklist (run before declaring M1 complete)

- [ ] All 30 wire type strings present and disjoint (Task 5 test).
- [ ] Envelope encode/decode fidelity: empty-payload ping, skipReplay omission, legacy activity decode, unknown-type throw (Task 6 test).
- [ ] **Contract test passes against a real captured frame; `createdAt` is a Double** (Task 9). If it was a string, the spec correction is wrong for this server — document and adjust.
- [ ] Ping/pong: window caps at 6, 3 failures → `onSendFailed`, healthy ping resets (Task 12 test).
- [ ] `sendAndWaitForResponse` resumes once, 10s timeout, subscriber installed before send (Task 13 test).
- [ ] Cleartext scoping matches iOS ATS (Task 14 test).
- [ ] Token round-trips in EncryptedSharedPreferences (Task 15 instrumented test).
- [ ] Replay machine: buffers during replay, single-blob flush, RIS-on-ready, 4MB cap (Task 16 test).
- [ ] Manual: live terminal connects, types, resizes (Task 19).
