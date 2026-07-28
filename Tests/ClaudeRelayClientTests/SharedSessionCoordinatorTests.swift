import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class SharedSessionCoordinatorTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsClean() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        XCTAssertFalse(coordinator.isRecovering)
        XCTAssertFalse(coordinator.recoveryFailed)
        XCTAssertFalse(coordinator.connectionTimedOut)
        XCTAssertFalse(coordinator.showSessionStolen)
        XCTAssertFalse(coordinator.sessionAttachFailed)
        XCTAssertNil(coordinator.activeSessionId)
        XCTAssertNil(coordinator.sessionController)
        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertTrue(coordinator.terminalViewModels.isEmpty)
        XCTAssertFalse(coordinator.isTornDown)
        XCTAssertFalse(coordinator.isLoading)
    }

    // MARK: - Tear Down

    func testTearDownSetsFlag() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.tearDown()

        XCTAssertTrue(coordinator.isTornDown)
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testTearDownClearsTerminalCaches() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.registerLiveTerminal(for: sessionId, view: NSObject())

        coordinator.tearDown()

        XCTAssertTrue(coordinator.terminalCache.cachedIds.isEmpty)
    }

    func testTearDownCancelsRecoveryTask() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(100)) }
        coordinator.recoveryTask = task

        coordinator.tearDown()

        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - C-19: auto-recovery breaker reset

    func testHealthyPingResetsAutoRecoveryBreaker() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        // Force the breaker into the suspended state.
        coordinator._testOnly_setAutoRecoverySuspended(true, failures: 3)
        XCTAssertTrue(coordinator._testOnly_autoRecoverySuspended)
        XCTAssertEqual(coordinator._testOnly_consecutiveAutoRecoveryFailures, 3)

        // A single healthy ping must clear both flags.
        connection._testOnly_recordRTT(rtt: 0.05)

        // The breaker reset is dispatched via Task { @MainActor }; wait briefly.
        let exp = expectation(description: "breaker reset")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(coordinator._testOnly_autoRecoverySuspended)
        XCTAssertEqual(coordinator._testOnly_consecutiveAutoRecoveryFailures, 0)
    }

    func testHealthyPingWithIdleBreakerIsNoop() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        // Breaker starts idle — healthy ping should do nothing observable.
        XCTAssertFalse(coordinator._testOnly_autoRecoverySuspended)
        connection._testOnly_recordRTT(rtt: 0.05)

        let exp = expectation(description: "noop")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(coordinator._testOnly_autoRecoverySuspended)
        XCTAssertEqual(coordinator._testOnly_consecutiveAutoRecoveryFailures, 0)
    }

    // MARK: - Cancel Recovery

    func testCancelRecoverySetsCorrectState() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.cancelRecovery()

        XCTAssertFalse(coordinator.isRecovering)
        XCTAssertTrue(coordinator.recoveryFailed)
    }

    func testCancelRecoveryCancelsInFlightTask() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(100)) }
        coordinator.recoveryTask = task

        coordinator.cancelRecovery()

        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - Recovery Phase Labels

    func testRecoveryPhaseLabels() {
        XCTAssertFalse(SharedSessionCoordinator.RecoveryPhase.reconnecting.label.isEmpty)
        XCTAssertFalse(SharedSessionCoordinator.RecoveryPhase.authenticating.label.isEmpty)
        XCTAssertFalse(SharedSessionCoordinator.RecoveryPhase.resuming.label.isEmpty)
    }

    // MARK: - Session Names

    func testNameFallsBackToShortId() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let name = coordinator.name(for: sessionId)
        XCTAssertEqual(name, String(sessionId.uuidString.prefix(8)))
    }

    func testSetNameStoresLocally() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.setName("Rhaegar", for: sessionId)
        XCTAssertEqual(coordinator.name(for: sessionId), "Rhaegar")
    }

    // MARK: - Active Sessions Filter

    /// The pane renders the server's token-scoped `sessions` directly, minus
    /// terminal sessions. There is no local owned-set filter — the server list
    /// IS the ownership boundary.
    func testActiveSessionsDropsOnlyTerminal() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let attached = UUID()
        let detached = UUID()
        let terminated = UUID()

        coordinator.sessions = [
            SessionInfo(id: attached, name: nil, state: .activeAttached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24),
            SessionInfo(id: detached, name: nil, state: .activeDetached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24),
            SessionInfo(id: terminated, name: nil, state: .terminated, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24)
        ]

        let active = coordinator.activeSessions
        XCTAssertEqual(Set(active.map { $0.id }), [attached, detached],
                       "Pane shows all non-terminal server sessions; no local owned filter")
    }

    // MARK: - Activity Tracking

    func testAgentSessionTracking() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        XCTAssertFalse(coordinator.isRunningAgent(sessionId: sessionId))
        XCTAssertNil(coordinator.activeAgent(for: sessionId))

        coordinator.agentSessions[sessionId] = "claude"
        XCTAssertTrue(coordinator.isRunningAgent(sessionId: sessionId))
        XCTAssertEqual(coordinator.activeAgent(for: sessionId), "claude")

        coordinator.agentSessions[sessionId] = "codex"
        XCTAssertEqual(coordinator.activeAgent(for: sessionId), "codex")
    }

    // MARK: - Terminal View Cache

    func testRegisterLiveTerminal() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let view = NSObject()
        coordinator.registerLiveTerminal(for: sessionId, view: view)

        XCTAssertNotNil(coordinator.cachedTerminalView(for: sessionId))
    }

    func testEvictTerminalClearsAllState() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.registerLiveTerminal(for: sessionId, view: NSObject())
        coordinator.terminalViewModels[sessionId] = TerminalViewModel(sessionId: sessionId, connection: connection)

        coordinator.evictTerminal(for: sessionId)

        XCTAssertNil(coordinator.cachedTerminalView(for: sessionId))
        XCTAssertNil(coordinator.viewModel(for: sessionId))
    }

    // MARK: - Present Error

    func testPresentErrorSetsFlags() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.presentError("Something went wrong")

        XCTAssertEqual(coordinator.errorMessage, "Something went wrong")
        XCTAssertTrue(coordinator.showError)
    }

    // MARK: - Recovery Prevents Operations

    func testCreateNewSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        await coordinator.createNewSession()

        XCTAssertNil(coordinator.activeSessionId)
    }

    func testSwitchToSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        await coordinator.switchToSession(id: UUID())

        XCTAssertNil(coordinator.activeSessionId)
    }

    func testTerminateSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        let sessionId = UUID()
        coordinator.activeSessionId = sessionId

        await coordinator.terminateSession(id: sessionId)

        // activeSessionId should not have been cleared by the terminate (it was blocked)
        XCTAssertEqual(coordinator.activeSessionId, sessionId)
    }

    func testAttachRemoteSessionBlockedDuringRecovery() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.isRecovering = true
        await coordinator.attachRemoteSession(id: UUID(), serverName: nil)

        XCTAssertNil(coordinator.activeSessionId)
    }

    // MARK: - Foreground Transition on Torn Down Coordinator

    func testHandleForegroundAfterTearDownIsNoOp() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.tearDown()
        await coordinator.handleForegroundTransition()

        XCTAssertFalse(coordinator.isRecovering)
    }

    // MARK: - User Recovery After Tear Down

    func testTriggerUserRecoveryAfterTearDownIsNoOp() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        coordinator.tearDown()
        coordinator.triggerUserRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    // MARK: - Session Stolen Handling

    func testSessionStolenNotificationClearsActiveSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.activeSessionId = sessionId
        coordinator.sessionNames[sessionId] = "TestSession"
        coordinator.agentSessions[sessionId] = "claude"
        coordinator.sessionsAwaitingInput.insert(sessionId)

        connection.onSessionStolen?(sessionId)

        // Give the Task a chance to run (it dispatches back to MainActor)
        let exp = expectation(description: "stolen callback dispatched")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertNil(coordinator.activeSessionId)
        XCTAssertTrue(coordinator.showSessionStolen)
        XCTAssertEqual(coordinator.stolenSessionName, "TestSession")
        XCTAssertNil(coordinator.agentSessions[sessionId])
        XCTAssertFalse(coordinator.sessionsAwaitingInput.contains(sessionId))
    }

    /// A session attached by another client (server `session_stolen` push) must
    /// drop out of the pane (`sessions`), suppress its terminal VM, forget its
    /// activity, and raise the "attached by another client" alert — while
    /// leaving other sessions untouched.
    func testSessionStolenRemovesFromPane() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let stolenId = UUID()
        let keepId = UUID()

        coordinator.activeSessionId = stolenId
        coordinator.sessions = [
            SessionInfo(id: stolenId, name: nil, state: .activeAttached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24),
            SessionInfo(id: keepId, name: nil, state: .activeAttached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24)
        ]
        coordinator.agentSessions[stolenId] = "claude"
        coordinator.sessionsAwaitingInput.insert(stolenId)
        let stolenVM = TerminalViewModel(sessionId: stolenId, connection: connection)
        coordinator.terminalViewModels[stolenId] = stolenVM

        XCTAssertTrue(coordinator.activeSessions.contains(where: { $0.id == stolenId }))

        connection.onSessionStolen?(stolenId)
        let exp = expectation(description: "stolen callback dispatched")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(coordinator.sessions.contains(where: { $0.id == stolenId }),
                       "Stolen session must be dropped from the pane source")
        XCTAssertFalse(coordinator.activeSessions.contains(where: { $0.id == stolenId }))
        XCTAssertNil(coordinator.agentSessions[stolenId])
        XCTAssertFalse(coordinator.sessionsAwaitingInput.contains(stolenId))
        XCTAssertTrue(stolenVM.isSendingSuppressed, "VM for stolen session must suppress sends")
        XCTAssertTrue(coordinator.showSessionStolen, "popup must fire")

        // The other session is untouched.
        XCTAssertTrue(coordinator.activeSessions.contains(where: { $0.id == keepId }))
    }

    /// A non-active session attached by another client (sitting in the sidebar,
    /// not the focused tab) must also disappear immediately AND raise the alert.
    func testSessionStolenNonActiveStillRemovesAndAlerts() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let stolenId = UUID()      // shown in sidebar, NOT active
        let activeId = UUID()      // the session the user is actually looking at

        coordinator.activeSessionId = activeId
        coordinator.sessions = [
            SessionInfo(id: stolenId, name: nil, state: .activeDetached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24),
            SessionInfo(id: activeId, name: nil, state: .activeAttached, tokenId: "t1", createdAt: Date(), cols: 80, rows: 24)
        ]

        XCTAssertTrue(coordinator.activeSessions.contains(where: { $0.id == stolenId }))

        connection.onSessionStolen?(stolenId)
        let exp = expectation(description: "stolen callback dispatched")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(coordinator.activeSessions.contains(where: { $0.id == stolenId }))
        XCTAssertTrue(coordinator.showSessionStolen)
        // The active session the user is looking at is untouched.
        XCTAssertEqual(coordinator.activeSessionId, activeId)
        XCTAssertTrue(coordinator.activeSessions.contains(where: { $0.id == activeId }))
    }

    // MARK: - Session Renamed Handling

    func testSessionRenamedUpdatesLocalName() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        coordinator.sessionNames[sessionId] = "OldName"

        connection.onSessionRenamed?(sessionId, "NewName")

        let exp = expectation(description: "rename callback dispatched")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(coordinator.sessionNames[sessionId], "NewName")
    }

    // MARK: - Last-Known Terminal Size

    func testResizeUpdatesLastKnownTerminalSize() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
        coordinator.terminalViewModels[sessionId] = vm
        coordinator.wireTerminalOutput(to: sessionId)

        XCTAssertNil(coordinator.lastKnownTerminalSize)

        vm.sendResize(cols: 100, rows: 30)

        XCTAssertEqual(coordinator.lastKnownTerminalSize?.cols, 100)
        XCTAssertEqual(coordinator.lastKnownTerminalSize?.rows, 30)
    }

    // MARK: - ViewModel Access

    func testViewModelReturnsNilForUnknownSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        XCTAssertNil(coordinator.viewModel(for: UUID()))
    }

    func testCreatedAtReturnsNilForUnknownSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        XCTAssertNil(coordinator.createdAt(for: UUID()))
    }

    func testCreatedAtReturnsDateForKnownSession() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")

        let sessionId = UUID()
        let now = Date()
        coordinator.sessions = [
            SessionInfo(id: sessionId, name: nil, state: .activeAttached, tokenId: "t", createdAt: now, cols: 80, rows: 24)
        ]

        XCTAssertEqual(coordinator.createdAt(for: sessionId), now)
    }

    // MARK: - Friendly Attach Error Message

    func testFriendlyMessageForAuthenticationFailed() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")
        let err = SessionController.SessionError.authenticationFailed(reason: "Invalid token")
        let message = coordinator.friendlyAttachErrorMessage(err)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("token"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("re-pair"))
    }

    // MARK: - Live workingDir patch (Codex PR #29 finding 2, client half)

    func testActivityEventPatchesCachedSessionWorkingDir() async {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")
        let id = UUID()
        coordinator.sessions = [SessionInfo(
            id: id, name: "s", state: .activeAttached, tokenId: "test-token",
            createdAt: Date(), cols: 80, rows: 24, activity: .agentActive,
            agent: "claude", agentState: .working, title: nil, workingDir: "/repo/old")]

        // Simulate a live activity push carrying a new cwd (as after `cd`).
        // The coordinator's handler hops through a Task { @MainActor }, so yield
        // before asserting.
        connection.onSessionActivity?(id, .agentActive, "claude", .working, nil, "/repo/new")
        for _ in 0..<10 where coordinator.sessions.first?.workingDir != "/repo/new" {
            await Task.yield()
        }

        // The cached SessionInfo must be patched so the grouped sidebar regroups
        // without waiting for a full session-list refetch.
        XCTAssertEqual(coordinator.sessions.first?.workingDir, "/repo/new")
    }

    // MARK: - Reconcile (server is authoritative for ownership)

    private func session(_ id: UUID, token: String = "t1", state: SessionState = .activeDetached) -> SessionInfo {
        SessionInfo(id: id, name: nil, state: state, tokenId: token, createdAt: Date(), cols: 80, rows: 24)
    }

    /// The pane is the server's token-scoped list, verbatim. reconcile() assigns
    /// `sessions = tokenScoped`; there is no local owned set that could drift and
    /// blank the pane on relaunch. THE core guarantee behind the redesign.
    func testReconcileRendersServerListDirectly() {
        let coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        let a = UUID(), b = UUID()

        coordinator.reconcile(tokenScoped: [session(a, state: .activeAttached), session(b)])

        XCTAssertEqual(Set(coordinator.sessions.map { $0.id }), [a, b])
        XCTAssertEqual(Set(coordinator.activeSessions.map { $0.id }), [a, b],
                       "Every non-terminal session the server lists under this token shows in the pane")
    }

    /// Relaunch shape: a fresh coordinator (no in-memory state, nothing persisted
    /// about ownership) shows exactly what the server returns for this token.
    /// This is the scenario that kept regressing — now it can't, because there is
    /// no persisted owned set to be missing.
    func testReconcileOnFreshCoordinatorShowsOwnedSessions() {
        let coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        let attached = UUID()

        // Simulate the first post-launch fetch returning our attached session.
        coordinator.reconcile(tokenScoped: [session(attached, state: .activeAttached)])

        XCTAssertTrue(coordinator.activeSessions.contains { $0.id == attached },
                      "A session the server lists under this token appears on relaunch with no local persistence")
    }

    /// A session absent from the server's token-scoped list simply isn't shown —
    /// no reconciliation, no popup. (Cleanup of a live takeover is the
    /// session_stolen path, tested separately.)
    func testReconcileDropsSessionsAbsentFromServerList() {
        let coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        let gone = UUID(), present = UUID()

        coordinator.reconcile(tokenScoped: [session(gone), session(present)])
        XCTAssertEqual(coordinator.sessions.count, 2)

        // Next fetch: `gone` is no longer under our token.
        coordinator.reconcile(tokenScoped: [session(present)])

        XCTAssertEqual(coordinator.sessions.map { $0.id }, [present])
        XCTAssertFalse(coordinator.activeSessions.contains { $0.id == gone })
        XCTAssertFalse(coordinator.showSessionStolen, "a plain list refresh must not raise the takeover popup")
    }

    /// reconcile evicts stale terminal VMs / cached views for sessions the server
    /// no longer lists (the bookkeeping the removed claim/unclaim path used to do).
    func testReconcileEvictsStaleTerminalState() {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "t1")
        let stale = UUID()
        coordinator.terminalViewModels[stale] = TerminalViewModel(sessionId: stale, connection: connection)

        coordinator.reconcile(tokenScoped: [session(UUID())])

        XCTAssertNil(coordinator.terminalViewModels[stale], "VM for a no-longer-listed session must be evicted")
    }

    /// Regression (found in review): reconcile must forget ALL activity state
    /// (agent, awaiting-input, agentState, title, unseen) for a session the
    /// server no longer lists. A buggy prune-then-diff ordering made the
    /// forget-set always empty, leaking stale activity.
    func testReconcileForgetsStaleActivityState() {
        let coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        let gone = UUID()
        // Populate all five activity buckets that forgetSession clears.
        coordinator.agentSessions[gone] = "claude"
        coordinator.sessionsAwaitingInput.insert(gone)
        coordinator.activityCoordinator.agentStates[gone] = .working
        coordinator.activityCoordinator.sessionTitles[gone] = "old title"
        coordinator.activityCoordinator.unseenSessions.insert(gone)

        // `gone` is absent from the new server list.
        coordinator.reconcile(tokenScoped: [session(UUID())])

        XCTAssertNil(coordinator.agentSessions[gone], "stale agent must be forgotten")
        XCTAssertFalse(coordinator.sessionsAwaitingInput.contains(gone), "stale awaiting-input cleared")
        XCTAssertNil(coordinator.activityCoordinator.agentStates[gone], "stale agentState cleared")
        XCTAssertNil(coordinator.activityCoordinator.sessionTitles[gone], "stale title cleared")
        XCTAssertFalse(coordinator.activityCoordinator.unseenSessions.contains(gone), "stale unseen cleared")
    }

    /// F3 active-tab restore only considers NON-TERMINAL sessions the server
    /// lists (a terminal id would error in resumeSession). With only a terminal
    /// session present, reconcile must not auto-select an active tab.
    func testReconcileDoesNotRestoreTerminalActiveTab() {
        let coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        // Persist a focused id via the setter, then clear it so the F3 restore
        // branch (`activeSessionId == nil`) is eligible on the next reconcile.
        let terminalId = UUID()
        coordinator.activeSessionId = terminalId
        coordinator.activeSessionId = nil

        coordinator.reconcile(tokenScoped: [session(terminalId, state: .terminated)])

        XCTAssertNil(coordinator.activeSessionId, "must not restore a terminal session as the active tab")
    }

}
