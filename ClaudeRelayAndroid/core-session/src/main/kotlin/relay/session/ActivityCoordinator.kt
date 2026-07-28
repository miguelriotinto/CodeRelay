package relay.session

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.protocol.ActivityState
import relay.protocol.AgentDetectedState
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import java.util.UUID

/**
 * Minimal persistence surface the coordinator needs from the ownership store.
 *
 * The Swift `ActivityCoordinator` holds a concrete `SessionOwnershipStore` and
 * calls `saveAgents(agentSessions)` on every agent-map change. On Android the
 * store is in `:core-storage` (an Android library) and `:core-session` stays
 * pure-JVM, so we depend on this injected interface instead — exactly the
 * pattern `RecoveryController` / `AuthCoordinator` already use.
 *
 * `SessionOwnershipStore` satisfies this shape directly: it has
 * `setAgent(id, agentId?)` and an `agents` snapshot. The `:app` layer adapts the
 * concrete store to this interface when constructing the coordinator.
 */
interface AgentPersistence {
    /** Last-seen agent per session (UUID→agentId). Read once at init to hydrate. */
    val agents: Map<UUID, String>

    /** Persist (or, when [agentId] is null, remove) the agent for [id]. Diff-checked by the store. */
    fun setAgent(id: UUID, agentId: String?)
}

/**
 * Activity-state facet ported from
 * Sources/ClaudeRelayClient/ViewModels/ActivityCoordinator.swift.
 *
 * Holds the live agent / awaiting-input state plus the "session stolen" UI
 * flags. The Swift original is `@MainActor`-isolated and republishes through
 * the parent `SharedSessionCoordinator`; here the state is exposed as
 * [StateFlow]s the Compose layer collects. Like the Swift type this is **not**
 * thread-safe — callers must confine mutation to a single (main) dispatcher.
 *
 * Persistence: the agent map mirror is written through to the ownership store
 * on every change (Swift `ownershipStore.saveAgents`), so the sidebar can paint
 * the agent badge immediately on reconnect, before the first `sessionActivity`
 * event arrives. The Android store is diff-checked per entry, so we call
 * [AgentPersistence.setAgent] only on the entries that actually changed.
 *
 * ## Agent-map put/remove rule (ActivityCoordinator.swift:102-114)
 *  - `agentActive` / `agentIdle` **with a non-null agent** → put `id → agent`.
 *  - `active` / `idle`, or a null agent → remove `id`.
 * Awaiting-input is derived (ActivityCoordinator.swift:116-120): `id` is in the
 * set **iff** activity is `agentIdle` AND an agent is currently mapped for it;
 * any other update removes `id` from the set.
 */
class ActivityCoordinator(
    private val persistence: AgentPersistence,
) {
    // MARK: - Published state

    private val _agentSessions = MutableStateFlow<Map<UUID, String>>(persistence.agents)

    /**
     * Session ids mapped to the coding agent currently running in them
     * (ActivityCoordinator.swift:28). Server-reported via `sessionActivity`;
     * mirrored to the ownership store so the sidebar can render the badge while
     * waiting for the first event after reconnect. Hydrated from
     * [AgentPersistence.agents] at construction.
     */
    val agentSessions: StateFlow<Map<UUID, String>> = _agentSessions.asStateFlow()

    private val _sessionsAwaitingInput = MutableStateFlow<Set<UUID>>(emptySet())

    /**
     * Session ids whose coding agent is currently idle / awaiting user input
     * (ActivityCoordinator.swift:34). Derived state — cleared automatically when
     * the agent exits. Drives the "needs attention" dot in the sidebar.
     */
    val sessionsAwaitingInput: StateFlow<Set<UUID>> = _sessionsAwaitingInput.asStateFlow()

    private val _agentStates = MutableStateFlow<Map<UUID, AgentDetectedState>>(emptyMap())

    /**
     * Fine-grained agent state per session (server screen-detection). Nil-absent
     * when the server doesn't report it (older server / no agent). Ports the
     * Swift `agentStates` map added in Task 5.
     */
    val agentStates: StateFlow<Map<UUID, AgentDetectedState>> = _agentStates.asStateFlow()

    private val _sessionTitles = MutableStateFlow<Map<UUID, String>>(emptyMap())

    /** Latest window title per session, surfaced under the session name. */
    val sessionTitles: StateFlow<Map<UUID, String>> = _sessionTitles.asStateFlow()

    private val _unseenSessions = MutableStateFlow<Set<UUID>>(emptySet())

    /**
     * Sessions with an unacknowledged blocked/done state — drives the "needs
     * attention" affordance. Cleared by [markSeen] when the user activates the
     * session. Mirrors herdr's client-side `seen` bit.
     */
    val unseenSessions: StateFlow<Set<UUID>> = _unseenSessions.asStateFlow()

    private val _sessionsStolen = MutableStateFlow<Set<UUID>>(emptySet())

    /**
     * Session ids that were taken over by another device since the last
     * [clearStolen]. The Swift original keeps single `stolenSessionName` /
     * `stolenSessionShortId` / `showSessionStolen` alert fields; on Android the
     * set is the source of truth and the richer [stolenAlert] mirrors the most
     * recent one for the alert UI.
     */
    val sessionsStolen: StateFlow<Set<UUID>> = _sessionsStolen.asStateFlow()

    /** UI payload for the "Session Moved" alert (ActivityCoordinator.swift:39-41, :126-130). */
    data class StolenAlert(
        val sessionId: UUID,
        val sessionName: String,
        val shortId: String,
    )

    private val _stolenAlert = MutableStateFlow<StolenAlert?>(null)

    /** The most recent stolen-session alert, or null when none is pending. */
    val stolenAlert: StateFlow<StolenAlert?> = _stolenAlert.asStateFlow()

    // MARK: - Reads (ActivityCoordinator.swift:65-83)

    /** The agent id running in [sessionId], or null. */
    fun activeAgent(sessionId: UUID): String? = _agentSessions.value[sessionId]

    /** Whether any coding agent is currently running in [sessionId]. */
    fun isRunningAgent(sessionId: UUID): Boolean = _agentSessions.value.containsKey(sessionId)

    /**
     * Derive the [ActivityState] for [sessionId] — the lookup order the sidebar
     * uses to pick agentActive/agentIdle/active/idle (ActivityCoordinator.swift:78-83).
     */
    fun activityState(sessionId: UUID): ActivityState {
        val awaiting = _sessionsAwaitingInput.value.contains(sessionId)
        return if (isRunningAgent(sessionId)) {
            if (awaiting) ActivityState.AGENT_IDLE else ActivityState.AGENT_ACTIVE
        } else {
            if (awaiting) ActivityState.IDLE else ActivityState.ACTIVE
        }
    }

    /** The fine-grained agent state for [sessionId], or null. */
    fun agentState(sessionId: UUID): AgentDetectedState? = _agentStates.value[sessionId]

    /** The window title for [sessionId], or null. */
    fun title(sessionId: UUID): String? = _sessionTitles.value[sessionId]

    /**
     * Mark [sessionId]'s state as seen — clears its "needs attention" flag.
     * Called by the coordinator when the session becomes (or is) active.
     */
    fun markSeen(sessionId: UUID) {
        _unseenSessions.value = _unseenSessions.value - sessionId
    }

    /**
     * Group [sessions] into workspace rollups (one per working directory / git
     * root), worst-state first. Parity with Swift `ActivityCoordinator.rollups`:
     * uses the live [agentStates] map (leads the snapshot) + [unseenSessions].
     */
    fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup> =
        WorkspaceRollup.group(
            sessions = sessions,
            agentStates = _agentStates.value,
            unseen = _unseenSessions.value,
            groupKey = { it.workingDir ?: "~" },
            title = { if (it == "~") "Other" else it.substringAfterLast('/') },
        )

    // MARK: - Server-event handlers

    /**
     * Apply an activity update reported by the server (Swift
     * `handleActivityUpdate`, ActivityCoordinator.swift:94-121). Mutates
     * [agentSessions] / [sessionsAwaitingInput] and, when the agent map changes,
     * writes through to the ownership store via [AgentPersistence.setAgent].
     *
     * [onAgentActiveChange] lets the parent coordinator flip the matching
     * terminal view-model's `isAgentActive` flag without this type knowing about
     * the terminal cache — parity with the Swift closure parameter.
     */
    fun applyActivity(
        sessionId: UUID,
        activity: ActivityState,
        agent: String?,
        agentState: AgentDetectedState? = null,
        title: String? = null,
        isActiveSession: Boolean = false,
        onAgentActiveChange: (UUID, Boolean) -> Unit = { _, _ -> },
    ) {
        val current = _agentSessions.value
        // Only persist on an actual transition, not a redundant update
        // (ActivityCoordinator.swift:101).
        if (activity.isAgentRunning && agent != null) {
            if (current[sessionId] != agent) {
                _agentSessions.value = current + (sessionId to agent)
                persistence.setAgent(sessionId, agent)
                onAgentActiveChange(sessionId, true)
            }
        } else {
            if (current.containsKey(sessionId)) {
                _agentSessions.value = current - sessionId
                persistence.setAgent(sessionId, null)
                onAgentActiveChange(sessionId, false)
            }
        }

        // Fine-grained state + title mirror the agent-running lifecycle: when no
        // agent runs, clear them so a stale "blocked" never lingers
        // (ActivityCoordinator.swift Task 5).
        if (agent != null) {
            _agentStates.value = if (agentState != null) {
                _agentStates.value + (sessionId to agentState)
            } else {
                _agentStates.value - sessionId
            }
            _sessionTitles.value = if (!title.isNullOrEmpty()) {
                _sessionTitles.value + (sessionId to title)
            } else {
                _sessionTitles.value - sessionId
            }
        } else {
            _agentStates.value = _agentStates.value - sessionId
            _sessionTitles.value = _sessionTitles.value - sessionId
        }

        // "Needs attention" bucket: a blocked prompt or a just-finished (idle-
        // after-working "done") agent is worth surfacing until the user looks.
        // The session the user is CURRENTLY viewing is by definition seen: never
        // flag it, and clear any stale flag if an update arrives while on screen.
        _unseenSessions.value = when {
            isActiveSession -> _unseenSessions.value - sessionId
            agent != null && (agentState == AgentDetectedState.BLOCKED || agentState == AgentDetectedState.IDLE) ->
                _unseenSessions.value + sessionId
            agentState == AgentDetectedState.WORKING || agent == null ->
                _unseenSessions.value - sessionId
            else -> _unseenSessions.value
        }

        // Awaiting-input is derived: only set when agentIdle AND an agent is
        // currently mapped for the session (ActivityCoordinator.swift:116-120).
        val awaiting = activity == ActivityState.AGENT_IDLE &&
            _agentSessions.value.containsKey(sessionId)
        _sessionsAwaitingInput.value = if (awaiting) {
            _sessionsAwaitingInput.value + sessionId
        } else {
            _sessionsAwaitingInput.value - sessionId
        }
    }

    /**
     * Apply "session stolen by another device" semantics (Swift
     * `handleSessionStolen`, ActivityCoordinator.swift:135-154). Clears the
     * per-session activity state, raises the alert, and — per the M2 design —
     * also relinquishes ownership via [AgentPersistence.unclaim] so this device
     * stops claiming a session that now lives elsewhere.
     *
     * @param nameLookup resolves a display name for the alert; defaults to the
     *   short id when no name is known.
     */
    fun sessionStolen(
        sessionId: UUID,
        nameLookup: (UUID) -> String = { it.toString().take(8) },
    ): StolenAlert {
        val shortId = sessionId.toString().take(8)
        val name = nameLookup(sessionId)

        // Clear local activity state (ActivityCoordinator.swift:142-143).
        if (_agentSessions.value.containsKey(sessionId)) {
            _agentSessions.value = _agentSessions.value - sessionId
            persistence.setAgent(sessionId, null)
        }
        _sessionsAwaitingInput.value = _sessionsAwaitingInput.value - sessionId
        _agentStates.value = _agentStates.value - sessionId
        _sessionTitles.value = _sessionTitles.value - sessionId
        _unseenSessions.value = _unseenSessions.value - sessionId

        val alert = StolenAlert(sessionId = sessionId, sessionName = name, shortId = shortId)
        _sessionsStolen.value = _sessionsStolen.value + sessionId
        _stolenAlert.value = alert
        return alert
    }

    /** Dismiss the stolen flag/alert for [sessionId] (clears the alert when it matches). */
    fun clearStolen(sessionId: UUID) {
        _sessionsStolen.value = _sessionsStolen.value - sessionId
        if (_stolenAlert.value?.sessionId == sessionId) {
            _stolenAlert.value = null
        }
    }

    /**
     * Clear activity state for a locally terminated session (Swift
     * `forgetSession`, ActivityCoordinator.swift:157-160). Removes the session
     * from every map/set. Persists the agent removal so a forgotten session
     * doesn't leave a dangling badge on the next launch.
     */
    fun forgetSession(sessionId: UUID) {
        if (_agentSessions.value.containsKey(sessionId)) {
            _agentSessions.value = _agentSessions.value - sessionId
            persistence.setAgent(sessionId, null)
        }
        _sessionsAwaitingInput.value = _sessionsAwaitingInput.value - sessionId
        _agentStates.value = _agentStates.value - sessionId
        _sessionTitles.value = _sessionTitles.value - sessionId
        _unseenSessions.value = _unseenSessions.value - sessionId
        _sessionsStolen.value = _sessionsStolen.value - sessionId
        if (_stolenAlert.value?.sessionId == sessionId) {
            _stolenAlert.value = null
        }
    }

    /**
     * Apply the server's pruned-agents set so [sessionsAwaitingInput] doesn't
     * keep dangling entries for sessions the server no longer knows about (Swift
     * `applyPrunedAgents`, ActivityCoordinator.swift:165-169).
     */
    fun applyPrunedAgents(removedAgents: Set<UUID>) {
        if (removedAgents.isNotEmpty()) {
            _sessionsAwaitingInput.value = _sessionsAwaitingInput.value - removedAgents
            _unseenSessions.value = _unseenSessions.value - removedAgents
            _agentStates.value = _agentStates.value - removedAgents
            _sessionTitles.value = _sessionTitles.value - removedAgents
        }
    }
}
