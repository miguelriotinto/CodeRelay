# Multi-Server Plan 3: Kotlin ServerHub — Android and Linux Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Android and Linux clients show every enabled relay's sessions in one workspace — sidebar grouped by server, one attached session across servers, management screen with per-bookmark Enabled, push/deep-link routing by server — plus the loading sheet the Apple apps already ship (step + byte counter as the largest text, "0 KB → Ready", terminal fades to black, never stays up).

**Architecture:** One Kotlin `ServerHub<S : ServerSlot>` in `core-session` (shared, so Linux compiles it in place) owns one unchanged per-server `SessionCoordinator` per enabled bookmark, wrapped by a `CoordinatorServerSlot` adapter, and the single global `activeRef: SessionRef`. It is a line-for-line port of the shipped Swift hub *after* both review fix passes (Plans 1 and 2): one `pendingRef == activeRef`, `selectionGeneration` on every selection path, reconcile from the coordinator, concurrent staggered start/fan-out, `focusSlot`, cap of 8 enforced on reload, push unregister on disable, rebuild only when not live. Platform glue lives in each app: Android's `HubViewModel` (replacing `ConnectionViewModel`) and Linux's `Main.kt` hub. The loading sheet's logic (`SessionLoadingPresentation`, `SessionLoadingSheetModel`) is pure Kotlin in `core-session`; its Compose sheet lives in the shared `feature-workspace`.

**Tech Stack:** Kotlin 2.3, kotlinx.coroutines 1.11 (StateFlow, `runTest`/`StandardTestDispatcher`), kotlinx.serialization (`WireJson`), Jetpack Compose + Material3 (Android, BOM 2026.05.01) / Compose Multiplatform 1.12 desktop (Linux), JUnit 5, Turbine.

**Spec:** `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md` — §5 (identity), §7 (hub), §8.1 (shared behaviour), §8.4 (Android), §8.5 (Linux), §9 (migration), §10 (push + deep links), §11 (management), §12 (edge cases). The Swift implementation is the reference for every behaviour named here: `Sources/CodeRelayClient/Hub/*.swift`, `Sources/CodeRelayClient/Views/SessionLoadingPresentation.swift`, `SessionLoadingSheet.swift`, and the two Swift fix-pass commits `90e9bd9` (Plan 1) and `49bfa6a` (Plan 2).

## Global Constraints

- **No version bumps in this plan** (Android `versionCode`/`versionName`, Kit version, formula, PKGBUILDs — the release owns them).
- **One copy of each shared file.** `CodeRelayLinux` compiles `CodeRelayAndroid/{core-protocol,core-net,core-session,terminal,feature-*}/src/main/kotlin` (and their `src/test` suites for the shared modules) by `srcDirs`; a new file there is picked up automatically unless its name matches an `exclude` in the Linux module's `build.gradle.kts`. Every shared change must keep **both** builds green.
- **Android gates** (from `.github/workflows/android.yml`), JDK 17: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew test testDebugUnitTest :core-storage:compileDebugAndroidTestKotlin assembleDebug :app:assembleRelease`.
- **Linux gates** (from `.github/workflows/linux.yml`, minus the libvterm terminal suite which builds only on Linux), JDK 21: `cd CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :shared-protocol:test :shared-net:test :shared-session:test :linux-storage:test :feature-settings:test :feature-servers:test :feature-workspace:test :app:test --no-daemon`. If a Linux module refuses to configure on macOS because it needs the native libvterm build (`cmake`), record a ruling, run what does configure, and rely on the `linux` CI job for the rest — never skip it silently.
- **Kotlin coordinators are not thread-safe**: every hub and coordinator entry point runs on the one main-confined scope (`Dispatchers.Main.immediate` in the apps, `TestScope` in tests). The hub adds no locks.
- **Never** run the relay server binary directly, `pkill` the relay, or `claude-relay restart` (the user's live Claude sessions run inside it). Never log tokens. `git add` explicit paths only; no `git stash` / `checkout --` / `clean`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Copy matches the Apple apps verbatim (spec §8.1): notices "Up to 8 servers can be enabled at once. Disable one first.", "<name> has no token. Re-pair it in Servers.", "Enable <name> in Servers to open its sessions.", "That server is not connected.", "That session has ended", "Enabled <name> to open this session", "Session not found on any enabled server"; section subtitles "connecting…", "reconnecting…", "offline", "No token stored for this server", "disabled"; loading sheet title "Loading session" / "Reconnecting", status = phase label, bytes "0 KB" until history streams, closing status "Ready".

## Review Focus

1. **A push tap on a cold-started Android app** (process dead) must open the right session on the right server after the handshakes, not be dropped or attached on "the first server": `MainActivity` hands the parsed `SessionDeepLink` (with `?server=`) to `hub.handleDeepLink`, which waits on `startCompleted`. Task 5's `testDeepLinkBeforeStartIsQueuedAndRoutesByInstanceId` + Task 9's `testLaunchIntentRoutesSessionLinksToTheHub`.
2. **Android rotation / activity recreation** must not build a second hub or a second set of sockets: the hub is owned by an activity-scoped `ViewModel` and `start()` is idempotent. Task 9's `testHubViewModelStartsTheHubOnce`.
3. **An upgrade with two or more bookmarks and no `lastConnectedServerId`** leaves every bookmark disabled (spec §9 step 2): the workspace must present the management screen, never a black pane. Task 7's `testNoEnabledServerPresentsManagement`.
4. **The same session UUID listed by two servers** (rare, but a restored backup can do it) must not cross-attach: tabs and rows are keyed by `SessionRef`, never by bare UUID. Task 7's `testTabsAreKeyedByRefNotBareUuid`.
5. **A locked Linux keyring** (`secret-tool` exits non-zero) or a missing Android token must render that server as `authFailed("No token stored for this server")` with Re-pair, not crash or vanish. Task 4's `testTokenLookupThatThrowsBecomesAuthFailed`.
6. **The loading sheet must never stay up**: every path that raises it clears it on success and on failure; a presentation unchanged for 15 s lowers it until progress resumes. Task 6's `testSheetDismissesAfterAStallAndReturnsOnProgress` + Task 2's `testFailedSwitchIsMarkedFailedBeforeItsPhaseClears`.

---

### Task 1: Protocol v3 identity, `SessionRef`, `SessionDeepLink`, bookmark fields (core-protocol, core-net, both stores)

**Files:**
- Create: `CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ServerIdentity.kt`, `.../SessionRef.kt`, `.../SessionDeepLink.kt`, `.../ConnectionConfigList.kt`
- Modify: `CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ServerMessage.kt` (`AuthSuccess` line 16, `PairSuccess` line 104), `.../MessageEnvelope.kt` (decode lines 123–126 and 161–163), `.../ConnectionConfig.kt`; `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt` (`ProtocolVersions.CURRENT` line 20; `authenticate` ~line 196); `CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/SavedConnectionStore.kt` (decode in `loadAll`); `CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/SavedConnectionStore.kt` (decode in `loadAll`); `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/DeepLinks.kt` (`parseSessionId` delegates)
- Test: `CodeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/SessionDeepLinkTest.kt`, `.../ConnectionConfigListTest.kt`, additions to `.../MessageEnvelopeTest.kt` and `.../ConnectionConfigTest.kt`; `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerIdentityTest.kt`

**Interfaces:**
- Produces: `data class ServerIdentity(val id: UUID, val name: String)`; `data class SessionRef(val serverId: UUID, val sessionId: UUID)` (`serverId` = **bookmark** id, never the instance id); `data class SessionDeepLink(val sessionId: UUID, val serverInstanceId: UUID? = null)` with `companion fun parse(raw: String): SessionDeepLink?` and `val uri: String`; `ServerMessage.AuthSuccess.serverId/serverName` + `val server: ServerIdentity?`; `ServerMessage.PairSuccess.serverId/serverName` + `val server: ServerIdentity?`; `ConnectionConfig.enabled: Boolean = true`, `instanceId: UUID? = null`, `displayName: String? = null`, `val title: String get() = displayName ?: name`; `object ConnectionConfigList { fun decodeLenient(json: String): List<ConnectionConfig> }`; `SessionController.serverIdentity: ServerIdentity?` (set by `authenticate`, cleared by `resetAuth`); `ProtocolVersions.CURRENT = 3`.

- [ ] **Step 1: Write the failing tests**

`SessionDeepLinkTest.kt`:

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.util.UUID

class SessionDeepLinkTest {
    private val sid = UUID.fromString("0b7a6a51-2d4f-4b5c-9a6e-1f2e3d4c5b6a")
    private val iid = UUID.fromString("9c8b7a69-5847-4362-a1b0-c9d8e7f6a5b4")

    @Test fun parsesSessionOnly() =
        assertEquals(SessionDeepLink(sid), SessionDeepLink.parse("coderelay://session/$sid"))

    @Test fun parsesServerQuery() =
        assertEquals(SessionDeepLink(sid, iid), SessionDeepLink.parse("coderelay://session/$sid?server=$iid"))

    @Test fun acceptsLegacySchemeAndAnyCase() =
        assertEquals(SessionDeepLink(sid), SessionDeepLink.parse("ClaudeRelay://SESSION/${sid.toString().uppercase()}"))

    @Test fun ignoresAMalformedServerValue() =
        assertEquals(SessionDeepLink(sid), SessionDeepLink.parse("coderelay://session/$sid?server=not-a-uuid"))

    @Test fun rejectsOtherHostsSchemesAndGarbage() {
        assertNull(SessionDeepLink.parse("coderelay://pair?host=h&port=1&tls=0&code=ABCDEFGH"))
        assertNull(SessionDeepLink.parse("https://session/$sid"))
        assertNull(SessionDeepLink.parse("coderelay://session/nope"))
        assertNull(SessionDeepLink.parse(""))
    }

    @Test fun roundTrips() {
        val link = SessionDeepLink(sid, iid)
        assertEquals("coderelay://session/$sid?server=$iid", link.uri)
        assertEquals(link, SessionDeepLink.parse(link.uri))
        assertEquals("coderelay://session/$sid", SessionDeepLink(sid).uri)
    }
}
```

`ConnectionConfigListTest.kt`:

```kotlin
package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

class ConnectionConfigListTest {
    @Test fun preFeatureBookmarksDecodeEnabledWithNoIdentity() {
        val id = UUID.randomUUID()
        val list = ConnectionConfigList.decodeLenient("""[{"id":"$id","name":"a","host":"h","port":9200,"useTLS":false}]""")
        assertEquals(1, list.size)
        assertTrue(list[0].enabled)
        assertNull(list[0].instanceId)
        assertNull(list[0].displayName)
    }

    @Test fun oneBadElementDoesNotWipeTheList() {
        // The store decodes all-or-nothing today; one future-shaped field would
        // drop every bookmark and the next save would overwrite the list.
        val good = UUID.randomUUID()
        val list = ConnectionConfigList.decodeLenient(
            """[{"id":"$good","name":"a","host":"h"},{"id":"x","name":5,"host":[]},"junk"]""",
        )
        assertEquals(listOf(good), list.map { it.id })
    }

    @Test fun wrongTypedOptionalFieldsFallBackToDefaults() {
        val id = UUID.randomUUID()
        val list = ConnectionConfigList.decodeLenient(
            """[{"id":"$id","name":"a","host":"h","enabled":"yes","instanceId":12,"displayName":false}]""",
        )
        assertTrue(list.single().enabled)
        assertNull(list.single().instanceId)
        assertNull(list.single().displayName)
    }

    @Test fun garbageIsEmpty() = assertEquals(emptyList<ConnectionConfig>(), ConnectionConfigList.decodeLenient("not json"))
}
```

Append to `MessageEnvelopeTest.kt` (inside the class):

```kotlin
    @Test fun authSuccessCarriesTheServerIdentity() {
        val id = java.util.UUID.randomUUID()
        val msg = MessageEnvelope.decodeServer(
            """{"type":"auth_success","payload":{"protocolVersion":3,"tokenId":"t","serverId":"$id","serverName":"studio"}}""",
        ) as ServerMessage.AuthSuccess
        org.junit.jupiter.api.Assertions.assertEquals(ServerIdentity(id, "studio"), msg.server)
    }

    @Test fun aV2AuthSuccessHasNoIdentityAndAMalformedIdIsIgnored() {
        val v2 = MessageEnvelope.decodeServer("""{"type":"auth_success","payload":{"protocolVersion":2}}""") as ServerMessage.AuthSuccess
        org.junit.jupiter.api.Assertions.assertNull(v2.server)
        val bad = MessageEnvelope.decodeServer("""{"type":"auth_success","payload":{"serverId":"zz"}}""") as ServerMessage.AuthSuccess
        org.junit.jupiter.api.Assertions.assertNull(bad.server)
    }

    @Test fun pairSuccessCarriesTheServerIdentity() {
        val id = java.util.UUID.randomUUID()
        val msg = MessageEnvelope.decodeServer(
            """{"type":"pair_success","payload":{"token":"k","tokenId":"t","label":"l","serverId":"$id","serverName":"studio"}}""",
        ) as ServerMessage.PairSuccess
        org.junit.jupiter.api.Assertions.assertEquals(ServerIdentity(id, "studio"), msg.server)
    }
```

(Check the object name with `grep -n "^object\|fun decodeServer" core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt`; adjust the qualifier if the decoder lives on a differently named object.)

Append to `ConnectionConfigTest.kt`:

```kotlin
    @Test fun titlePrefersTheRelaysOwnName() {
        val c = ConnectionConfig(name = "bookmark", host = "h")
        org.junit.jupiter.api.Assertions.assertEquals("bookmark", c.title)
        org.junit.jupiter.api.Assertions.assertEquals("studio", c.copy(displayName = "studio").title)
    }
```

`core-net/src/test/kotlin/relay/net/SessionControllerIdentityTest.kt` — drive `authenticate` with the core-net test double the existing `SessionControllerTest` uses (`ls core-net/src/test/kotlin/relay/net/` and copy its fake-connection construction verbatim):

```kotlin
    @Test fun authenticateRecordsTheServerIdentityAndResetClearsIt() = runTest {
        val id = UUID.randomUUID()
        val (controller, fake) = makeController() // as in SessionControllerTest
        fake.respondTo<ClientMessage.AuthRequest> {
            ServerMessage.AuthSuccess(protocolVersion = 3, tokenId = "t", serverId = id.toString(), serverName = "studio")
        }
        controller.authenticate("tok")
        assertEquals(ServerIdentity(id, "studio"), controller.serverIdentity)
        controller.resetAuth()
        assertNull(controller.serverIdentity, "the next relay may be a different one")
    }

    @Test fun authRequestAnnouncesProtocolThree() = runTest {
        val (controller, fake) = makeController()
        fake.respondTo<ClientMessage.AuthRequest> { ServerMessage.AuthSuccess(protocolVersion = 3) }
        controller.authenticate("tok")
        assertEquals(3, (fake.sent.first() as ClientMessage.AuthRequest).protocolVersion)
    }
```

(`makeController`/`respondTo`/`sent` are placeholders for whatever names the existing core-net test double uses — read it first and use its real API; the assertions are the contract.)

- [ ] **Step 2: Run them to verify they fail**

Run: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-protocol:test :core-net:test 2>&1 | grep -E "error:|e: |FAILED|BUILD" | head -20`
Expected: compile errors — `Unresolved reference: SessionDeepLink`, `ConnectionConfigList`, `server`, `title`, `serverIdentity`.

- [ ] **Step 3: Implement**

`ServerIdentity.kt`:

```kotlin
package relay.protocol

import java.util.UUID

/** The relay's own identity, sent on `auth_success` / `pair_success` from protocol v3 (spec §5.2, §6.2). */
data class ServerIdentity(val id: UUID, val name: String) {
    companion object {
        /** Null for a v2 relay (no id) or a malformed id. */
        fun from(serverId: String?, serverName: String?): ServerIdentity? {
            val id = serverId?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: return null
            return ServerIdentity(id, serverName.orEmpty())
        }
    }
}
```

`SessionRef.kt`:

```kotlin
package relay.protocol

import java.util.UUID

/**
 * One session on one server (spec §5.1). [serverId] is the BOOKMARK id — stable,
 * local, survives a host rename — never the relay's instance id, which is only
 * for routing deep links and flagging duplicates.
 */
data class SessionRef(val serverId: UUID, val sessionId: UUID)
```

`SessionDeepLink.kt`:

```kotlin
package relay.protocol

import java.net.URI
import java.util.UUID

/**
 * `coderelay://session/<uuid>[?server=<instanceId>]` (spec §10). The legacy
 * `clauderelay` scheme is still accepted; a malformed `server` value is ignored
 * rather than rejecting the link. Shared by every Kotlin client and mirrors
 * `Sources/CodeRelayKit/Protocol/SessionDeepLink.swift`.
 */
data class SessionDeepLink(val sessionId: UUID, val serverInstanceId: UUID? = null) {

    val uri: String
        get() = buildString {
            append(SCHEME).append("://").append(HOST).append('/').append(sessionId)
            serverInstanceId?.let { append('?').append(SERVER_QUERY).append('=').append(it) }
        }

    companion object {
        const val SCHEME = "coderelay"
        const val LEGACY_SCHEME = "clauderelay"
        const val HOST = "session"
        const val SERVER_QUERY = "server"

        fun parse(raw: String): SessionDeepLink? {
            val uri = runCatching { URI(raw.trim()) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != SCHEME && scheme != LEGACY_SCHEME) return null
            if (uri.host?.lowercase() != HOST) return null
            val first = uri.path.orEmpty().trim('/').substringBefore('/')
            val sessionId = runCatching { UUID.fromString(first) }.getOrNull() ?: return null
            val server = uri.rawQuery.orEmpty().split('&')
                .map { it.split('=', limit = 2) }
                .firstOrNull { it.size == 2 && it[0].equals(SERVER_QUERY, ignoreCase = true) }
                ?.let { runCatching { UUID.fromString(it[1]) }.getOrNull() }
            return SessionDeepLink(sessionId, server)
        }
    }
}
```

`ServerMessage.kt` — replace the two data classes:

```kotlin
    data class AuthSuccess(
        val protocolVersion: Int? = null,
        val tokenId: String? = null,
        /** protocolVersion ≥ 2: optional relay features, e.g. `prompt_optimizer`. Null from older relays. */
        val capabilities: List<String>? = null,
        /** protocolVersion ≥ 3: the relay's persisted instance id and display name (spec §6.2). */
        val serverId: String? = null,
        val serverName: String? = null,
    ) : ServerMessage {
        override val typeString get() = "auth_success"
        val server: ServerIdentity? get() = ServerIdentity.from(serverId, serverName)
    }
```

```kotlin
    data class PairSuccess(
        val token: String,
        val tokenId: String,
        val label: String,
        val serverId: String? = null,
        val serverName: String? = null,
    ) : ServerMessage {
        override val typeString get() = "pair_success"
        val server: ServerIdentity? get() = ServerIdentity.from(serverId, serverName)
    }
```

`MessageEnvelope.kt` decode:

```kotlin
            "auth_success" -> ServerMessage.AuthSuccess(
                payload.intOrNull("protocolVersion"), payload.stringOrNull("tokenId"),
                payload.stringListOrNull("capabilities"),
                payload.stringOrNull("serverId"), payload.stringOrNull("serverName"),
            )
```

```kotlin
            "pair_success" -> ServerMessage.PairSuccess(
                payload.string("token"), payload.string("tokenId"), payload.string("label"),
                payload.stringOrNull("serverId"), payload.stringOrNull("serverName"),
            )
```

If the envelope also has an `encodeServer`/test helper that writes these types, add the two fields there the same way (`grep -n "AuthSuccess\|PairSuccess" -r core-protocol/src`).

`ConnectionConfig.kt`:

```kotlin
@Serializable
data class ConnectionConfig(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val host: String,
    val port: UShort = 9200u,
    val useTLS: Boolean = false,
    /** Live in the workspace (multi-server spec §9). Pre-feature bookmarks decode as enabled; the hub's one-time migration then disables all but the last-used one. */
    val enabled: Boolean = true,
    /** The relay's instance id, learned from `auth_success` (spec §5.2). */
    @Serializable(with = UuidSerializer::class) val instanceId: UUID? = null,
    /** The relay's own display name, learned from `auth_success`. */
    val displayName: String? = null,
) {
    val wsUrl: String
        get() = "${if (useTLS) "wss" else "ws"}://$host:$port"

    /** Section / row title: the relay's own name when learned, else the bookmark name. */
    val title: String get() = displayName ?: name
}
```

(`UuidSerializer` on a nullable property: if kotlinx rejects it, add `NullableUuidSerializer` next to `UuidSerializer` with `UuidSerializer.nullable` — `grep -n "object UuidSerializer" -r core-protocol/src/main`.)

`ConnectionConfigList.kt`:

```kotlin
package relay.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * Decodes a stored bookmark list element by element. The stores used to decode
 * the whole list in one call, so one bookmark written in another shape (a
 * future build, then a downgrade) failed the decode, the store returned an
 * empty list, and the next save overwrote every bookmark. Wrong-typed optional
 * multi-server fields fall back to their defaults for the same reason.
 */
object ConnectionConfigList {
    fun decodeLenient(json: String): List<ConnectionConfig> {
        val array = runCatching { WireJson.instance.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: return emptyList()
        return array.mapNotNull { element -> decodeOne(element) }
    }

    private fun decodeOne(element: JsonElement): ConnectionConfig? {
        val obj = element as? JsonObject ?: return null
        val cleaned = JsonObject(obj.toMutableMap().apply {
            if ((this["enabled"] as? JsonPrimitive)?.booleanOrNull == null) remove("enabled")
            if (!isUuidString(this["instanceId"])) remove("instanceId")
            if ((this["displayName"] as? JsonPrimitive)?.isString != true) remove("displayName")
        })
        return runCatching { WireJson.instance.decodeFromJsonElement(ConnectionConfig.serializer(), cleaned) }.getOrNull()
    }

    private fun isUuidString(element: JsonElement?): Boolean {
        val p = element as? JsonPrimitive ?: return false
        return p.isString && runCatching { java.util.UUID.fromString(p.content) }.isSuccess
    }
}
```

Both `SavedConnectionStore.loadAll()` implementations: replace the `WireJson.instance.decodeFromString(listSerializer, raw)` call with `ConnectionConfigList.decodeLenient(raw)` (Android: the DataStore string at key `saved_connections` and the legacy key; Linux: `servers.json` contents). Leave encoding unchanged.

`SessionController.kt`: `ProtocolVersions.CURRENT = 3`; add `var serverIdentity: ServerIdentity? = null; private set`; in `authenticate`, on `AuthSuccess` set `serverIdentity = response.server`; in `resetAuth()` set `serverIdentity = null`.

`feature-workspace/.../DeepLinks.kt`: `parseSessionId(uri)` becomes `SessionDeepLink.parse(uri)?.sessionId`; add `fun parseSessionLink(uri: String): SessionDeepLink? = SessionDeepLink.parse(uri)`; `sessionUri(id)` stays.

- [ ] **Step 4: Run the tests (both builds)**

Run Android: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-protocol:test :core-net:test :core-storage:testDebugUnitTest :feature-workspace:testDebugUnitTest 2>&1 | tail -5` → `BUILD SUCCESSFUL`.
Run Linux: `cd CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :shared-protocol:test :shared-net:test :linux-storage:test --no-daemon 2>&1 | tail -5` → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/core-protocol CodeRelayAndroid/core-net CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/SavedConnectionStore.kt CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/SavedConnectionStore.kt CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/DeepLinks.kt
git commit -m "feat(kotlin): protocol v3 server identity, SessionRef, SessionDeepLink, multi-server bookmark fields

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Coordinator hooks for the hub (core-session, core-net, both ownership stores)

**Files:**
- Modify: `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/RelayConnection.kt` (`var state` line 83 becomes backed by a `MutableStateFlow`); `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt` (`CoordinatorConnection` interface line 32, `RelayConnectionGateway` line 61, coordinator state + `createNewSession`/`switchToSession`/`attachRemoteSession`/`reloadTerminalFromServer` catches, new `detachForHub`); `.../SessionHandshake.kt` (token-rejection branch ~line 215, success path ~line 205); `.../RecoveryController.kt` (`recoveryFailed` line 195 becomes a `StateFlow`); `CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/SessionOwnershipStore.kt` and `CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/SessionOwnershipStore.kt` (namespace parameter + legacy move); `core-session/src/test/kotlin/relay/session/CoordinatorTestDoubles.kt` (`FakeCoordinatorConnection.connectedFlow`)
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorHubHooksTest.kt`; `CodeRelayLinux/linux-storage/src/test/kotlin/relay/storage/SessionOwnershipStoreTest.kt` (additions)

**Interfaces:**
- Consumes: Task 1 `ServerIdentity`, `SessionController.serverIdentity`.
- Produces on `SessionCoordinator`: `val connected: StateFlow<Boolean>`; `val serverIdentity: StateFlow<ServerIdentity?>`; `val isAuthRejected: StateFlow<Boolean>`; `val recoveryFailed: StateFlow<Boolean>`; `val lastLoadFailed: StateFlow<Boolean>`; `val loadEndedInFailure: Boolean`; `val expectsSessionToLoad: Boolean`; `suspend fun detachForHub(budgetMs: Long = 3_000)`; internal `attachEpoch: Long`. On `CoordinatorConnection`: `val connectedFlow: StateFlow<Boolean>` (default `MutableStateFlow(true)`). On `RelayConnection`: `val stateFlow: StateFlow<ConnectionState>`. On both `SessionOwnershipStore`s: constructor parameter `namespace: String = ""` (keys/files become `"$namespace.sessionNames"` etc. when non-empty) and `fun moveLegacyInto(namespace: String?)` (copies the un-namespaced maps into `namespace` when non-null, then clears them).

- [ ] **Step 1: Write the failing tests**

`SessionCoordinatorHubHooksTest.kt` — construct exactly like `SessionCoordinatorTest` (lines 40–87: `StandardTestDispatcher(testScheduler)`, `FakeCoordinatorConnection(log)`, `SessionController(FakeConnectionSurface(log))`, `FakeOwnershipStore(log)`), via a local `makeCoordinator()` helper copied from there:

```kotlin
package relay.session

import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ServerIdentity
import relay.protocol.ServerMessage
import java.util.UUID

class SessionCoordinatorHubHooksTest {

    @Test fun connectedFollowsTheTransport() = runTest {
        val (coord, conn) = makeCoordinator(this)
        conn.setConnected(false); advanceUntilIdle()
        assertFalse(coord.connected.value)
        conn.setConnected(true); advanceUntilIdle()
        assertTrue(coord.connected.value, "the hub republishes on this flow; a plain var fired nothing")
    }

    @Test fun serverIdentityIsPublishedAfterAuth() = runTest {
        val id = UUID.randomUUID()
        val (coord, _, surface) = makeCoordinatorWithSurface(this)
        surface.responder = { m -> if (m is relay.protocol.ClientMessage.AuthRequest) ServerMessage.AuthSuccess(protocolVersion = 3, serverId = id.toString(), serverName = "studio") else null }
        coord.connect(); advanceUntilIdle()
        assertEquals(ServerIdentity(id, "studio"), coord.serverIdentity.value)
    }

    @Test fun aRejectedTokenIsFlaggedAndASuccessfulAuthClearsIt() = runTest {
        val (coord, _, surface) = makeCoordinatorWithSurface(this)
        surface.responder = { m -> if (m is relay.protocol.ClientMessage.AuthRequest) ServerMessage.AuthFailure("bad token") else null }
        runCatching { coord.connect() }; advanceUntilIdle()
        assertTrue(coord.isAuthRejected.value, "the hub shows authFailed with Re-pair")
        surface.responder = { m -> if (m is relay.protocol.ClientMessage.AuthRequest) ServerMessage.AuthSuccess(protocolVersion = 3) else null }
        coord.performHandshake(SessionHandshake.Reason.WAKE); advanceUntilIdle()
        assertFalse(coord.isAuthRejected.value)
    }

    @Test fun detachForHubClearsLocallyEvenWhenTheWireIsDead() = runTest {
        val (coord, conn) = makeCoordinator(this)
        val id = UUID.randomUUID()
        coord.setActiveSessionForTest(id)
        conn.alive = false
        conn.sendHangs = true                   // the detach RPC never returns
        coord.detachForHub(budgetMs = 100)
        assertNull(coord.activeSessionId.value, "cleared before the RPC, so the hub can attach elsewhere at once")
    }

    @Test fun detachForHubInvalidatesAnAttachInFlight() = runTest {
        // D9: an attach that began before the hub moved to another server must
        // not publish when its RPC returns.
        val (coord, _, surface) = makeCoordinatorWithSurface(this)
        val target = UUID.randomUUID()
        surface.parkResume = true
        val switching = launch { coord.switchToSession(target) }
        advanceUntilIdle()                       // parked inside resumeSession
        coord.detachForHub(budgetMs = 100)
        surface.releaseResume(target)
        switching.join(); advanceUntilIdle()
        assertNull(coord.activeSessionId.value)
    }

    @Test fun failedSwitchIsMarkedFailedBeforeItsPhaseClears() = runTest {
        val (coord, _, surface) = makeCoordinatorWithSurface(this)
        surface.responder = { m -> if (m is relay.protocol.ClientMessage.SessionResume) ServerMessage.Error(500, "boom") else null }
        var failedWhenCleared: Boolean? = null
        val job = launch {
            coord.sessionLoadPhase.collect { phase ->
                if (phase == null && failedWhenCleared == null && coord.lastLoadFailed.value) failedWhenCleared = true
                else if (phase == null && failedWhenCleared == null && coord.sessionLoadPhase.value == null) failedWhenCleared = coord.lastLoadFailed.value
            }
        }
        coord.switchToSession(UUID.randomUUID()); advanceUntilIdle()
        assertTrue(coord.lastLoadFailed.value)
        assertTrue(coord.loadEndedInFailure)
        job.cancel()
    }

    @Test fun reloadPublishesAttachingAndClearsItOnFailure() = runTest {
        val (coord, _, surface) = makeCoordinatorWithSurface(this)
        val id = UUID.randomUUID()
        coord.installTerminalForTest(id); coord.setActiveSessionForTest(id)
        surface.responder = { m -> if (m is relay.protocol.ClientMessage.SessionResume) ServerMessage.Error(500, "boom") else null }
        val seen = mutableListOf<SessionLoadPhase?>()
        val job = launch { coord.sessionLoadPhase.collect { seen += it } }
        advanceUntilIdle()
        coord.reloadTerminalFromServer(id); advanceUntilIdle()
        assertTrue(SessionLoadPhase.Attaching in seen, "the name-label tap raises the sheet at once")
        assertNull(coord.sessionLoadPhase.value)
        assertTrue(coord.lastLoadFailed.value)
        job.cancel()
    }

    @Test fun recoveryFailedIsObservable() = runTest {
        val (coord, _) = makeCoordinator(this)
        assertFalse(coord.recoveryFailed.value)
        coord.cancelRecovery(); advanceUntilIdle()
        assertTrue(coord.recoveryFailed.value, "a cancelled reconnect never closes the sheet with Ready")
    }
}
```

`makeCoordinator`/`makeCoordinatorWithSurface` live in the test file (build the coordinator as `SessionCoordinatorTest` does and return the fakes). The fakes need four small additions in `CoordinatorTestDoubles.kt`, written with the tests: `FakeCoordinatorConnection.setConnected(Boolean)` (writes `connected` and a backing `MutableStateFlow` returned by `override val connectedFlow`), `FakeCoordinatorConnection.sendHangs` (when true, `send` suspends on `awaitCancellation()`), `FakeConnectionSurface.parkResume` + `releaseResume(id)` (park the `SessionResume` responder on a `CompletableDeferred` until released, then reply `SessionResumed(id)`). Test hooks on the coordinator: `internal fun setActiveSessionForTest(id: UUID?)` and `internal fun installTerminalForTest(id: UUID)` (puts a fresh `newTerminalVm()` in `terminalCache`).

Linux `SessionOwnershipStoreTest.kt` additions:

```kotlin
    @Test fun namespacesKeepTwoServersApart(@TempDir dir: File) {
        val sid = UUID.randomUUID()
        SessionOwnershipStore(dir, namespace = "a").setName(sid, "alpha")
        SessionOwnershipStore(dir, namespace = "b").setName(sid, "bravo")
        assertEquals("alpha", SessionOwnershipStore(dir, namespace = "a").names[sid])
        assertEquals("bravo", SessionOwnershipStore(dir, namespace = "b").names[sid])
    }

    @Test fun legacyMapsMoveIntoTheKeptServerAndLeaveTheLegacyEmpty(@TempDir dir: File) {
        val sid = UUID.randomUUID()
        SessionOwnershipStore(dir).setName(sid, "legacy")
        SessionOwnershipStore(dir).moveLegacyInto("kept")
        assertEquals("legacy", SessionOwnershipStore(dir, namespace = "kept").names[sid])
        assertTrue(SessionOwnershipStore(dir).names.isEmpty())
    }
```

(Android's store needs a `Context`; its namespace behaviour is the same code path and is covered on device in Task 11. Add the same two cases to `core-storage/src/androidTest` only if that suite already constructs the store — `ls core-storage/src/androidTest`; CI compiles it with `:core-storage:compileDebugAndroidTestKotlin`.)

- [ ] **Step 2: Run to verify failure**

Run: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-session:test 2>&1 | grep -E "^e: |FAILED|BUILD" | head -12`
Expected: `Unresolved reference: connected / serverIdentity / isAuthRejected / detachForHub / lastLoadFailed / recoveryFailed …`.

- [ ] **Step 3: Implement**

`RelayConnection.kt`:

```kotlin
    private val _stateFlow = MutableStateFlow(ConnectionState.DISCONNECTED)
    /** Observable transport state; [state] reads and writes it. */
    val stateFlow: StateFlow<ConnectionState> = _stateFlow.asStateFlow()
    var state: ConnectionState
        get() = _stateFlow.value
        private set(value) { _stateFlow.value = value }
```

(Keep the five existing `state = …` writes; if `state` was publicly settable anywhere — `grep -rn "\.state = " core-net core-session ../CodeRelayLinux` — keep the setter's visibility as it was.)

`CoordinatorConnection` gains:

```kotlin
    /** Observable "is there a socket": the hub's section status reads it (spec §7.2). */
    val connectedFlow: StateFlow<Boolean> get() = MutableStateFlow(true)
```

and `RelayConnectionGateway` overrides it with `connection.stateFlow.map { it == RelayConnection.ConnectionState.CONNECTED }.stateIn(...)` — it has no scope, so instead give the gateway a cached `MutableStateFlow` updated by a collector started from the coordinator's `scope` in `SessionCoordinator.init`: `scope.launch { connection.connectedFlowSource.collect { _connected.value = it } }`. Simplest exact form: in `SessionCoordinator`:

```kotlin
    private val _connected = MutableStateFlow(connection.isConnected)
    /** The hub republishes on this; a plain property fired nothing (Plan 2 lesson). */
    val connected: StateFlow<Boolean> = _connected.asStateFlow()
    // in init:
    scope.launch { connection.connectedFlow.collect { _connected.value = it } }
```

with `RelayConnectionGateway.connectedFlow` = a `MutableStateFlow` it keeps in sync by registering on `connection.stateFlow` lazily:

```kotlin
    override val connectedFlow: StateFlow<Boolean> by lazy {
        object : StateFlow<Boolean> {
            override val value get() = connection.state == RelayConnection.ConnectionState.CONNECTED
            override val replayCache get() = listOf(value)
            override suspend fun collect(collector: kotlinx.coroutines.flow.FlowCollector<Boolean>): Nothing {
                connection.stateFlow.collect { collector.emit(it == RelayConnection.ConnectionState.CONNECTED) }
                awaitCancellation()
            }
        }
    }
```

(If implementing `StateFlow` directly trips `@OptIn(InternalCoroutinesApi)` or the "not stable for inheritance" warning-as-error, change the interface member to `val connectedFlow: Flow<Boolean>` and keep `SessionCoordinator.connected` as the `StateFlow` — record the ruling.)

Coordinator additions (place next to the other recovery/state flows):

```kotlin
    private val _serverIdentity = MutableStateFlow<ServerIdentity?>(null)
    val serverIdentity: StateFlow<ServerIdentity?> = _serverIdentity.asStateFlow()

    private val _isAuthRejected = MutableStateFlow(false)
    /** The relay refused this token; the hub shows the section as authFailed and Re-pair. */
    val isAuthRejected: StateFlow<Boolean> = _isAuthRejected.asStateFlow()

    val recoveryFailed: StateFlow<Boolean> get() = recoveryController.recoveryFailed

    private val _lastLoadFailed = MutableStateFlow(false)
    /**
     * The most recent switch / create / attach / reload ended in failure. Set at
     * the TOP of each failure branch, before the phase clears, and reset when
     * the next load starts — the loading sheet shows "Ready" only when a load
     * ends with this false (mirrors Swift `lastLoadFailed`).
     */
    val lastLoadFailed: StateFlow<Boolean> = _lastLoadFailed.asStateFlow()

    /** A load just ended badly: its own flag, or an error the user is about to see. */
    val loadEndedInFailure: Boolean
        get() = _lastLoadFailed.value || _errorMessage.value != null ||
            connectionTimedOut.value || sessionAttachFailed.value

    /** A session is attached — the handshake phases then narrate a session, not a bare server. */
    val expectsSessionToLoad: Boolean get() = _activeSessionId.value != null

    /** Bumped by [detachForHub]; an attach that began before the bump must not publish. */
    internal var attachEpoch: Long = 0
        private set

    internal fun recordServerIdentity(identity: ServerIdentity?) { _serverIdentity.value = identity }
    internal fun setAuthRejected(rejected: Boolean) { _isAuthRejected.value = rejected }
```

`recordServerIdentity(sessionController.serverIdentity)` is called wherever the coordinator observes a successful authentication — the `authenticate` lambda passed to `AuthCoordinator` (find it with `grep -n "AuthCoordinator(" core-session/src/main/kotlin/relay/session/SessionCoordinator.kt`) and the handshake's auth step; `SessionHandshake` calls `coordinator.setAuthRejected(true)` in the `isTokenRejection` branch before `fail(error)`, and `coordinator.setAuthRejected(false)` right after its successful `authenticate`.

`RecoveryController`: `private val _recoveryFailed = MutableStateFlow(false); val recoveryFailed: StateFlow<Boolean> = _recoveryFailed.asStateFlow()`; replace the three `recoveryFailed = x` writes with `_recoveryFailed.value = x` and every read with `_recoveryFailed.value`.

`detachForHub`:

```kotlin
    /**
     * Detaches whatever this coordinator has attached and clears the selection,
     * so the hub can attach on another server (D9: one attachment across all
     * servers). Clears LOCALLY first, then sends the detach bounded by
     * [budgetMs]: a stuck server must not block a cross-server switch, and the
     * straggling RPC is left to finish (or fail) on its own in [scope]. Bumps
     * [attachEpoch], so a switch / create / attach whose RPC is still in flight
     * undoes itself instead of publishing. Never surfaces an error — the user
     * asked for the OTHER session.
     */
    suspend fun detachForHub(budgetMs: Long = 3_000) {
        attachEpoch += 1
        val id = _activeSessionId.value ?: return
        terminalCache.view(id)?.prepareForSwitch()
        clearActiveSession()
        if (recoveryController.isRecovering.value) return
        val rpc = scope.async { runCatching { sessionController.detach() } }
        withTimeoutOrNull(budgetMs) { rpc.await() }
    }

    /** True when [detachForHub] ran since [epoch] was captured. */
    private fun attachSuperseded(epoch: Long): Boolean = epoch != attachEpoch

    /** Detaches what a superseded attach just attached, without publishing it. */
    private suspend fun undoSupersededAttach(id: UUID) {
        if (_activeSessionId.value == id) clearActiveSession()
        terminalCache.view(id)?.prepareForSwitch()
        _sessionLoadPhase.value = null
        val rpc = scope.async { runCatching { sessionController.detach() } }
        withTimeoutOrNull(3_000) { rpc.await() }
    }
```

Guards and flags in the four load paths:
- `createNewSession`: after `_sessionLoadPhase.value = SessionLoadPhase.Attaching` add `_lastLoadFailed.value = false; val epoch = attachEpoch`; right after the `withAuth { … createSession … }` returns, `if (attachSuperseded(epoch)) { undoSupersededAttach(sessionId); return }`; first line of its `catch`: `_lastLoadFailed.value = true`.
- `switchToSession`: next to `_sessionLoadPhase.value = SessionLoadPhase.Attaching` add `_lastLoadFailed.value = false` and capture `val epoch = attachEpoch` before the `withAuth`; after it returns, `if (attachSuperseded(epoch)) { undoSupersededAttach(id); return }`; first line of its `catch`: `_lastLoadFailed.value = true`.
- `attachRemoteSession`: same three edits around its `withAuth` (and before its previous-session rollback in the `catch`).
- `reloadTerminalFromServer`: after `vm.beginServerReload()` add `_sessionLoadPhase.value = SessionLoadPhase.Attaching; _lastLoadFailed.value = false`; first two lines of its `catch`: `_lastLoadFailed.value = true; _sessionLoadPhase.value = null`. Then confirm the success path clears the phase: the replay that a server reload triggers must reach the `onReplayDelivered` hook installed by `wireTerminalOutput` (line ~1217). Check with `grep -n "fun beginServerReload\|fun endReplay\|onReplayDelivered" terminal/src/main/kotlin -r`: if `beginServerReload` does not go through the same `beginReplay`/`endReplay` pair that fires `onReplayDelivered`, add `_sessionLoadPhase.value = null` where the vm reports the reload landed (its `isReloadingFromServer` going false) and record the ruling.

Both `SessionOwnershipStore`s: add `namespace: String = ""` as the LAST constructor parameter (keeps every existing call site); `namesKey = if (namespace.isEmpty()) NAMES_KEY else "$namespace.$NAMES_KEY"`, same for `agentsKey`; add

```kotlin
    /**
     * One-time multi-server migration (spec §9): copies this store's
     * un-namespaced maps into [namespace] (the server that stays enabled) and
     * clears them; with a null [namespace] the legacy maps are only dropped.
     */
    fun moveLegacyInto(namespace: String?) {
        if (namespace != null) {
            val target = /* same constructor args */ SessionOwnershipStore(/* context|dir */, namespace = namespace)
            names.forEach { (id, n) -> target.setName(id, n) }
            agents.forEach { (id, a) -> target.setAgent(id, a) }
        }
        names.keys.toList().forEach { setName(it, null) }
        agents.keys.toList().forEach { setAgent(it, null) }
    }
```

(Android passes `context` and `deviceId`; Linux passes `dir`. Keep the method on the instance so the app can call it on the legacy store it already builds.)

- [ ] **Step 4: Run the tests (both builds)**

Android: `./gradlew :core-session:test :core-net:test :core-storage:testDebugUnitTest :core-storage:compileDebugAndroidTestKotlin` → `BUILD SUCCESSFUL`, all existing `SessionCoordinatorTest`/`RecoveryControllerTest`/`SessionHandshakeTest` cases still pass.
Linux: `./gradlew :shared-net:test :shared-session:test :linux-storage:test --no-daemon` → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/core-net CodeRelayAndroid/core-session CodeRelayAndroid/core-storage CodeRelayLinux/linux-storage
git commit -m "feat(kotlin): coordinator hooks for the multi-server hub — connected/identity/auth-rejected flows, bounded detachForHub with attach epoch, namespaced ownership stores

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Hub model — `ServerSlot`, `ServerSection`, status, state store, migration (core-session)

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/hub/ServerSlot.kt`, `.../hub/CoordinatorServerSlot.kt`, `.../hub/ServerSection.kt`, `.../hub/HubStateStore.kt`, `.../hub/HubMigration.kt`
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/hub/ServerSectionStatusTest.kt`, `.../hub/HubStateStoreTest.kt`, `.../hub/HubMigrationTest.kt`, `.../hub/FakeServerSlot.kt` (test double used by Tasks 4–5)

**Interfaces:**
- Consumes: Task 1 `ConnectionConfig` fields, `SessionRef`, `ServerIdentity`; Task 2 coordinator flows.
- Produces:

```kotlin
interface ServerSlot {
    val config: ConnectionConfig
    val sessions: StateFlow<List<SessionInfo>>          // the coordinator's activeSessions (pane list)
    val activeSessionId: StateFlow<UUID?>
    val isRecovering: StateFlow<Boolean>
    val recoveryFailed: StateFlow<Boolean>
    val isAuthRejected: StateFlow<Boolean>
    val isPerformingHandshake: StateFlow<Boolean>
    val connected: StateFlow<Boolean>
    val serverIdentity: StateFlow<ServerIdentity?>
    val sessionsAwaitingInput: StateFlow<Set<UUID>>
    /** Fires after any of the above changed (the hub republishes on it). */
    val changes: Flow<Unit>
    fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup>
    suspend fun start()
    suspend fun switchToSession(id: UUID)
    suspend fun createNewSession()
    suspend fun detachForHub(budgetMs: Long)
    suspend fun attachRemoteSession(id: UUID, serverName: String?)
    fun handleForegroundTransition()
    fun triggerUserRecovery()
    suspend fun syncPush(settings: PushSettings)
    suspend fun tearDown()
}
data class PushSettings(val deviceToken: String?, val permissionGranted: Boolean, val deviceId: String,
                        val pushEnabled: Boolean, val notifyOnFinished: Boolean)
open class CoordinatorServerSlot(final override val config: ConnectionConfig, val coordinator: SessionCoordinator) : ServerSlot
sealed interface ServerSectionStatus { Connecting; Live; Reconnecting; Offline; data class AuthFailed(val message: String); Disabled; val isLive: Boolean }
fun ServerSectionStatus.Companion.derive(enabled, connected, isRecovering, isPerformingHandshake, authRejected): ServerSectionStatus
data class ServerSection(config, status, sessions, isCached, rollups, awaitingInput, isCollapsed, isDuplicateInstance = false) { val id; val title }
data class HubAggregate(liveServers = 0, totalServers = 0, enabledServers = 0, sessionsAwaitingInput = 0)
interface HubPreferences { fun get(key: String): String?; fun put(key: String, value: String?) }
class HubStateStore(prefs: HubPreferences, keyPrefix: String) { loadActiveRef/saveActiveRef/loadCollapsedServers/saveCollapsedServers/isMigrated/markMigrated }
object HubMigration { suspend fun run(bookmarks: BookmarkStore, lastServerId: String?, state: HubStateStore, moveLegacyOwnership: (UUID?) -> Unit): Boolean }
interface BookmarkStore { suspend fun loadAll(): List<ConnectionConfig>; suspend fun saveAll(list: List<ConnectionConfig>); suspend fun add(c: ConnectionConfig); suspend fun delete(id: UUID) }
interface TokenSource { fun loadToken(id: UUID): String?; fun deleteToken(id: UUID) }
```

- [ ] **Step 1: Write the failing tests**

`ServerSectionStatusTest.kt` (port of `Tests/CodeRelayClientTests/ServerSectionHeaderTests.swift`'s derive table):

```kotlin
package relay.session.hub

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ServerSectionStatusTest {
    private fun d(enabled: Boolean = true, connected: Boolean = true, recovering: Boolean = false,
                  handshake: Boolean = false, rejected: Boolean = false) =
        ServerSectionStatus.derive(enabled, connected, recovering, handshake, rejected)

    @Test fun table() {
        assertEquals(ServerSectionStatus.Disabled, d(enabled = false, rejected = true))
        assertEquals(ServerSectionStatus.AuthFailed("Token rejected by the relay"), d(rejected = true, recovering = true))
        assertEquals(ServerSectionStatus.Reconnecting, d(recovering = true, connected = false))
        assertEquals(ServerSectionStatus.Connecting, d(handshake = true))
        assertEquals(ServerSectionStatus.Live, d())
        assertEquals(ServerSectionStatus.Offline, d(connected = false))
    }
}
```

`HubStateStoreTest.kt`:

```kotlin
package relay.session.hub

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.SessionRef
import java.util.UUID

class MapPreferences : HubPreferences {
    val map = mutableMapOf<String, String>()
    override fun get(key: String) = map[key]
    override fun put(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
}

class HubStateStoreTest {
    @Test fun activeRefRoundTripsAndAGarbledValueReadsAsNone() {
        val prefs = MapPreferences(); val store = HubStateStore(prefs, "relay")
        val ref = SessionRef(UUID.randomUUID(), UUID.randomUUID())
        store.saveActiveRef(ref); assertEquals(ref, store.loadActiveRef())
        store.saveActiveRef(null); assertNull(store.loadActiveRef())
        prefs.put("relay.hub.activeRef", "nonsense"); assertNull(store.loadActiveRef())
    }

    @Test fun collapsedServersAndMigratedFlag() {
        val store = HubStateStore(MapPreferences(), "relay")
        val a = UUID.randomUUID(); val b = UUID.randomUUID()
        store.saveCollapsedServers(setOf(a, b)); assertEquals(setOf(a, b), store.loadCollapsedServers())
        assertFalse(store.isMigrated); store.markMigrated(); assertTrue(store.isMigrated)
    }
}
```

`HubMigrationTest.kt` (port of `HubMigrationTests.swift`; `InMemoryBookmarks : BookmarkStore` lives in `FakeServerSlot.kt`):

```kotlin
package relay.session.hub

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import java.util.UUID

class HubMigrationTest {
    private fun cfg(n: String) = ConnectionConfig(name = n, host = "$n.local")

    @Test fun onlyTheLastUsedBookmarkStaysEnabledAndGetsTheLegacyMaps() = runTest {
        val a = cfg("a"); val b = cfg("b"); val c = cfg("c")
        val store = InMemoryBookmarks(listOf(a, b, c)); val state = HubStateStore(MapPreferences(), "relay")
        var movedInto: UUID? = UUID.randomUUID()
        assertTrue(HubMigration.run(store, b.id.toString(), state) { movedInto = it })
        assertEquals(listOf(false, true, false), store.loadAll().map { it.enabled })
        assertEquals(b.id, movedInto)
        assertTrue(state.isMigrated)
    }

    @Test fun aSingleBookmarkIsEnabledEvenWithoutALastUsedId() = runTest {
        val a = cfg("a"); val store = InMemoryBookmarks(listOf(a)); val state = HubStateStore(MapPreferences(), "relay")
        HubMigration.run(store, "", state) {}
        assertTrue(store.loadAll().single().enabled)
    }

    @Test fun aStaleLastUsedIdWithSeveralBookmarksDisablesAllAndDropsTheLegacyMaps() = runTest {
        val store = InMemoryBookmarks(listOf(cfg("a"), cfg("b"))); val state = HubStateStore(MapPreferences(), "relay")
        var movedInto: UUID? = UUID.randomUUID()
        HubMigration.run(store, UUID.randomUUID().toString(), state) { movedInto = it }
        assertTrue(store.loadAll().none { it.enabled })
        assertEquals(null, movedInto, "maps of a server that no longer exists are dropped, not guessed onto one")
    }

    @Test fun runsOnce() = runTest {
        val store = InMemoryBookmarks(listOf(cfg("a"), cfg("b"))); val state = HubStateStore(MapPreferences(), "relay")
        HubMigration.run(store, "", state) {}
        store.saveAll(store.loadAll().map { it.copy(enabled = true) })
        assertFalse(HubMigration.run(store, "", state) {})
        assertTrue(store.loadAll().all { it.enabled }, "a second launch never touches the user's choices")
    }
}
```

`FakeServerSlot.kt` (test double; port of `Tests/CodeRelayClientTests/Hub/FakeServerSlot.swift` including the fix-pass additions — `startHangs`, `foregroundHangs`, `switchFails`, `detachHangs`, `log`):

```kotlin
package relay.session.hub

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import java.util.UUID

class FakeServerSlot(override val config: ConnectionConfig) : ServerSlot {
    override val sessions = MutableStateFlow<List<SessionInfo>>(emptyList())
    override val activeSessionId = MutableStateFlow<UUID?>(null)
    override val isRecovering = MutableStateFlow(false)
    override val recoveryFailed = MutableStateFlow(false)
    override val isAuthRejected = MutableStateFlow(false)
    override val isPerformingHandshake = MutableStateFlow(false)
    override val connected = MutableStateFlow(false)
    override val serverIdentity = MutableStateFlow<ServerIdentity?>(null)
    override val sessionsAwaitingInput = MutableStateFlow<Set<UUID>>(emptySet())
    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 64)
    override val changes: Flow<Unit> = _changes
    fun changed() { _changes.tryEmit(Unit) }

    var log: ((String) -> Unit)? = null
    var startCount = 0; var foregroundCount = 0; var recoveryCount = 0; var detachCount = 0; var createCount = 0
    val switchedTo = mutableListOf<UUID>(); val remoteAttaches = mutableListOf<UUID>(); val pushSyncs = mutableListOf<PushSettings>()
    var tornDown = false
    var startHangs = false; val startGate = CompletableDeferred<Unit>()
    var foregroundHangs = false
    var detachHangs = false; val detachGate = CompletableDeferred<Unit>()
    var switchFails = false

    override fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup> = emptyList()
    override suspend fun start() { startCount += 1; log?.invoke("start:${config.name}"); if (startHangs) startGate.await() }
    override suspend fun switchToSession(id: UUID) { switchedTo += id; log?.invoke("switch:${config.name}"); if (!switchFails) activeSessionId.value = id; changed() }
    override suspend fun createNewSession() { createCount += 1; activeSessionId.value = UUID.randomUUID(); log?.invoke("create:${config.name}"); changed() }
    override suspend fun detachForHub(budgetMs: Long) { detachCount += 1; log?.invoke("detach:${config.name}"); activeSessionId.value = null; if (detachHangs) detachGate.await(); changed() }
    override suspend fun attachRemoteSession(id: UUID, serverName: String?) { remoteAttaches += id; activeSessionId.value = id; changed() }
    override fun handleForegroundTransition() { foregroundCount += 1; log?.invoke("fg:${config.name}") }
    override fun triggerUserRecovery() { recoveryCount += 1; log?.invoke("recover:${config.name}") }
    override suspend fun syncPush(settings: PushSettings) { pushSyncs += settings; log?.invoke("push:${settings.pushEnabled}") }
    override suspend fun tearDown() { tornDown = true; log?.invoke("teardown:${config.name}") }

    fun goLive(list: List<SessionInfo>) { connected.value = true; isPerformingHandshake.value = false; sessions.value = list; changed() }
    fun goOffline() { connected.value = false; changed() }
}

class InMemoryBookmarks(initial: List<ConnectionConfig> = emptyList()) : BookmarkStore {
    private var list = initial
    override suspend fun loadAll() = list
    override suspend fun saveAll(list: List<ConnectionConfig>) { this.list = list }
    override suspend fun add(c: ConnectionConfig) { list = if (list.any { it.id == c.id }) list.map { if (it.id == c.id) c else it } else list + c }
    override suspend fun delete(id: UUID) { list = list.filterNot { it.id == id } }
}

class FakeTokens(var tokens: MutableMap<UUID, String> = mutableMapOf(), var throwsFor: Set<UUID> = emptySet()) : TokenSource {
    override fun loadToken(id: UUID): String? { if (id in throwsFor) error("keyring locked"); return tokens[id] }
    override fun deleteToken(id: UUID) { tokens.remove(id) }
}
```

(`foregroundHangs` is unused because `handleForegroundTransition` is non-suspending on Kotlin — the coordinator launches its own recovery, so the fan-out cannot serialise; keep the field out if lint flags it.)

- [ ] **Step 2: Run to verify failure**

`./gradlew :core-session:test 2>&1 | grep -E "^e: " | head` → unresolved `ServerSectionStatus`, `HubStateStore`, `HubMigration`, `ServerSlot`, `BookmarkStore`, `TokenSource`, `PushSettings`.

- [ ] **Step 3: Implement**

`ServerSlot.kt` — the interface, `PushSettings`, `BookmarkStore`, `TokenSource` exactly as in **Interfaces** above, each with a one-line KDoc pointing at the spec section.

`CoordinatorServerSlot.kt`:

```kotlin
package relay.session.hub

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import relay.session.SessionCoordinator
import java.util.UUID

/**
 * Adapts one unchanged [SessionCoordinator] to [ServerSlot]. `open` so each app
 * can subclass it to carry its own per-server objects (Android/Linux add the
 * `WorkspaceViewModel` the shared screen hosts).
 */
open class CoordinatorServerSlot(
    final override val config: ConnectionConfig,
    val coordinator: SessionCoordinator,
) : ServerSlot {
    override val sessions: StateFlow<List<SessionInfo>> get() = coordinator.activeSessions
    override val activeSessionId: StateFlow<UUID?> get() = coordinator.activeSessionId
    override val isRecovering: StateFlow<Boolean> get() = coordinator.isRecovering
    override val recoveryFailed: StateFlow<Boolean> get() = coordinator.recoveryFailed
    override val isAuthRejected: StateFlow<Boolean> get() = coordinator.isAuthRejected
    override val isPerformingHandshake: StateFlow<Boolean> get() = coordinator.isPerformingHandshake
    override val connected: StateFlow<Boolean> get() = coordinator.connected
    override val serverIdentity: StateFlow<ServerIdentity?> get() = coordinator.serverIdentity
    override val sessionsAwaitingInput: StateFlow<Set<UUID>> get() = coordinator.sessionsAwaitingInput

    override val changes: Flow<Unit> = merge(
        coordinator.activeSessions.drop(1).map { },
        coordinator.activeSessionId.drop(1).map { },
        coordinator.isRecovering.drop(1).map { },
        coordinator.recoveryFailed.drop(1).map { },
        coordinator.isAuthRejected.drop(1).map { },
        coordinator.isPerformingHandshake.drop(1).map { },
        coordinator.connected.drop(1).map { },
        coordinator.serverIdentity.drop(1).map { },
        coordinator.sessionsAwaitingInput.drop(1).map { },
        coordinator.agentStates.drop(1).map { },
    )

    override fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup> = coordinator.activityCoordinator.rollups(sessions)
    override suspend fun start() = coordinator.connect().let { }  // throws on bad token → caught by the hub
    override suspend fun switchToSession(id: UUID) = coordinator.switchToSession(id)
    override suspend fun createNewSession() = coordinator.createNewSession()
    override suspend fun detachForHub(budgetMs: Long) = coordinator.detachForHub(budgetMs)
    override suspend fun attachRemoteSession(id: UUID, serverName: String?) = coordinator.attachRemoteSession(id, serverName)
    override fun handleForegroundTransition() = coordinator.handleForegroundTransition()
    override fun triggerUserRecovery() = coordinator.triggerUserRecovery()
    override suspend fun syncPush(settings: PushSettings) = coordinator.syncPushRegistration(
        deviceToken = settings.deviceToken, permissionGranted = settings.permissionGranted, deviceId = settings.deviceId,
        pushEnabled = settings.pushEnabled, notifyOnFinished = settings.notifyOnFinished,
    )
    override suspend fun tearDown() = coordinator.tearDown()
}
```

`coordinator.connect()` throws when the handshake never authenticated; the hub wraps `slot.start()` in `runCatching` (Task 4) — the coordinator's `isAuthRejected`/error flows already describe the failure.

`ServerSection.kt`:

```kotlin
package relay.session.hub

import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import java.util.UUID

/** Where one server stands, for its section header (spec §7.2, §8.1). */
sealed interface ServerSectionStatus {
    data object Connecting : ServerSectionStatus
    data object Live : ServerSectionStatus
    data object Reconnecting : ServerSectionStatus
    data object Offline : ServerSectionStatus
    data class AuthFailed(val message: String) : ServerSectionStatus
    data object Disabled : ServerSectionStatus

    val isLive: Boolean get() = this == Live

    companion object {
        /** Order matters: a rejected token beats everything, recovery beats the raw socket, a connected socket mid-handshake is "connecting". */
        fun derive(enabled: Boolean, connected: Boolean, isRecovering: Boolean,
                   isPerformingHandshake: Boolean, authRejected: Boolean): ServerSectionStatus = when {
            !enabled -> Disabled
            authRejected -> AuthFailed("Token rejected by the relay")
            isRecovering -> Reconnecting
            connected && isPerformingHandshake -> Connecting
            connected -> Live
            isPerformingHandshake -> Connecting
            else -> Offline
        }
    }
}

/** One server's slice of the sidebar. */
data class ServerSection(
    val config: ConnectionConfig,
    val status: ServerSectionStatus,
    /** Live list while live; the last live list otherwise (D4). */
    val sessions: List<SessionInfo>,
    val isCached: Boolean,
    val rollups: List<WorkspaceRollup>,
    val awaitingInput: Int,
    val isCollapsed: Boolean,
    /** Another bookmark learned the same instance id (spec §10, §12). */
    val isDuplicateInstance: Boolean = false,
) {
    val id: UUID get() = config.id
    val title: String get() = config.title
}

/** Cross-server counts (spec §7.6). Cached sections contribute nothing. */
data class HubAggregate(
    val liveServers: Int = 0,
    val totalServers: Int = 0,
    val enabledServers: Int = 0,
    val sessionsAwaitingInput: Int = 0,
)
```

`HubStateStore.kt`:

```kotlin
package relay.session.hub

import relay.protocol.SessionRef
import java.util.UUID

/** Key/value seam so the hub's state persists through each platform's own store (Android SharedPreferences, Linux PreferenceStore). */
interface HubPreferences {
    fun get(key: String): String?
    fun put(key: String, value: String?)
}

/** The hub's own persisted state (spec §9): the active ref, collapsed sections, the one-time migration flag. */
class HubStateStore(private val prefs: HubPreferences, keyPrefix: String) {
    private val activeKey = "$keyPrefix.hub.activeRef"
    private val collapsedKey = "$keyPrefix.hub.collapsedServers"
    private val migratedKey = "$keyPrefix.hub.migrated"

    fun loadActiveRef(): SessionRef? {
        val parts = prefs.get(activeKey)?.split('/') ?: return null
        if (parts.size != 2) return null
        return runCatching { SessionRef(UUID.fromString(parts[0]), UUID.fromString(parts[1])) }.getOrNull()
    }
    fun saveActiveRef(ref: SessionRef?) = prefs.put(activeKey, ref?.let { "${it.serverId}/${it.sessionId}" })

    fun loadCollapsedServers(): Set<UUID> =
        prefs.get(collapsedKey).orEmpty().split(',').mapNotNull { runCatching { UUID.fromString(it) }.getOrNull() }.toSet()
    fun saveCollapsedServers(ids: Set<UUID>) = prefs.put(collapsedKey, ids.joinToString(",").ifEmpty { null })

    val isMigrated: Boolean get() = prefs.get(migratedKey) == "true"
    fun markMigrated() = prefs.put(migratedKey, "true")
}
```

`HubMigration.kt`:

```kotlin
package relay.session.hub

import java.util.UUID

/**
 * One-time move from the single-server build (multi-server spec §9). Only the
 * bookmark the old `lastConnectedServerId` names stays enabled (or the only
 * bookmark, when there is one), so the upgrade looks exactly like the previous
 * build (G8); the legacy session-name/agent maps move under it, or are dropped
 * when it no longer exists. Marks the flag BEFORE the legacy maps are deleted so
 * a crash in between cannot re-run it over the user's later choices.
 */
object HubMigration {
    suspend fun run(
        bookmarks: BookmarkStore,
        lastServerId: String?,
        state: HubStateStore,
        moveLegacyOwnership: (UUID?) -> Unit,
    ): Boolean {
        if (state.isMigrated) return false
        val all = bookmarks.loadAll()
        val last = lastServerId?.takeIf { it.isNotBlank() }?.let { runCatching { UUID.fromString(it) }.getOrNull() }
        val keep: UUID? = when {
            last != null && all.any { it.id == last } -> last
            all.size == 1 -> all[0].id
            else -> null
        }
        bookmarks.saveAll(all.map { it.copy(enabled = it.id == keep) })
        state.markMigrated()
        moveLegacyOwnership(if (last != null && keep == last) keep else null)
        return true
    }
}
```

(The single-bookmark-with-stale-id case passes `null` to `moveLegacyOwnership` — spec §9 step 2 drops the legacy maps when `lastConnectedServerId` names no bookmark; this fixes the Swift deferred minor M5 on the Kotlin side.)

- [ ] **Step 4: Run** `./gradlew :core-session:test` (Android) and `:shared-session:test` (Linux) → green.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/core-session
git commit -m "feat(kotlin): hub model — ServerSlot, sections and status, hub state store, one-time migration

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `ServerHub` — lifecycle, publish, enable/cap, push, rebuild (core-session)

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/hub/ServerHub.kt`
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/hub/ServerHubTest.kt`

**Interfaces:**
- Consumes: Task 3 everything.
- Produces:

```kotlin
class ServerHub<S : ServerSlot>(
    scope: CoroutineScope, bookmarks: BookmarkStore, tokens: TokenSource, state: HubStateStore,
    factory: (ConnectionConfig, String) -> S,
    migration: (suspend () -> Unit)? = null,
    maxEnabled: Int = 8, staggerMs: Long = 150, detachBudgetMs: Long = 3_000,
    sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    val sections: StateFlow<List<ServerSection>>; val activeRef: StateFlow<SessionRef?>; val aggregate: StateFlow<HubAggregate>
    val notice: StateFlow<String?>; fun setNotice(text: String?)
    val isShowingServerList: StateFlow<Boolean>; fun setShowingServerList(show: Boolean)
    val activeSlot: StateFlow<S?>; val focusSlot: StateFlow<S?>; val focusServerId: StateFlow<UUID?>
    fun slot(serverId: UUID): S?
    suspend fun start(); fun stop()
    suspend fun reloadBookmarks(); suspend fun setEnabled(serverId: UUID, enabled: Boolean): Boolean
    fun rebuildSlot(serverId: UUID)
    fun handleForegroundTransition(); fun triggerUserRecovery(serverId: UUID? = null)
    suspend fun syncPushRegistration(settings: PushSettings)
    fun setCollapsed(serverId: UUID, collapsed: Boolean)
    // Task 5: select, createSession, selectNext/Previous, orderedRefs, removeServer, handleDeepLink
}
```

- [ ] **Step 1: Write the failing tests** — port `Tests/CodeRelayClientTests/Hub/ServerHubTests.swift` and the lifecycle half of `ServerHubFixPassTests.swift` to `runTest`. Harness:

```kotlin
package relay.session.hub

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID

fun cfg(name: String, enabled: Boolean = true) = ConnectionConfig(name = name, host = "$name.local", enabled = enabled)
fun session(id: UUID = UUID.randomUUID()) = SessionInfo(/* copy the minimal constructor SessionCoordinatorTest uses */ id = id, state = SessionState.ACTIVE_DETACHED, tokenId = "t", createdAt = 0.0, cols = 80, rows = 24)

class HubHarness(scope: CoroutineScope, configs: List<ConnectionConfig>, tokensFor: Set<UUID>? = null,
                 maxEnabled: Int = 8, val sleeps: MutableList<Long> = mutableListOf()) {
    val bookmarks = InMemoryBookmarks(configs)
    val tokens = FakeTokens(configs.filter { tokensFor == null || it.id in tokensFor }.associate { it.id to "tok-${it.name}" }.toMutableMap())
    val built = mutableListOf<FakeServerSlot>()
    val state = HubStateStore(MapPreferences(), "test")
    val hub = ServerHub(scope, bookmarks, tokens, state, factory = { c, _ -> FakeServerSlot(c).also { built += it } },
        maxEnabled = maxEnabled, sleepMs = { sleeps += it })
    fun slot(id: UUID) = hub.slot(id)
}
```

(Copy `SessionInfo`'s real constructor from `core-protocol/src/main/kotlin/relay/protocol/SessionInfo.kt`.)

Tests (each `= runTest { … }`, ending with `advanceUntilIdle()` before assertions that depend on launched work):

```kotlin
class ServerHubTest {
    @Test fun startBuildsOneSlotPerEnabledBookmarkWithAStagger() = runTest {
        val h = HubHarness(this, listOf(cfg("a"), cfg("b", enabled = false), cfg("c")))
        h.hub.start(); advanceUntilIdle()
        assertEquals(listOf("a", "c"), h.built.map { it.config.name })
        assertEquals(listOf(0L, 150L), h.sleeps)
        assertEquals(3, h.hub.sections.value.size)
        assertEquals(ServerSectionStatus.Disabled, h.hub.sections.value[1].status)
    }

    @Test fun aSlowServerStartDoesNotDelayTheOthers() = runTest {
        val slow = cfg("slow"); val fast = cfg("fast")
        val h = HubHarness(this, listOf(slow, fast))
        val hubStart = launch { h.hub.start() }
        advanceUntilIdle()
        // slow parks in start(); fast was still built and started.
        h.built.first { it.config.name == "slow" }.let { assertEquals(1, it.startCount) }
        assertEquals(1, h.built.first { it.config.name == "fast" }.startCount)
        h.built.first { it.config.name == "slow" }.startGate.complete(Unit)
        hubStart.join()
    }
    // FakeServerSlot.startHangs must be set before start(): construct the harness with a factory hook,
    // or set `slowHangs` via `HubHarness(..., hangs = setOf(slow.id))` that sets startHangs in the factory.

    @Test fun liveSlotPublishesItsSessionsAndOfflineKeepsThemCached() = runTest {
        val a = cfg("a"); val h = HubHarness(this, listOf(a)); h.hub.start(); advanceUntilIdle()
        val s = session(); h.slot(a.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(ServerSectionStatus.Live, h.hub.sections.value[0].status)
        h.slot(a.id)!!.goOffline(); advanceUntilIdle()
        val sec = h.hub.sections.value[0]
        assertEquals(ServerSectionStatus.Offline, sec.status); assertTrue(sec.isCached); assertEquals(listOf(s.id), sec.sessions.map { it.id })
        assertEquals(0, h.hub.aggregate.value.liveServers)
    }

    @Test fun missingTokenBecomesAuthFailedSection() = runTest {
        val a = cfg("a"); val h = HubHarness(this, listOf(a), tokensFor = emptySet()); h.hub.start(); advanceUntilIdle()
        assertNull(h.slot(a.id))
        assertEquals(ServerSectionStatus.AuthFailed("No token stored for this server"), h.hub.sections.value[0].status)
    }

    @Test fun tokenLookupThatThrowsBecomesAuthFailed() = runTest {   // Review Focus 5
        val a = cfg("a"); val h = HubHarness(this, listOf(a)); h.tokens.throwsFor = setOf(a.id)
        h.hub.start(); advanceUntilIdle()
        assertEquals(ServerSectionStatus.AuthFailed("No token stored for this server"), h.hub.sections.value[0].status)
    }

    @Test fun capRefusesTheNinthServerWithANotice() = runTest {
        val configs = (1..9).map { cfg("s$it", enabled = it <= 8) }
        val h = HubHarness(this, configs); h.hub.start(); advanceUntilIdle()
        assertFalse(h.hub.setEnabled(configs[8].id, true))
        assertEquals("Up to 8 servers can be enabled at once. Disable one first.", h.hub.notice.value)
    }

    @Test fun reloadAtTheCapDisablesTheNewBookmarkWithANotice() = runTest {
        val h = HubHarness(this, listOf(cfg("a"), cfg("b")), maxEnabled = 2); h.hub.start(); advanceUntilIdle()
        val c = cfg("c"); h.bookmarks.add(c); h.hub.reloadBookmarks(); advanceUntilIdle()
        assertFalse(h.bookmarks.loadAll().first { it.id == c.id }.enabled)
        assertNull(h.slot(c.id)); assertNotNull(h.hub.notice.value)
    }

    @Test fun disablingUnregistersPushBeforeTearingDownAndKeepsTheCachedRows() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(this, listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val push = PushSettings("t", true, "d", pushEnabled = true, notifyOnFinished = false)
        h.hub.syncPushRegistration(push); advanceUntilIdle()
        val slotB = h.slot(b.id)!!; slotB.goLive(listOf(session())); advanceUntilIdle()
        val log = mutableListOf<String>(); slotB.log = { log += it }
        h.hub.setEnabled(b.id, false); advanceUntilIdle()
        assertNull(h.slot(b.id)); assertEquals(listOf("push:false", "teardown:b"), log)
        val sec = h.hub.sections.value.first { it.id == b.id }
        assertEquals(ServerSectionStatus.Disabled, sec.status); assertEquals(1, sec.sessions.size, "spec §7: cached list kept")
    }

    @Test fun slotsBuiltAfterASyncReceiveTheCurrentPushSettings() = runTest {
        val b = cfg("b", enabled = false); val h = HubHarness(this, listOf(cfg("a"), b)); h.hub.start(); advanceUntilIdle()
        val push = PushSettings("t", true, "d", pushEnabled = true, notifyOnFinished = false)
        h.hub.syncPushRegistration(push); h.hub.setEnabled(b.id, true); advanceUntilIdle()
        assertEquals(listOf(push), h.slot(b.id)!!.pushSyncs)
    }

    @Test fun stopDuringStartBuildsNothingAndDisableBeforeBuildBuildsNothing() = runTest {
        val h = HubHarness(this, listOf(cfg("a"), cfg("b")))
        val started = launch { h.hub.start() }; h.hub.stop(); advanceUntilIdle(); started.join()
        assertTrue(h.built.all { it.tornDown }, "a coordinator built after stop() is torn down, never left connected")
    }

    @Test fun rebuildSlotReplacesTheCoordinator() = runTest {
        val a = cfg("a"); val h = HubHarness(this, listOf(a)); h.hub.start(); advanceUntilIdle()
        val old = h.slot(a.id)!!; h.hub.rebuildSlot(a.id); advanceUntilIdle()
        assertTrue(old.tornDown); assertNotSame(old, h.slot(a.id)); assertEquals(1, h.slot(a.id)!!.startCount)
    }

    @Test fun identityIsLearnedOntoTheBookmarkAndDuplicatesAreFlagged() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(this, listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val iid = UUID.randomUUID()
        listOf(a, b).forEach { c -> h.slot(c.id)!!.serverIdentity.value = relay.protocol.ServerIdentity(iid, "studio"); h.slot(c.id)!!.goLive(emptyList()) }
        advanceUntilIdle()
        assertTrue(h.bookmarks.loadAll().all { it.instanceId == iid && it.displayName == "studio" })
        assertTrue(h.hub.sections.value.all { it.isDuplicateInstance })
    }

    @Test fun foregroundFansOutToEveryEnabledSlotWithAStagger() = runTest {
        val h = HubHarness(this, listOf(cfg("a"), cfg("b"))); h.hub.start(); advanceUntilIdle(); h.sleeps.clear()
        h.hub.handleForegroundTransition(); advanceUntilIdle()
        assertTrue(h.built.all { it.foregroundCount == 1 }); assertEquals(listOf(0L, 150L), h.sleeps)
    }

    @Test fun focusSlotFallsBackToTheOnlyEnabledThenFirstLive() = runTest {
        val a = cfg("a"); val h = HubHarness(this, listOf(a)); h.hub.start(); advanceUntilIdle()
        assertSame(h.slot(a.id), h.hub.focusSlot.value, "one enabled server: its coordinator drives the surfaces (G8)")
    }

    @Test fun startIsIdempotent() = runTest {
        val h = HubHarness(this, listOf(cfg("a"))); h.hub.start(); h.hub.start(); advanceUntilIdle()
        assertEquals(1, h.built.size)
    }
}
```

(Fix the `aSlowServerStartDoesNotDelayTheOthers` set-up by giving `HubHarness` a `hangs: Set<UUID> = emptySet()` parameter that the factory copies into `FakeServerSlot.startHangs` — write it that way, the comment above is the reminder.)

- [ ] **Step 2: Run to verify failure** → unresolved `ServerHub`.

- [ ] **Step 3: Implement `ServerHub.kt`** — a direct port of `Sources/CodeRelayClient/Hub/ServerHub.swift` at main, with Kotlin mechanics:

```kotlin
package relay.session.hub

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.SessionRef
import java.util.UUID

/**
 * One workspace across several relays (multi-server spec §7). Owns one slot per
 * ENABLED bookmark, merges their state into [sections], and holds the single
 * global active session. Never talks to the network, runs recovery, or holds
 * terminal views — those stay in the coordinators, unchanged. Not thread-safe:
 * confined to [scope]'s single dispatcher like the coordinators it owns.
 *
 * Port of `Sources/CodeRelayClient/Hub/ServerHub.swift` including both review
 * fix passes; keep the two in step.
 */
class ServerHub<S : ServerSlot>(
    private val scope: CoroutineScope,
    internal val bookmarkStore: BookmarkStore,
    internal val tokens: TokenSource,
    internal val state: HubStateStore,
    private val factory: (ConnectionConfig, String) -> S,
    private val migration: (suspend () -> Unit)? = null,
    private val maxEnabled: Int = 8,
    private val staggerMs: Long = 150,
    internal val detachBudgetMs: Long = 3_000,
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    private val _sections = MutableStateFlow<List<ServerSection>>(emptyList())
    val sections: StateFlow<List<ServerSection>> = _sections.asStateFlow()
    internal val _activeRef = MutableStateFlow<SessionRef?>(null)
    val activeRef: StateFlow<SessionRef?> = _activeRef.asStateFlow()
    private val _aggregate = MutableStateFlow(HubAggregate())
    val aggregate: StateFlow<HubAggregate> = _aggregate.asStateFlow()
    internal val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()
    fun setNotice(text: String?) { _notice.value = text }
    private val _isShowingServerList = MutableStateFlow(false)
    val isShowingServerList: StateFlow<Boolean> = _isShowingServerList.asStateFlow()
    fun setShowingServerList(show: Boolean) { _isShowingServerList.value = show }
    private val _activeSlot = MutableStateFlow<S?>(null)
    val activeSlot: StateFlow<S?> = _activeSlot.asStateFlow()
    private val _focusSlot = MutableStateFlow<S?>(null)
    /** The slot single-server surfaces follow when nothing is selected: active, else the only enabled, else the first live (G8). */
    val focusSlot: StateFlow<S?> = _focusSlot.asStateFlow()
    private val _focusServerId = MutableStateFlow<UUID?>(null)
    val focusServerId: StateFlow<UUID?> = _focusServerId.asStateFlow()

    internal var bookmarks: List<ConnectionConfig> = emptyList()
    internal val slots = mutableMapOf<UUID, S>()
    private val slotJobs = mutableMapOf<UUID, Job>()
    internal val cachedSessions = mutableMapOf<UUID, List<SessionInfo>>()
    internal val missingToken = mutableSetOf<UUID>()
    private var collapsedServers: Set<UUID> = state.loadCollapsedServers()
    internal var started = false
    internal val startCompleted = CompletableDeferred<Unit>()
    /** The one selection waiting for its server (== activeRef while set). */
    internal var pendingRef: SessionRef? = null
    internal var selectionGeneration = 0L
    internal var selectionsInFlight = 0
    private var pushSettings: PushSettings? = null

    val enabledCount: Int get() = bookmarks.count { it.enabled }
    fun slot(serverId: UUID): S? = slots[serverId]

    suspend fun start() {
        if (started) return
        started = true
        try {
            migration?.invoke()
            bookmarks = bookmarkStore.loadAll()
            state.loadActiveRef()?.let { saved ->
                if (bookmarks.any { it.id == saved.serverId && it.enabled }) { _activeRef.value = saved; pendingRef = saved }
                else state.saveActiveRef(null)
            }
            publish()
            coroutineScope {
                bookmarks.filter { it.enabled }.forEachIndexed { index, config ->
                    launch { sleepMs(staggerMs * index); if (started) buildSlot(config) }
                }
            }
            publish()
        } finally {
            startCompleted.complete(Unit)
        }
    }

    fun stop() {
        slots.values.forEach { s -> scope.launch { s.tearDown() } }
        slots.clear(); slotJobs.values.forEach { it.cancel() }; slotJobs.clear()
        started = false; pendingRef = null
        publish()
    }

    private fun isWanted(id: UUID) = started && bookmarks.firstOrNull { it.id == id }?.enabled == true

    private suspend fun buildSlot(config: ConnectionConfig) {
        if (slots.containsKey(config.id) || !isWanted(config.id)) return
        val token = runCatching { tokens.loadToken(config.id) }.getOrNull()
        if (token.isNullOrEmpty()) { missingToken += config.id; publish(); return }
        missingToken -= config.id
        val slot = factory(config, token)
        slots[config.id] = slot
        slotJobs[config.id] = scope.launch { slot.changes.collect { slotDidChange(config.id) } }
        runCatching { slot.start() }
        if (!isWanted(config.id) || slots[config.id] !== slot) {
            if (slots[config.id] === slot) { slots.remove(config.id); slotJobs.remove(config.id)?.cancel() }
            slot.tearDown(); return
        }
        pushSettings?.let { slot.syncPush(it) }
        slotDidChange(config.id)
    }

    /** Removes the slot from the hub at once, then detaches / unregisters within the budget and tears it down. */
    internal fun detachFromHub(id: UUID): S? {
        val slot = slots.remove(id) ?: return null
        slotJobs.remove(id)?.cancel()
        if (_activeRef.value?.serverId == id || pendingRef?.serverId == id) {
            _activeRef.value = null; pendingRef = null; state.saveActiveRef(null)
        }
        return slot
    }

    internal suspend fun retire(slot: S, wasActive: Boolean, unregisterPush: Boolean) {
        val work = scope.async {
            if (wasActive) slot.detachForHub(detachBudgetMs)
            if (unregisterPush) pushSettings?.let { slot.syncPush(it.copy(pushEnabled = false)) }
                ?: slot.syncPush(PushSettings(null, false, "", pushEnabled = false, notifyOnFinished = false))
        }
        withTimeoutOrNull(detachBudgetMs) { work.await() }
        slot.tearDown()
    }

    private fun tearDownSlot(id: UUID, unregisterPush: Boolean = false) {
        val slot = detachFromHub(id) ?: return
        val wasActive = slot.activeSessionId.value != null
        scope.launch { retire(slot, wasActive, unregisterPush) }
    }

    suspend fun reloadBookmarks() {
        var fresh = bookmarkStore.loadAll()
        var enabledNow = fresh.count { it.enabled }
        if (enabledNow > maxEnabled) {
            fresh = fresh.reversed().map { c ->
                if (c.enabled && !slots.containsKey(c.id) && enabledNow > maxEnabled) {
                    enabledNow -= 1
                    _notice.value = "Up to $maxEnabled servers can be enabled at once. ${c.name} was added disabled."
                    c.copy(enabled = false)
                } else c
            }.reversed()
            bookmarkStore.saveAll(fresh)
        }
        val freshById = fresh.associateBy { it.id }
        for (id in slots.keys.toList()) {
            val now = freshById[id]
            if (now == null || !now.enabled) { tearDownSlot(id); continue }
            val old = bookmarks.firstOrNull { it.id == id }
            if (old != null && (old.host != now.host || old.port != now.port || old.useTLS != now.useTLS)) tearDownSlot(id)
        }
        bookmarks = fresh
        publish()
        fresh.filter { it.enabled && !slots.containsKey(it.id) }.forEach { c -> scope.launch { buildSlot(c) } }
    }

    suspend fun setEnabled(serverId: UUID, enabled: Boolean): Boolean {
        val config = bookmarks.firstOrNull { it.id == serverId } ?: return false
        if (enabled && !config.enabled && enabledCount >= maxEnabled) {
            _notice.value = "Up to $maxEnabled servers can be enabled at once. Disable one first."
            return false
        }
        val updated = config.copy(enabled = enabled)
        bookmarkStore.add(updated)
        bookmarks = bookmarkStore.loadAll()
        if (enabled) scope.launch { buildSlot(updated) } else tearDownSlot(serverId, unregisterPush = true)
        publish()
        return true
    }

    fun rebuildSlot(serverId: UUID) {
        tearDownSlot(serverId)
        val config = bookmarks.firstOrNull { it.id == serverId && it.enabled } ?: run { publish(); return }
        scope.launch { buildSlot(config) }
    }

    private suspend fun slotDidChange(id: UUID) {
        val slot = slots[id] ?: return
        val identity = slot.serverIdentity.value
        val config = bookmarks.firstOrNull { it.id == id }
        if (identity != null && config != null) {
            val name = identity.name.ifEmpty { null }
            if (config.instanceId != identity.id || config.displayName != name) {
                bookmarkStore.add(config.copy(instanceId = identity.id, displayName = name))
                bookmarks = bookmarkStore.loadAll()
            }
        }
        reconcileSelection(slot, id)
        publish()
        applyPendingSelection(id)
    }

    /** The coordinator owns the attachment; the hub mirrors it (⌘W, terminate, stolen, failed resume, Attach sheet, QR). */
    private fun reconcileSelection(slot: S, id: UUID) {
        if (selectionsInFlight > 0 || pendingRef != null) return
        val attached = slot.activeSessionId.value
        val active = _activeRef.value
        if (active != null && active.serverId == id) {
            if (attached == active.sessionId) return
            _activeRef.value = attached?.let { SessionRef(id, it) }; state.saveActiveRef(_activeRef.value)
        } else if (active == null && attached != null) {
            _activeRef.value = SessionRef(id, attached); state.saveActiveRef(_activeRef.value)
        }
    }

    internal fun publish() {
        var live = 0; var awaiting = 0
        val built = bookmarks.map { config ->
            val slot = slots[config.id]
            var status = ServerSectionStatus.derive(
                enabled = config.enabled,
                connected = slot?.connected?.value ?: false,
                isRecovering = slot?.isRecovering?.value ?: false,
                isPerformingHandshake = slot?.isPerformingHandshake?.value ?: false,
                authRejected = slot?.isAuthRejected?.value ?: false,
            )
            if (config.enabled && config.id in missingToken) status = ServerSectionStatus.AuthFailed("No token stored for this server")
            val liveList = slot?.sessions?.value.orEmpty()
            if (status.isLive) cachedSessions[config.id] = liveList
            val shown = if (status.isLive) liveList else cachedSessions[config.id].orEmpty()
            val waiting = if (status.isLive) slot?.sessionsAwaitingInput?.value?.size ?: 0 else 0
            if (status.isLive) { live += 1; awaiting += waiting }
            ServerSection(config, status, shown, !status.isLive, slot?.rollups(shown).orEmpty(), waiting, config.id in collapsedServers)
        }
        val counts = built.mapNotNull { it.config.instanceId }.groupingBy { it }.eachCount()
        val withDupes = built.map { s -> s.config.instanceId?.let { s.copy(isDuplicateInstance = (counts[it] ?: 0) > 1) } ?: s }
        if (_sections.value != withDupes) _sections.value = withDupes
        val agg = HubAggregate(live, bookmarks.size, enabledCount, awaiting)
        if (_aggregate.value != agg) _aggregate.value = agg
        _activeSlot.value = _activeRef.value?.let { slots[it.serverId] }
        val focusId = _activeRef.value?.serverId?.takeIf { slots.containsKey(it) }
            ?: bookmarks.filter { it.enabled }.singleOrNull()?.id?.takeIf { slots.containsKey(it) }
            ?: withDupes.firstOrNull { it.status.isLive && slots.containsKey(it.id) }?.id
        _focusServerId.value = focusId
        _focusSlot.value = focusId?.let { slots[it] }
    }

    fun handleForegroundTransition() {
        bookmarks.filter { it.enabled }.mapNotNull { slots[it.id] }.forEachIndexed { index, slot ->
            scope.launch { sleepMs(staggerMs * index); slot.handleForegroundTransition() }
        }
    }

    fun triggerUserRecovery(serverId: UUID? = null) {
        if (serverId != null) slots[serverId]?.triggerUserRecovery() else slots.values.forEach { it.triggerUserRecovery() }
    }

    suspend fun syncPushRegistration(settings: PushSettings) {
        pushSettings = settings
        slots.values.toList().forEach { it.syncPush(settings) }
    }

    fun setCollapsed(serverId: UUID, collapsed: Boolean) {
        collapsedServers = if (collapsed) collapsedServers + serverId else collapsedServers - serverId
        state.saveCollapsedServers(collapsedServers)
        publish()
    }
}
```

(Notes for the implementer: `start()` uses `coroutineScope { launch … }` so the stagger children run concurrently and `start()` returns after all builds — one dead relay never delays the others, the Swift fix-pass rule. `stop()` sets `started = false` so a build still parked in `sleepMs` or `slot.start()` tears its slot down via `isWanted`. `slot.changes` collection triggers `slotDidChange` on the hub scope; `slotDidChange` is `suspend` because learning the identity writes the bookmark store.)

- [ ] **Step 4: Run** `./gradlew :core-session:test` and Linux `:shared-session:test` → green.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/core-session
git commit -m "feat(kotlin): ServerHub — concurrent staggered start, sections and aggregate, enable/cap, push sync and unregister, rebuild

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `ServerHub` selection and deep-link routing (core-session)

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/hub/ServerHubSelection.kt` (extension functions + `DeepLinkOutcome`)
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/hub/ServerHubSelectionTest.kt`, `.../hub/ServerHubRoutingTest.kt`

**Interfaces:**
- Consumes: Task 4 internals (`slots`, `_activeRef`, `pendingRef`, `selectionGeneration`, `selectionsInFlight`, `state`, `publish`, `detachFromHub`, `retire`, `missingToken`, `started`, `startCompleted`, `cachedSessions`, `detachBudgetMs`).
- Produces: `val ServerHub<*>.orderedRefs: List<SessionRef>`; `suspend fun ServerHub<*>.select(ref: SessionRef)`; `suspend fun ServerHub<*>.createSession(serverId: UUID)`; `suspend fun ServerHub<*>.selectNext()` / `selectPrevious()`; `suspend fun ServerHub<*>.removeServer(serverId: UUID)`; `internal fun ServerHub<*>.applyPendingSelection(serverId: UUID)` (called from `slotDidChange` — move the call); `sealed interface DeepLinkOutcome { Selected(ref); EnabledAndSelected(ref); AttachingRemote(serverId); NotFound(serverName: String?) }`; `suspend fun ServerHub<*>.handleDeepLink(link: SessionDeepLink): DeepLinkOutcome`.

- [ ] **Step 1: Write the failing tests** — port `ServerHubSelectionTests.swift`, `ServerHubRoutingTests.swift` and the selection half of `ServerHubFixPassTests.swift` one-for-one (same names in camelCase, same assertions), using `HubHarness`. The non-negotiable cases (write these exactly; port the rest by name):

```kotlin
class ServerHubSelectionTest {
    private suspend fun TestScope.liveHub(vararg names: String): Pair<HubHarness, List<ConnectionConfig>> {
        val configs = names.map { cfg(it) }; val h = HubHarness(this, configs); h.hub.start(); advanceUntilIdle()
        configs.forEach { h.slot(it.id)!!.goLive(listOf(session(), session())) }; advanceUntilIdle()
        return h to configs
    }

    @Test fun selectAcrossServersDetachesPreviousBeforeSwitching() = runTest {
        val (h, c) = liveHub("a", "b"); val log = mutableListOf<String>()
        c.forEach { h.slot(it.id)!!.log = { e -> log += e } }
        val sa = h.slot(c[0].id)!!.sessions.value[0].id; val sb = h.slot(c[1].id)!!.sessions.value[0].id
        h.hub.select(SessionRef(c[0].id, sa)); advanceUntilIdle(); log.clear()
        h.hub.select(SessionRef(c[1].id, sb)); advanceUntilIdle()
        assertEquals(listOf("detach:a", "switch:b"), log)
        assertNull(h.slot(c[0].id)!!.activeSessionId.value)
        assertEquals(h.hub.activeRef.value, h.state.loadActiveRef())
    }

    @Test fun overlappingSelectsLeaveExactlyTheLastOneAttached() = runTest {
        val (h, c) = liveHub("a", "b"); val a = h.slot(c[0].id)!!; val b = h.slot(c[1].id)!!
        h.hub.select(SessionRef(c[0].id, a.sessions.value[0].id)); advanceUntilIdle()
        a.detachHangs = true
        val first = launch { h.hub.select(SessionRef(c[1].id, b.sessions.value[0].id)) }; advanceUntilIdle()
        a.detachHangs = false
        h.hub.select(SessionRef(c[1].id, b.sessions.value[1].id)); advanceUntilIdle()
        a.detachGate.complete(Unit); first.join(); advanceUntilIdle()
        assertEquals(listOf(b.sessions.value[1].id), b.switchedTo, "the stale select must not re-attach after the newer one won")
    }

    @Test fun abandonedPendingSelectionIsNotAppliedWhenTheServerReturns() = runTest {
        val (h, c) = liveHub("a", "b"); val a = h.slot(c[0].id)!!; val b = h.slot(c[1].id)!!
        a.goOffline(); advanceUntilIdle()
        h.hub.select(SessionRef(c[0].id, a.sessions.value[0].id))
        h.hub.select(SessionRef(c[1].id, b.sessions.value[0].id)); advanceUntilIdle()
        a.goLive(a.sessions.value); advanceUntilIdle()
        assertTrue(a.switchedTo.isEmpty()); assertEquals(c[1].id, h.hub.activeRef.value?.serverId)
    }

    @Test fun activeRefFollowsACoordinatorThatDetachedOnItsOwn() = runTest {
        val (h, c) = liveHub("a"); val a = h.slot(c[0].id)!!; val s = a.sessions.value[0].id
        h.hub.select(SessionRef(c[0].id, s)); advanceUntilIdle()
        a.activeSessionId.value = null; a.changed(); advanceUntilIdle()
        assertNull(h.hub.activeRef.value)
        h.hub.select(SessionRef(c[0].id, s)); advanceUntilIdle()
        assertEquals(listOf(s, s), a.switchedTo, "re-selecting the detached row attaches again")
    }

    @Test fun selectingARowOfATokenlessServerIsRefusedWithoutDetaching() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(this, listOf(a, b), tokensFor = setOf(a.id))
        h.hub.start(); advanceUntilIdle(); h.slot(a.id)!!.goLive(listOf(session())); advanceUntilIdle()
        h.hub.select(SessionRef(a.id, h.slot(a.id)!!.sessions.value[0].id)); advanceUntilIdle()
        h.hub.select(SessionRef(b.id, UUID.randomUUID())); advanceUntilIdle()
        assertEquals(a.id, h.hub.activeRef.value?.serverId); assertEquals(0, h.slot(a.id)!!.detachCount)
        assertEquals("b has no token. Re-pair it in Servers.", h.hub.notice.value)
    }

    @Test fun removeActiveServerDetachesAndClearsActiveRef() = runTest {
        val (h, c) = liveHub("a"); val a = h.slot(c[0].id)!!
        h.hub.select(SessionRef(c[0].id, a.sessions.value[0].id)); advanceUntilIdle()
        h.hub.removeServer(c[0].id); advanceUntilIdle()
        assertNull(h.hub.activeRef.value); assertEquals(1, a.detachCount); assertTrue(a.tornDown)
        assertTrue(h.bookmarks.loadAll().isEmpty()); assertNull(h.tokens.loadToken(c[0].id))
    }
}

class ServerHubRoutingTest {
    @Test fun deepLinkBeforeStartIsQueuedAndRoutesByInstanceId() = runTest {   // Review Focus 1
        val iid = UUID.randomUUID(); val a = cfg("a").copy(instanceId = iid); val b = cfg("b")
        val h = HubHarness(this, listOf(b, a))
        val target = UUID.randomUUID()
        val routed = async { h.hub.handleDeepLink(SessionDeepLink(target, iid)) }
        advanceUntilIdle(); assertFalse(routed.isCompleted, "held until start() completes")
        h.hub.start(); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(a.id, target)), routed.await())
    }

    @Test fun instanceIdOnADisabledBookmarkEnablesItAndDetachesTheCurrentServerFirst() = runTest {
        val iid = UUID.randomUUID(); val a = cfg("a"); val b = cfg("b", enabled = false).copy(instanceId = iid)
        val h = HubHarness(this, listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val slotA = h.slot(a.id)!!; slotA.goLive(listOf(session())); advanceUntilIdle()
        h.hub.select(SessionRef(a.id, slotA.sessions.value[0].id)); advanceUntilIdle()
        val target = UUID.randomUUID()
        assertEquals(DeepLinkOutcome.EnabledAndSelected(SessionRef(b.id, target)), h.hub.handleDeepLink(SessionDeepLink(target, iid)))
        assertEquals(1, slotA.detachCount); assertEquals("Enabled b to open this session", h.hub.notice.value)
    }

    @Test fun anEnabledDuplicateBookmarkWins() = runTest {
        val iid = UUID.randomUUID(); val off = cfg("off", enabled = false).copy(instanceId = iid); val on = cfg("on").copy(instanceId = iid)
        val h = HubHarness(this, listOf(off, on)); h.hub.start(); advanceUntilIdle()
        val s = session(); h.slot(on.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(on.id, s.id)), h.hub.handleDeepLink(SessionDeepLink(s.id, iid)))
        assertFalse(h.bookmarks.loadAll().first { it.id == off.id }.enabled, "never a second socket to one relay")
    }

    @Test fun uniqueSessionAcrossLiveSectionsRoutesWithoutAServerHint() = runTest { /* port */ }
    @Test fun unknownSessionWithOneServerFallsBackToRemoteAttach() = runTest { /* port */ }
    @Test fun unknownSessionWithSeveralServersIsNotFound() = runTest { /* port: notice "Session not found on any enabled server" */ }
    @Test fun deepLinkAfterStartWithOnlyTokenlessServersDoesNotHang() = runTest {
        val h = HubHarness(this, listOf(cfg("a")), tokensFor = emptySet()); h.hub.start(); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.NotFound(null), withTimeout(2_000) { h.hub.handleDeepLink(SessionDeepLink(UUID.randomUUID())) })
    }
}
```

The three `/* port */` bodies are the Swift tests of the same names in `Tests/CodeRelayClientTests/Hub/ServerHubRoutingTests.swift` — translate them line for line (they are 6–8 lines each); they are not optional.

- [ ] **Step 2: Run to verify failure** → unresolved `select`, `handleDeepLink`, `DeepLinkOutcome`, `removeServer`.

- [ ] **Step 3: Implement `ServerHubSelection.kt`** — a line-for-line Kotlin translation of `Sources/CodeRelayClient/Hub/ServerHub+Selection.swift` and `ServerHub+DeepLink.swift` (both reproduced in this repo at main; read them side by side). Mechanics: `await detachBounded(from)` → `withTimeoutOrNull(detachBudgetMs) { scope.async { from.detachForHub(detachBudgetMs) }.await() }`; `defer { selectionsInFlight -= 1 }` → `try { … } finally { selectionsInFlight -= 1 }`; `if !startCompleted { await startGate }` → `startCompleted.await()`; `Task { … }` in `applyPendingSelection` → `scope.launch { try { … } finally { selectionsInFlight -= 1 } }`; `notice = …` → `_notice.value = …`; `stateStore.saveActiveRef` → `state.saveActiveRef`; `mirror(slot, serverId)` → a private extension writing `_activeRef` from `slot.activeSessionId.value`. In `ServerHub.slotDidChange` keep the `applyPendingSelection(id)` call (now the extension). `orderedRefs` = `sections.value.filter { it.config.enabled }.flatMap { s -> s.sessions.map { SessionRef(s.id, it.id) } }`.

- [ ] **Step 4: Run** `./gradlew :core-session:test` + Linux `:shared-session:test` → green (all Task 3–5 hub tests).

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/core-session
git commit -m "feat(kotlin): hub selection — one attachment across servers under overlapping selections, single pending ref, deep-link routing by instance id

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The loading sheet — model (core-session) and Compose sheet (feature-workspace)

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionLoadingPresentation.kt` (presentation + `SessionLoadingSheetModel`); `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionLoadingSheet.kt`
- Delete: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionLoadingOverlay.kt`
- Modify: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceScreen.kt` (remove the `SessionLoadingOverlay` at ~756 and the recovery scrim at ~455; the terminal box gets the blackout; host the sheet)
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionLoadingPresentationTest.kt`, `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/SessionLoadingSheetStyleTest.kt`

**Interfaces:**
- Consumes: `SessionLoadPhase` (`label`, `detail`, `LoadingHistory(bytes)`), `RecoveryPhase` (add `val label: String` if absent — "Reconnecting to server…", "Authenticating…", "Restoring session…", matching Swift `RecoveryPhase.label`), Task 2 `lastLoadFailed`/`loadEndedInFailure`/`expectsSessionToLoad`/`recoveryFailed`.
- Produces: `data class SessionLoadingPresentation(…)` with `isActive`, `title`, `status`, `detail`, `subtitle`, `allowsCancel`, `isReady`, `fun readied()`, `fun endsInReady(after: SessionLoadingPresentation?)`; `class SessionLoadingSheetModel(scope: CoroutineScope, sleepMs: suspend (Long) -> Unit = { delay(it) })` with `val isPresented: StateFlow<Boolean>`, `val shown: StateFlow<SessionLoadingPresentation?>`, `fun update(p: SessionLoadingPresentation)`, constants `MINIMUM_VISIBLE_MS = 600`, `READY_DWELL_MS = 600`, `STALL_TIMEOUT_MS = 15_000`; `@Composable fun SessionLoadingSheetHost(model: SessionLoadingSheetModel, onCancel: () -> Unit)` and `object SessionLoadingSheetStyle { const val BYTES_SP = 24; const val STATUS_SP = 14; const val COVER_OUT_MS = 160; const val COVER_IN_MS = 220; const val MAX_WIDTH_DP = 340 }`; `Modifier.terminalLoadingCover(covered: Boolean)`.

- [ ] **Step 1: Write the failing tests** — port `Tests/CodeRelayClientTests/SessionLoadingPresentationTests.swift` at main one-for-one (`testInactiveWhenNothingLoads`, `testHandshakePhasesDoNotRaiseTheSheetWithoutASessionToShow`, `testDetailReadsZeroKBBeforeHistoryStreams`, `testLoadPhasesDriveTitleStatusAndBytes`, `testRecoveryWinsTheTitleAndOffersCancel`, `testSheetHoldsAMinimumEvenWhenLoadingIsInstant`, `testSheetStaysWhileLoadingOutlivesTheHold`, `testSheetDismissesAfterAStallAndReturnsOnProgress`, `testAFullySyncedSessionShowsZeroThenReadyThenDismisses`, `testReadyKeepsTheFinalByteCount`, `testAFailedLoadNeverSaysReady`, `testACancelledReconnectNeverSaysReady`, `testANewLoadDuringReadyTakesOver`). The scripted sleeper in Kotlin:

```kotlin
class Sleeper {
    val parked = mutableListOf<Pair<Long, CompletableDeferred<Unit>>>()
    suspend fun sleep(ms: Long) { val d = CompletableDeferred<Unit>(); parked += ms to d; d.await() }
    fun release(ms: Long) { parked.firstOrNull { it.first == ms }?.let { parked.remove(it); it.second.complete(Unit) } }
}
```

with `SessionLoadingSheetModel(backgroundScope) { sleeper.sleep(it) }` inside `runTest` and `runCurrent()` where Swift used `settle()`.

`SessionLoadingSheetStyleTest.kt`:

```kotlin
class SessionLoadingSheetStyleTest {
    @Test fun bytesAreTheLargestTextOnTheSheet() {
        assertTrue(SessionLoadingSheetStyle.BYTES_SP > SessionLoadingSheetStyle.STATUS_SP,
            "the counter is the one line that proves progress is real; it must not be a caption")
    }
    @Test fun sheetWidthMatchesTheAppleApps() = assertEquals(340, SessionLoadingSheetStyle.MAX_WIDTH_DP)

    @Test fun blackoutCurvesMatchTheAppleApps() {
        assertEquals(160, SessionLoadingSheetStyle.COVER_OUT_MS); assertEquals(220, SessionLoadingSheetStyle.COVER_IN_MS)
    }
}
```

- [ ] **Step 2: Run to verify failure** → unresolved `SessionLoadingPresentation`, `SessionLoadingSheetModel`, `SessionLoadingSheetStyle`.

- [ ] **Step 3: Implement**

`SessionLoadingPresentation.kt` — translate `Sources/CodeRelayClient/Views/SessionLoadingPresentation.swift` at main exactly (init gate on `expectsSession` for Connecting/Authenticating/LoadingSessions; "0 KB" literal; `readied()`; `endsInReady(after:)`; the model with `MINIMUM_VISIBLE_MS`, `STALL_TIMEOUT_MS`, `READY_DWELL_MS`, `showReady`, `armStall`, `settle`). Kotlin shape of the model:

```kotlin
class SessionLoadingSheetModel(
    private val scope: CoroutineScope,
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    private val _isPresented = MutableStateFlow(false); val isPresented: StateFlow<Boolean> = _isPresented.asStateFlow()
    private val _shown = MutableStateFlow<SessionLoadingPresentation?>(null); val shown: StateFlow<SessionLoadingPresentation?> = _shown.asStateFlow()
    private var active = false; private var holdElapsed = true; private var stalled = false; private var showingReady = false
    private var holdJob: Job? = null; private var stallJob: Job? = null; private var readyJob: Job? = null

    fun update(p: SessionLoadingPresentation) {
        val changed = p != _shown.value
        val wasActive = active
        active = p.isActive
        if (p.isActive) { readyJob?.cancel(); readyJob = null; showingReady = false; _shown.value = p }
        if (wasActive && !active && _isPresented.value && !stalled && p.endsInReady(after = _shown.value)) {
            stallJob?.cancel(); stallJob = null; showReady(); return
        }
        if (active && changed) { stalled = false; armStall() }
        if (active && !_isPresented.value && !stalled) {
            _isPresented.value = true; holdElapsed = false
            holdJob?.cancel(); holdJob = scope.launch { sleepMs(MINIMUM_VISIBLE_MS); holdElapsed = true; settle() }
        }
        if (!active) { stallJob?.cancel(); stallJob = null; stalled = false }
        settle()
    }
    // armStall / showReady / settle: as in Swift, with scope.launch + sleepMs.
    companion object { const val MINIMUM_VISIBLE_MS = 600L; const val STALL_TIMEOUT_MS = 15_000L; const val READY_DWELL_MS = 600L }
}
```

`SessionLoadingSheet.kt` (shared Compose; Material3 `ModalBottomSheet` sizes to content on both platforms, so no fixed height to clip — the Plan 2 v0.3.35 lesson):

```kotlin
package relay.feature.workspace.ui

object SessionLoadingSheetStyle {
    const val BYTES_SP = 24
    const val STATUS_SP = 14
    const val COVER_OUT_MS = 160
    const val COVER_IN_MS = 220
    const val MAX_WIDTH_DP = 340
}

/** Black over the terminal while the loading sheet is up; quick to black, slower back (matches the Apple apps). */
fun Modifier.terminalLoadingCover(covered: Boolean): Modifier = composed {
    val alpha by animateFloatAsState(
        targetValue = if (covered) 1f else 0f,
        animationSpec = tween(if (covered) SessionLoadingSheetStyle.COVER_OUT_MS else SessionLoadingSheetStyle.COVER_IN_MS),
        label = "terminalLoadingCover",
    )
    drawWithContent { drawContent(); drawRect(Color.Black.copy(alpha = alpha)) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionLoadingSheetHost(model: SessionLoadingSheetModel, onCancel: () -> Unit) {
    val presented by model.isPresented.collectAsState()
    val shown by model.shown.collectAsState()
    val p = shown ?: return
    if (!presented) return
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { it != SheetValue.Hidden })
    ModalBottomSheet(
        onDismissRequest = {},                 // never dismissible by the user: the load ends it
        sheetState = sheetState,
        dragHandle = null,
        properties = ModalBottomSheetProperties(shouldDismissOnBackPress = false),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(24.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(Modifier.height(36.dp), contentAlignment = Alignment.Center) {
                if (p.isReady) Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Color(0xFF34C759), modifier = Modifier.size(32.dp))
                else CircularProgressIndicator()
            }
            Text(p.title, style = MaterialTheme.typography.titleMedium)
            // Every row is laid out in every state and hidden when empty, so the
            // sheet keeps ONE size from the first phase to Ready (the Apple
            // sheet grew and shrank by a row per state until v0.3.36).
            Text(p.detail ?: "0 KB", fontSize = SessionLoadingSheetStyle.BYTES_SP.sp, fontWeight = FontWeight.SemiBold,
                 fontFamily = FontFamily.Monospace,
                 modifier = Modifier.alpha(if (p.detail == null) 0f else 1f).semantics { contentDescription = "${p.detail ?: ""} loaded" })
            Text(p.status, fontSize = SessionLoadingSheetStyle.STATUS_SP.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text(p.subtitle ?: " ", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline, maxLines = 1)
            OutlinedButton(onClick = onCancel, enabled = p.allowsCancel,
                           modifier = Modifier.alpha(if (p.allowsCancel) 1f else 0f)) { Text("Cancel") }
        }
    }
}
```

(Imports: `androidx.compose.material3.*` incl. `ModalBottomSheetProperties`, `SheetValue`, `rememberModalBottomSheetState`; `androidx.compose.material.icons.Icons`, `androidx.compose.material.icons.filled.CheckCircle` — check `material-icons-core` is on both classpaths with `grep -rn "material.icons\|materialIconsExtended\|compose.materialIconsExtended" CodeRelayAndroid/feature-workspace/build.gradle.kts CodeRelayLinux/feature-workspace/build.gradle.kts`; if not, draw the checkmark with a `Canvas` path instead of adding a dependency. If CMP 1.12's `ModalBottomSheetProperties` lacks `shouldDismissOnBackPress`, drop the `properties` argument on the shared call and record the ruling — `onDismissRequest = {}` plus `confirmValueChange` already prevents dismissal.)

`WorkspaceScreen.kt`: delete the `SessionLoadingOverlay(...)` call and the recovery scrim; add `val loading = remember(scope) { SessionLoadingSheetModel(scope) }` where `scope = rememberCoroutineScope()`; derive the presentation from the focus coordinator (Task 7 supplies it; for this task use `vm.coordinator`):

```kotlin
    val c = vm.coordinator
    val phase by c.sessionLoadPhase.collectAsState(); val recovering by c.isRecovering.collectAsState()
    val recoveryPhase by c.recoveryPhase.collectAsState(); val activeId by c.activeSessionId.collectAsState()
    val failed by c.lastLoadFailed.collectAsState(); val recoveryFailed by c.recoveryFailed.collectAsState()
    val presentation = SessionLoadingPresentation(
        loadPhase = phase, isRecovering = recovering, recoveryPhase = recoveryPhase,
        expectsSession = c.expectsSessionToLoad, sessionAttached = activeId != null,
        loadFailed = failed || c.loadEndedInFailure, recoveryFailed = recoveryFailed,
        sessionName = activeId?.let { c.name(it) }, serverName = serverName,
    )
    LaunchedEffect(presentation) { loading.update(presentation) }
    val covered by loading.isPresented.collectAsState()
    // terminal box: Modifier.terminalLoadingCover(covered)
    SessionLoadingSheetHost(loading, onCancel = { c.cancelRecovery() })
```

(`serverName` is a new `WorkspaceScreen` parameter, `String? = null`, filled by Task 7.)

- [ ] **Step 4: Run** Android `:core-session:test :feature-workspace:testDebugUnitTest assembleDebug` and Linux `:shared-session:test :feature-workspace:test --no-daemon` (the Linux run is what proves `ModalBottomSheet` compiles on CMP desktop) → green.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/core-session CodeRelayAndroid/feature-workspace
git rm -q CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionLoadingOverlay.kt
git commit -m "feat(kotlin): one loading sheet for switch, refresh and reconnect — bytes as the largest text, Ready for 0.6 s, terminal fades to black, never stays up

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Hub workspace UI — section headers, grouped sidebar, tabs across servers (feature-workspace)

**Files:**
- Create: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/hub/WorkspaceSlot.kt`, `.../hub/ServerSectionHeader.kt`, `.../hub/HubSidebar.kt`, `.../hub/HubTabs.kt`, `.../hub/HubWorkspaceLogic.kt`
- Modify: `WorkspaceScreen.kt` (new hub entry point; current body becomes `internal fun WorkspacePane(vm, sidebar, tabs, serverName, …)`), `ui/SessionSidebar.kt` (extract the per-session row list into `internal fun LazyListScope.sessionRows(…)` so `HubSidebar` can emit it per section; `SessionSidebar` keeps calling it)
- Test: `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/hub/HubWorkspaceLogicTest.kt`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces: `interface WorkspaceSlot : ServerSlot { val coordinator: SessionCoordinator; val workspaceViewModel: WorkspaceViewModel }`; `@Composable fun WorkspaceScreen(hub: ServerHub<out WorkspaceSlot>, onOpenServers: () -> Unit, onShareQr: (SessionRef) -> Unit, shareScreen: Boolean, hapticsEnabled: Boolean, sidebarToggleRequests: Flow<Unit> = emptyFlow(), modifier: Modifier = Modifier)`; `data class ServerSectionHeaderModel(title, subtitle: String?, dot: HeaderDot, badge: Int, offersRetry: Boolean, isDuplicate: Boolean)` with `companion fun of(section: ServerSection)`; `object HubWorkspaceLogic { fun shouldPresentManagement(agg: HubAggregate): Boolean; fun tabs(sections, activeRef): List<HubTab>; fun retryAction(section): RetryAction; fun isConnecting(sections): Boolean }`; `data class HubTab(val ref: SessionRef, val number: Int, val isSelected: Boolean, val serverTitle: String?)`.

- [ ] **Step 1: Write the failing tests** — `HubWorkspaceLogicTest.kt` (ports of iOS `SidebarSectionsTests`, `SessionTabStripTests`, `WorkspaceRootTests.testEmptyStateOpensManagement…`, and Mac `ServerSectionHeaderTests`):

```kotlin
class HubWorkspaceLogicTest {
    private fun section(name: String, status: ServerSectionStatus, enabled: Boolean = true, sessions: Int = 1, collapsed: Boolean = false) =
        ServerSection(ConnectionConfig(name = name, host = name, enabled = enabled), status,
            (0 until sessions).map { session() }, !status.isLive, emptyList(), 0, collapsed)

    @Test fun noEnabledServerPresentsManagement() {   // Review Focus 3
        assertTrue(HubWorkspaceLogic.shouldPresentManagement(HubAggregate()))
        assertTrue(HubWorkspaceLogic.shouldPresentManagement(HubAggregate(totalServers = 2, enabledServers = 0)))
        assertFalse(HubWorkspaceLogic.shouldPresentManagement(HubAggregate(totalServers = 1, enabledServers = 1)))
    }

    @Test fun tabsNumberAcrossServersSkipDisabledAndTitleOnlyWithSeveral() {
        val a = section("a", ServerSectionStatus.Live, sessions = 2); val b = section("b", ServerSectionStatus.Live)
        val c = section("c", ServerSectionStatus.Disabled, enabled = false, sessions = 3)
        val tabs = HubWorkspaceLogic.tabs(listOf(a, b, c), SessionRef(b.id, b.sessions[0].id))
        assertEquals(listOf(1, 2, 3), tabs.map { it.number })
        assertEquals(listOf(a.id, a.id, b.id), tabs.map { it.ref.serverId })
        assertEquals(listOf(false, false, true), tabs.map { it.isSelected })
        assertEquals(listOf("a", "a", "b"), tabs.map { it.serverTitle })
        assertEquals(listOf<String?>(null), HubWorkspaceLogic.tabs(listOf(a.copy(sessions = a.sessions.take(1)), c), null).map { it.serverTitle }, "G8")
    }

    @Test fun tabsAreKeyedByRefNotBareUuid() {   // Review Focus 4
        val shared = session()
        val a = section("a", ServerSectionStatus.Live).copy(sessions = listOf(shared))
        val b = section("b", ServerSectionStatus.Live).copy(sessions = listOf(shared))
        val tabs = HubWorkspaceLogic.tabs(listOf(a, b), SessionRef(b.id, shared.id))
        assertEquals(2, tabs.map { it.ref }.toSet().size)
        assertEquals(listOf(false, true), tabs.map { it.isSelected }, "the same UUID on two servers is two tabs, one selected")
    }

    @Test fun retryAndConnectingRules() {
        assertEquals(RetryAction.OPEN_MANAGEMENT, HubWorkspaceLogic.retryAction(section("a", ServerSectionStatus.AuthFailed("x"))))
        assertEquals(RetryAction.RECOVER, HubWorkspaceLogic.retryAction(section("a", ServerSectionStatus.Offline)))
        assertFalse(HubWorkspaceLogic.isConnecting(listOf(section("a", ServerSectionStatus.AuthFailed("x")), section("b", ServerSectionStatus.Offline))))
        assertTrue(HubWorkspaceLogic.isConnecting(listOf(section("a", ServerSectionStatus.Connecting))))
    }

    @Test fun headerModelTable() {
        val m = ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Offline))
        assertEquals("offline", m.subtitle); assertEquals(HeaderDot.RED, m.dot); assertTrue(m.offersRetry)
        assertEquals("No token stored for this server", ServerSectionHeaderModel.of(section("a", ServerSectionStatus.AuthFailed("No token stored for this server"))).subtitle)
        assertNull(ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Live)).subtitle)
    }
}
```

- [ ] **Step 2: Run to verify failure** → unresolved `HubWorkspaceLogic`, `ServerSectionHeaderModel`, `HubTab`, `RetryAction`, `HeaderDot`.

- [ ] **Step 3: Implement**

- `WorkspaceSlot.kt` — the interface.
- `HubWorkspaceLogic.kt` — the pure functions; `tabs` = enabled sections' sessions flattened in order, numbered from 1, `serverTitle` = section title only when >1 enabled section; `retryAction` = `OPEN_MANAGEMENT` for `AuthFailed`, else `RECOVER`; `isConnecting` = any enabled section `Connecting`/`Reconnecting`.
- `ServerSectionHeader.kt` — `ServerSectionHeaderModel.of(section)` mapping (Live: no subtitle, GREEN, no retry; Connecting: "connecting…", ORANGE; Reconnecting: "reconnecting…", ORANGE; Offline: "offline", RED, retry; AuthFailed(m): m, ORANGE, retry; Disabled: "disabled", GRAY), `badge = awaitingInput` when live; the composable `ServerSectionHeader(model, isCollapsed, onToggle, onRetry, onNew: (() -> Unit)?)`: a `Row` with a dot, title (`titleSmall`, bold), subtitle (`labelSmall`, muted), ⚠ icon when duplicate, badge, Retry `IconButton` when `offersRetry`, `+` `IconButton` when `onNew != null`, chevron. Accessibility: one merged node "<title>, <subtitle>".
- `HubSidebar.kt` — `@Composable fun HubSidebar(hub: ServerHub<out WorkspaceSlot>, onOpenServers: () -> Unit, onAttach: (WorkspaceSlot) -> Unit, onShareQr: (SessionRef) -> Unit, modifier: Modifier)`: one `LazyColumn`; top `item { Row { OutlinedButton("Servers"); focus?.let { OutlinedButton("Attach") } } }`; for each section: `item(key = section.id) { ServerSectionHeader(…, onToggle = { hub.setCollapsed(id, !collapsed) }, onRetry = { if (retryAction == OPEN_MANAGEMENT) onOpenServers() else hub.triggerUserRecovery(id) }, onNew = if live { { scope.launch { hub.createSession(id) } } } else null) }`, then when not collapsed and the slot exists: `sessionRows(…)` from `SessionSidebar.kt` fed by that slot's coordinator (names, agents, states, rollups) with `onSelect = { id -> scope.launch { hub.select(SessionRef(section.id, id)) } }`, rows at `alpha(0.5f)` when `section.isCached`; when the slot is missing (disabled / token-less) plain greyed `Text` rows with no click. Pull-to-refresh calls `hub.handleForegroundTransition()`. A "Connecting…" progress row only when `HubWorkspaceLogic.isConnecting(sections) && aggregate.liveServers == 0`.
- `HubTabs.kt` — renders `HubWorkspaceLogic.tabs(...)` with the existing `SessionTabs` visuals; `onSelect(tab.ref)` → `hub.select`; per-tab agent state / attention from `hub.slot(tab.ref.serverId)?.coordinator`; content description `"<server>, session N"` when `serverTitle != null`. Keys are `tab.ref`.
- `WorkspaceScreen.kt` — rename the current composable to `internal fun WorkspacePane(vm: WorkspaceViewModel, sidebar: @Composable (Modifier) -> Unit, tabs: @Composable () -> Unit, serverName: String?, onOpenServers: () -> Unit, onShareQr: (UUID) -> Unit, …)` and replace its two internal `SessionSidebar(...)` / `SessionTabs(...)` call sites with `sidebar(...)` / `tabs()`; its "disconnect" toolbar button calls `onOpenServers` (label "Servers"). The new public `WorkspaceScreen(hub, …)`:

```kotlin
@Composable
fun WorkspaceScreen(
    hub: ServerHub<out WorkspaceSlot>,
    onOpenServers: () -> Unit,
    onShareQr: (SessionRef) -> Unit,
    shareScreen: Boolean = true,
    hapticsEnabled: Boolean = false,
    sidebarToggleRequests: Flow<Unit> = emptyFlow(),
    modifier: Modifier = Modifier,
) {
    val focus by hub.focusSlot.collectAsState()
    val active by hub.activeSlot.collectAsState()
    val sections by hub.sections.collectAsState()
    val aggregate by hub.aggregate.collectAsState()
    val notice by hub.notice.collectAsState()
    val slot = active ?: focus
    LaunchedEffect(aggregate) { if (HubWorkspaceLogic.shouldPresentManagement(aggregate)) onOpenServers() }
    Box(modifier) {
        if (slot == null) {
            HubEmptyState(aggregate, onOpenServers)     // "No Servers Enabled" + Servers button / "Connecting…"
        } else key(slot) {                               // a cross-server switch rebuilds the pane (Review Focus: terminal host)
            WorkspacePane(
                vm = slot.workspaceViewModel,
                sidebar = { m -> HubSidebar(hub, onOpenServers, onAttach = { /* host shows AttachSessionSheet for it */ }, onShareQr, m) },
                tabs = { HubTabs(hub) },
                serverName = sections.firstOrNull { it.id == slot.config.id }?.title,
                onOpenServers = onOpenServers,
                onShareQr = { id -> onShareQr(SessionRef(slot.config.id, id)) },
                shareScreen = shareScreen, hapticsEnabled = hapticsEnabled, sidebarToggleRequests = sidebarToggleRequests,
            )
        }
        notice?.let { NoticeCapsule(it) { hub.setNotice(null) } }   // auto-clears after 4 s via LaunchedEffect(it)
    }
}
```

The existing `onAttach: () -> Unit` parameter of `WorkspaceScreen` moves into `WorkspacePane` unchanged; the hosts (Tasks 9–10) supply it per focus slot.

- [ ] **Step 4: Run** Android `:feature-workspace:testDebugUnitTest assembleDebug` and Linux `:feature-workspace:test :app:test --no-daemon` → green (the hosts still call the old signature until Tasks 9–10: **ruling to record** — Tasks 7, 9 and 10 compile only together, as Plan 1's Tasks 8/9 did; build them in one cycle and commit per task).

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/feature-workspace
git commit -m "feat(kotlin): workspace grouped by server — section headers, hub sidebar, tabs across servers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Server management with Enabled toggles (feature-servers, both ServersViewModels)

**Files:**
- Modify: `CodeRelayAndroid/feature-servers/src/main/kotlin/relay/feature/servers/ServersScreen.kt`, `.../ServersViewModel.kt` (Android), `.../ServerFormLogic.kt`, `.../AddEditServerSheet.kt`; `CodeRelayLinux/feature-servers/src/main/kotlin/relay/feature/servers/ServersViewModel.kt`
- Create: `CodeRelayAndroid/feature-servers/src/main/kotlin/relay/feature/servers/ServerPolling.kt`
- Test: `CodeRelayAndroid/feature-servers/src/test/kotlin/relay/feature/servers/ServerManagementTest.kt`, additions to `ServerFormLogicTest.kt`

**Interfaces:**
- Consumes: Task 4 `ServerHub` (`sections`, `aggregate`, `notice`, `setEnabled`, `reloadBookmarks`, `rebuildSlot`), Task 5 `removeServer`.
- Produces: `ServersScreen(viewModel, hub: ServerHub<*>, onDone: () -> Unit, modifier, pendingPairingUrl, clearPendingPairing, onScanPair)` — no `onConnect`; `object ServerPolling { fun targets(list: List<ConnectionConfig>): List<ConnectionConfig> }`; `ServerFormLogic.buildConfig(existing: ConnectionConfig?, name, host, port, useTLS): ConnectionConfig?`; `fun shouldRebuild(afterEditing: ServerSection): Boolean = !section.status.isLive`.

- [ ] **Step 1: Write the failing tests**

```kotlin
class ServerManagementTest {
    @Test fun statusPollerTargetsOnlyDisabledBookmarks() {
        val a = ConnectionConfig(name = "a", host = "a", enabled = true); val b = ConnectionConfig(name = "b", host = "b", enabled = false)
        assertEquals(listOf(b.id), ServerPolling.targets(listOf(a, b)).map { it.id })
    }
    @Test fun editingALiveServerDoesNotRebuildItsCoordinator() {
        fun s(st: ServerSectionStatus) = ServerSection(ConnectionConfig(name = "a", host = "a"), st, emptyList(), false, emptyList(), 0, false)
        assertFalse(shouldRebuild(s(ServerSectionStatus.Live)))
        assertTrue(shouldRebuild(s(ServerSectionStatus.AuthFailed("x")))); assertTrue(shouldRebuild(s(ServerSectionStatus.Offline)))
    }
}
```

`ServerFormLogicTest.kt` addition:

```kotlin
    @Test fun editingPreservesEnabledInstanceAndDisplayName() {
        val existing = ConnectionConfig(name = "a", host = "a.local", enabled = false, instanceId = UUID.randomUUID(), displayName = "Studio")
        val built = ServerFormLogic.buildConfig(existing, name = "renamed", host = "a.local", port = "9200", useTLS = false)!!
        assertEquals(existing.id, built.id); assertEquals("renamed", built.name)
        assertFalse(built.enabled, "renaming a disabled bookmark must not enable it")
        assertEquals(existing.instanceId, built.instanceId); assertEquals("Studio", built.displayName)
    }
```

(Update every existing `buildConfig(existingId = …)` call in that test file and in `AddEditServerSheet.kt` to the new `existing` parameter.)

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**
- `ServerPolling.kt`: `object ServerPolling { fun targets(list: List<ConnectionConfig>) = list.filter { !it.enabled } }`; `shouldRebuild` in the same file.
- `ServerFormLogic.buildConfig(existing, …)`: `(existing ?: ConnectionConfig(name = "", host = "")).copy(name = trimmedName.ifEmpty { trimmedHost }, host = trimmedHost, port = p, useTLS = useTLS)` (keep the validation returning null).
- Both `ServersViewModel`s: `statusChecker.startPolling(ServerPolling.targets(_servers.value))` and `refresh(...)` the same; delete-from-VM paths are no longer used by the screen (keep `addOrUpdate`, `tokenFor`).
- `ServersScreen`: rows come from `hub.sections`; each row shows the title (`config.title`), `ws(s)://host:port`, the status dot+caption (enabled → `ServerSectionHeaderModel.of(section)`; disabled → the poller's probe: "disabled · reachable / offline / token rejected"), "instance 1a2b3c4d…" when known, ⚠ when `isDuplicateInstance`, and a trailing `Switch(checked = config.enabled, onCheckedChange = { on -> scope.launch { hub.setEnabled(id, on) } })`. Tapping the row opens edit (no connect). Swipe end→start deletes via `scope.launch { hub.removeServer(id) }`. Add/edit `onSave`: `viewModel.addOrUpdate(config, token)` then `hub.reloadBookmarks()` and, for edits, `if (shouldRebuild(section)) hub.rebuildSlot(id)`. Pairing `onPaired`: `hub.reloadBookmarks()` (the cap is enforced there). Footer: "N of M enabled · up to 8 at once"; `hub.notice` shown in orange above it. A "Done" action (`onDone`) only when `aggregate.enabledServers > 0`.

- [ ] **Step 4: Run** Android `:feature-servers:testDebugUnitTest` (or `:feature-servers:test` — whichever the module runs; check `./gradlew :feature-servers:tasks --all | grep -i test`) and Linux `:feature-servers:test --no-daemon` → green.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/feature-servers CodeRelayLinux/feature-servers
git commit -m "feat(kotlin): server management with per-bookmark Enabled; edits preserve the bookmark's multi-server fields

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Android app on the hub (app, feature-settings)

**Files:**
- Create: `CodeRelayAndroid/app/src/main/kotlin/relay/app/HubViewModel.kt`, `.../AndroidHubAdapters.kt` (`AndroidBookmarkStore`, `AndroidTokenSource`, `SharedPrefsHubPreferences`), `.../DeepLinkRouting.kt`
- Modify: `CodeRelayAndroid/app/src/main/kotlin/relay/app/CoordinatorFactory.kt` (`ConnectionSession.create` gains `ownershipNamespace: String`; new `class AppServerSlot : CoordinatorServerSlot, WorkspaceSlot`), `MainActivity.kt` (pending session link → hub; drop `resolveAutoConnect`), `RelayNavGraph.kt` (start at WORKSPACE; SERVERS is management; no connect flow), `PushSync.kt` (builds `PushSettings`), `RelayFirebaseMessagingService.kt` (unchanged payload pass-through — verify it keeps `data["deepLink"]` verbatim including `?server=`), `feature-settings/.../SettingsScreen.kt` (remove the Auto Connect row and `SettingsSection.CONNECTION`), `feature-settings/.../AppSettings.kt` (`suspend fun lastConnectedServerIdNow(): String` reading `dataStore.data.first()`)
- Delete: `CodeRelayAndroid/app/src/main/kotlin/relay/app/ConnectionViewModel.kt`
- Test: `CodeRelayAndroid/app/src/test/kotlin/relay/app/DeepLinkRoutingTest.kt`, `.../HubViewModelTest.kt` (add `testImplementation` JUnit5 + coroutines-test + `unitTests.all { it.useJUnitPlatform() }` to `app/build.gradle.kts`, copying the lines from `core-session/build.gradle.kts`)

**Interfaces:**
- Consumes: Tasks 1–8.
- Produces: `class HubViewModel(application: Application) : AndroidViewModel(application)` with `val hub: ServerHub<AppServerSlot>`, `fun start()` (idempotent), `fun onForeground()`, `fun onConnectivityRestored()`, `fun syncPush()`, `fun open(link: SessionDeepLink)`; `object DeepLinkRouting { sealed interface Route { data class Session(val link: SessionDeepLink) ; data class Pair(val url: PairingURL); data object None }; fun route(uri: String?): Route }`.

- [ ] **Step 1: Write the failing tests**

```kotlin
class DeepLinkRoutingTest {
    @Test fun launchIntentRoutesSessionLinksToTheHub() {   // Review Focus 1
        val sid = UUID.randomUUID(); val iid = UUID.randomUUID()
        assertEquals(DeepLinkRouting.Route.Session(SessionDeepLink(sid, iid)), DeepLinkRouting.route("coderelay://session/$sid?server=$iid"))
        assertTrue(DeepLinkRouting.route("coderelay://pair?host=h&port=9200&tls=0&code=ABCDEFGH") is DeepLinkRouting.Route.Pair)
        assertEquals(DeepLinkRouting.Route.None, DeepLinkRouting.route(null))
    }
}

class HubViewModelTest {
    @Test fun hubViewModelStartsTheHubOnce() = runTest {    // Review Focus 2
        // HubViewModel's hub construction is behind an internal factory parameter for tests:
        // HubViewModel.forTest(scope = this, bookmarks = InMemoryBookmarks(listOf(cfg)), tokens = FakeTokens(...), slotFactory = { c, _ -> FakeAppSlot(c) })
        val built = mutableListOf<ConnectionConfig>()
        val vm = HubViewModel.forTest(this, listOf(ConnectionConfig(name = "a", host = "a")), onBuild = { built += it })
        vm.start(); vm.start(); advanceUntilIdle()
        assertEquals(1, built.size, "rotation re-runs onCreate; the activity-scoped hub must not start twice")
    }
}
```

(`HubViewModel.forTest` is an `internal` companion factory that takes the seams instead of `Application`; `FakeAppSlot` is a test class implementing `WorkspaceSlot` by delegating `ServerSlot` to `FakeServerSlot` — `core-session`'s test fixtures are not visible to `:app` tests, so copy the ~20 lines of `FakeServerSlot` you need into `app/src/test`.)

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**
- `AndroidHubAdapters.kt`: `AndroidBookmarkStore(store: SavedConnectionStore) : BookmarkStore` (delegates; `add` returns Unit); `AndroidTokenSource(store: TokenStore) : TokenSource`; `SharedPrefsHubPreferences(context) : HubPreferences` over `context.getSharedPreferences("relay.hub", MODE_PRIVATE)`.
- `CoordinatorFactory.kt`: `ConnectionSession.create(context, config, token, settings, ownershipNamespace = config.id.toString())` builds `SessionOwnershipStore(appContext, deviceId, namespace = ownershipNamespace)`; `class AppServerSlot(val session: ConnectionSession) : CoordinatorServerSlot(session.config, session.coordinator), WorkspaceSlot { override val workspaceViewModel get() = session.workspaceViewModel; override suspend fun tearDown() { super.tearDown(); session.scope.cancel() } }` (store `config` on `ConnectionSession` if it is not already).
- `HubViewModel.kt`:

```kotlin
class HubViewModel internal constructor(
    private val app: Application?,
    scope: CoroutineScope?,
    bookmarks: BookmarkStore, tokens: TokenSource, prefs: HubPreferences,
    slotFactory: (ConnectionConfig, String) -> AppServerSlot,
    migration: (suspend () -> Unit)?,
) : ViewModel() {
    constructor(application: Application) : this(application, null, /* real adapters */, …)
    private val hubScope = scope ?: viewModelScope   // viewModelScope is Main.immediate
    val hub = ServerHub(hubScope, bookmarks, tokens, HubStateStore(prefs, "relay"), slotFactory, migration)
    private var started = false
    fun start() { if (started) return; started = true; hubScope.launch { hub.start(); syncPush() } }
    fun onForeground() { hub.handleForegroundTransition(); hub.activeSlot.value?.coordinator?.restoreActiveOnForeground() }
    fun onConnectivityRestored() = hub.handleForegroundTransition()
    fun syncPush() { app ?: return; hubScope.launch { hub.syncPushRegistration(PushSync.settings(app)) } }
    fun open(link: SessionDeepLink) { hubScope.launch { hub.handleDeepLink(link) } }
    override fun onCleared() { hub.stop() }
}
```

The real constructor's migration lambda: `{ HubMigration.run(bookmarks, settings.lastConnectedServerIdNow(), state) { keep -> SessionOwnershipStore(app, deviceId).moveLegacyInto(keep?.toString()) }; settings.setLastConnectedServerId("") }`.
- `PushSync.settings(context): PushSettings` (FCM token from `FcmTokenBridge`, `notificationsGranted`, `DeviceIdentifier.get`, `pushEnabled = true`, `notifyOnFinished = false` — the values `PushSync.sync` passes today); `FcmTokenBridge.onTokenRefreshed = { hubViewModel.syncPush() }` is set once in `MainActivity.onCreate`.
- `MainActivity`: `val hubViewModel: HubViewModel by viewModels()`; `onCreate` calls `hubViewModel.start()` then `handleIntent(intent)`; `onNewIntent` → `handleIntent`; `handleIntent` uses `DeepLinkRouting.route(intent.data?.toString())` → `Session(link)` → `hubViewModel.open(link)`, `Pair(url)` → `_pendingPairing.value = url`. Delete `_pendingSessionId`, `_autoConnectConfig`, `resolveAutoConnect`.
- `RelayNavGraph`: start destination after SPLASH is `WORKSPACE`; WORKSPACE hosts `WorkspaceScreen(hub = hubViewModel.hub, onOpenServers = { nav.navigate(SERVERS) }, onShareQr = { ref -> shareRef = ref }, …)` with `LifecycleEventEffect(ON_RESUME) { hubViewModel.onForeground() }` and `connectivity.connectivityRestored.collect { hubViewModel.onConnectivityRestored() }`; SERVERS hosts `ServersScreen(viewModel, hub = hubViewModel.hub, onDone = { nav.popBackStack() }, …)`; the QR share sheet builds `SessionDeepLink(ref.sessionId, hub.sections.value.firstOrNull { it.id == ref.serverId }?.config?.instanceId).uri`. Remove `connectAndOpen`, `connectionVm`, the auto-connect `LaunchedEffect`.
- `SettingsScreen`: delete the CONNECTION section and the enum entry; `grep -rn "SettingsSection.CONNECTION" CodeRelayAndroid CodeRelayLinux` must be empty afterwards. Keep `AppSettings.autoConnectEnabled` (unused; removing the key would not delete stored data).

- [ ] **Step 4: Run** the full Android gate (Global Constraints) → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/app CodeRelayAndroid/feature-settings
git rm -q CodeRelayAndroid/app/src/main/kotlin/relay/app/ConnectionViewModel.kt
git commit -m "feat(android): the hub owns the workspace — HubViewModel, per-server coordinators, push and deep links through the hub, servers screen is management

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Linux app on the hub (app, linux-storage, linux-platform)

**Files:**
- Create: `CodeRelayLinux/app/src/main/kotlin/relay/app/LinuxHub.kt` (adapters + `LinuxServerSlot` + factory)
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt` (replace `var session` / `connectTo` / `lastConnectedServer` with the hub; WorkspaceScreen/ServersScreen hosting; shortcuts; tray; notifier; deep links), `ConnectionSession.kt` (namespace parameter), `DeepLinks.kt` (`DeepLink.Session(val link: SessionDeepLink)`), `TrayMenu.kt` (server prefix when >1 enabled), `CodeRelayLinux/feature-settings/.../AppSettings.kt` (`fun lastConnectedServerIdNow(): String = lastConnectedServerId.value`)
- Test: `CodeRelayLinux/app/src/test/kotlin/relay/app/DeepLinksTest.kt` (update), `.../TrayModelTest.kt` (server prefix), `.../LinuxHubTest.kt`

**Interfaces:**
- Consumes: Tasks 1–8.
- Produces: `class LinuxServerSlot(val session: ConnectionSession) : CoordinatorServerSlot(session.config, session.coordinator), WorkspaceSlot`; `fun createLinuxHub(environment: AppEnvironment, settings: AppSettings, scope: CoroutineScope): ServerHub<LinuxServerSlot>`; `TrayModel.rows(..., serverPrefix: String?)`.

- [ ] **Step 1: Write the failing tests**

```kotlin
// DeepLinksTest additions
    @Test fun sessionLinksCarryTheServerHint() {
        val sid = UUID.randomUUID(); val iid = UUID.randomUUID()
        assertEquals(DeepLink.Session(SessionDeepLink(sid, iid)), DeepLinks.parse("coderelay://session/$sid?server=$iid"))
        assertEquals(DeepLink.Session(SessionDeepLink(sid)), DeepLinks.parse(sid.toString()), "a bare UUID argv still works")
    }

// TrayModelTest addition
    @Test fun rowsArePrefixedWithTheServerWhenSeveralAreEnabled() {
        val id = UUID.randomUUID()
        val model = TrayModel.rows(listOf(sessionInfo(id)), mapOf(id to "alpha"), emptyMap(), emptySet(), activeId = null, serverPrefix = "studio")
        assertEquals("studio · alpha", model.sessions.single().label)
    }

// LinuxHubTest
    @Test fun ownershipIsNamespacedPerBookmark(@TempDir dir: File) {
        val a = UUID.randomUUID(); val sid = UUID.randomUUID()
        relay.storage.SessionOwnershipStore(dir, namespace = a.toString()).setName(sid, "alpha")
        assertEquals("alpha", relay.storage.SessionOwnershipStore(dir, namespace = a.toString()).names[sid])
        assertNull(relay.storage.SessionOwnershipStore(dir).names[sid])
    }
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**
- `LinuxHub.kt`: `LinuxBookmarkStore(SavedConnectionStore)`, `LinuxTokenSource(TokenStore)` (`loadToken` wraps `runCatching` — a locked keyring throws → null → authFailed; Review Focus 5), `PreferenceStoreHubPreferences(PreferenceStore)`; `LinuxServerSlot`; `createLinuxHub(...)` = `ServerHub(scope, …, factory = { c, t -> LinuxServerSlot(ConnectionSession.create(c, t, settings, environment, ownershipNamespace = c.id.toString())) }, migration = { HubMigration.run(bookmarks, settings.lastConnectedServerIdNow(), state) { keep -> environment.ownership.moveLegacyInto(keep?.toString()) }; settings.setLastConnectedServerId("") })`.
- `ConnectionSession.create(..., ownershipNamespace: String)` → `SessionOwnershipAdapter(SessionOwnershipStore(XdgPaths.stateDir, namespace = ownershipNamespace))` instead of the shared `environment.ownership`.
- `Main.kt`: `val hub = remember { createLinuxHub(environment, settings, environment.scope) }`; `LaunchedEffect(Unit) { hub.start() }`; workspace shows `WorkspaceScreen(hub, onOpenServers = { showServers = true }, onShareQr = { ref -> shareRef = ref }, …)`; servers panel `ServersScreen(serversViewModel, hub, onDone = { showServers = false }, …)`; `network.connectivityRestored.collect { hub.handleForegroundTransition() }`; notifier: collect each slot's `agentStates` via `hub.sections` + `hub.slot(id)` and pass names prefixed `"<server> · "` when `aggregate.enabledServers > 1`, click-to-focus routes `SessionRef` → `hub.select`; tray model from `hub.focusSlot`; shortcuts: `NEW_SESSION` → `hub.focusServerId.value?.let { hub.createSession(it) }`, `NEXT/PREVIOUS_SESSION` → `hub.selectNext/selectPrevious`, `Ctrl+Alt+N` → `hub.orderedRefs.getOrNull(n)?.let { hub.select(it) }`, `DETACH/TERMINATE_CURRENT` → `hub.activeSlot.value?.coordinator`; `handleLaunch` → `DeepLink.Session(link)` → `hub.handleDeepLink(link)`. Delete `connectTo`, `disconnect`, `lastConnectedServer`, `var session`.
- `DeepLinks.parse`: `"session"` host → `SessionDeepLink.parse(text)?.let { DeepLink.Session(it) }`; bare UUID → `DeepLink.Session(SessionDeepLink(uuid))`.

- [ ] **Step 4: Run** the Linux gate (Global Constraints) → `BUILD SUCCESSFUL` for every module that configures on macOS.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayLinux
git commit -m "feat(linux): the hub owns the workspace — per-server coordinators, grouped sidebar, server-prefixed notifications and tray, deep links through the hub

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Emulator verification, docs, gates, PR

**Files:**
- Modify: `CLAUDE.md` (multi-server paragraph: "macOS, iOS, Android and Linux"; Android/Linux sentences; the loading-sheet paragraph: "The Kotlin clients share the same `SessionLoadingPresentation`/`SessionLoadingSheetModel` in `core-session` and `SessionLoadingSheetHost` in `feature-workspace`" replacing "still have theirs until Plans 3–4")
- No code.

- [ ] **Step 1: Android emulator check** (memory `android-emulator-verification-recipe`; AVD `coderelay35`):

```bash
cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug
~/Library/Android/sdk/emulator/emulator -avd coderelay35 -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot &
adb wait-for-device; until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 2; done
adb install -r app/build/outputs/apk/debug/app-debug.apk
CODE=$(curl -s -X POST 127.0.0.1:9100/pair/create -d '{"label":"emulator-hub"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])')
adb shell am start -a android.intent.action.VIEW -d "coderelay://pair?host=10.0.2.2\&port=9200\&tls=false\&code=$CODE"
sleep 8; adb exec-out screencap -p > /tmp/plan3-01-paired.png
```

Expected (read the screenshot): the workspace with ONE server section header (the local relay's name, green dot), its sessions under it, no server prefix on tabs (G8). Then create a session from the header's `+` and screenshot the loading sheet mid-attach (`adb exec-out screencap -p` within 1 s) — "Loading session", the byte counter, the status line; then after ~2 s the terminal with the sheet gone. Add a second, unreachable bookmark in the Servers screen if a human is available to type; otherwise state in the PR that the two-server view was verified by unit tests only. Clean up: `swift run claude-relay token list` → revoke the `emulator-hub` token with `claude-relay token revoke <id>`; `adb emu kill`. Keep screenshots out of git.

- [ ] **Step 2: Full gates** — the Android and Linux gate commands from Global Constraints, each must end `BUILD SUCCESSFUL`; read the per-module test counts from `build/test-results` (`find . -path '*/test-results/*' -name '*.xml' | xargs grep -h '<testsuite' | sed -E 's/.*tests="([0-9]+)".*failures="([0-9]+)".*/\1 \2/' | awk '{t+=$1; f+=$2} END {print t" tests, "f" failures"}'`) → 0 failures. `swift test` is untouched by this plan; skip it unless a shared doc or Swift file changed.

- [ ] **Step 3: Docs** — the `CLAUDE.md` edits above, plus `CodeRelayAndroid/RELEASE.md`'s "what ships" note if it lists client features.

- [ ] **Step 4: Commit and PR**

```bash
git add CLAUDE.md
git commit -m "docs: multi-server and the loading sheet on Android and Linux

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/multi-server-plan3-kotlin
```

PR title `feat(android,linux): multi-server workspace on a Kotlin ServerHub + the loading sheet (plan 3)`; body: Tasks 1–10 summary, compatibility (one-server users: the migration enables only the last-connected bookmark, the sidebar shows one section with no prefix; the Servers screen becomes management with Enabled toggles; the old inline overlay and recovery scrim are replaced by the sheet), test inventory, emulator verification described in words. Wait for the `android` and `linux` CI jobs.

---

## Self-review notes

- **Spec coverage:** §5 identity (T1), §7.1–7.6 hub (T3–T5), §7.4 coordinator additions (T2 — Kotlin needs `connected`, `serverIdentity`, `isAuthRejected`, `recoveryFailed`, `detachForHub`, attach epoch, namespace; it did not need Swift's single-flight foreground fix because `RecoveryController.triggerUserRecovery` already sets its dispatched flag before launching), §8.1 shared UI (T6–T8), §8.4 Android (T9: nav, `ConnectionViewModel` → hub, `MainActivity` pending link, FCM pass-through, `NetworkObserver` → hub), §8.5 Linux (T10: hub per process, `ConnectionSession` as factory, notifier prefix + click carries `SessionRef`, shortcuts move across sections, `SingleInstance` argv → hub), §9 migration (T3/T9/T10, with the Swift M5 crash-window and stale-id fixes applied), §10 push + deep links (T1/T5/T9/T10), §11 management (T8), §12 edge cases (Review Focus 1–6).
- **One sheet size:** every row (bytes, subtitle, Cancel) is reserved in every state and the width is capped at 340 dp, mirroring the v0.3.36 Apple fix.
- **Mirrors the Swift fix passes:** overlapping selects, single pending ref, deep-link enable detaches first, enabled duplicate wins, reconcile from the coordinator, concurrent staggered start, stop/disable tears down a late build, token-less/disabled rows refused before any state moves, push unregister on disable + settings remembered for late slots, cap on reload, rebuild only when not live, edits preserve bookmark fields, lenient bookmark decoding, loading sheet gated on `expectsSession`, 15 s stall, Ready 0.6 s, `lastLoadFailed` before the phase clears, sheet sized to content.
- **Known coupling:** Tasks 7, 9 and 10 compile only together (the shared `WorkspaceScreen` signature changes under both hosts); Task 6's `WorkspaceScreen` edit uses `vm.coordinator` until Task 7 replaces it. Build those in one cycle and commit per task, with a ledger ruling.
- **Placeholders:** the only deferred-by-design items are explicit "read the existing test double and use its real names" instructions (core-net `SessionControllerTest`, `SessionInfo` constructor) and three Swift routing tests to translate by name — each names the exact source file.
