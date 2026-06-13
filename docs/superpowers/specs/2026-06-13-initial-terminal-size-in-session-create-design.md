# Initial terminal size in `session_create`

**Date:** 2026-06-13
**Status:** Approved (design)
**Scope:** Wire protocol (Swift + Kotlin), server, iOS + macOS clients, Android client

## Problem

When a new session is created, a stray reverse-video `%` appears on its own
line above the first shell prompt. It reproduces on iOS, macOS, and Android.

The `%` is zsh's `PROMPT_EOL_MARK`. With `PROMPT_SP` enabled (a zsh default),
zsh checks — just before drawing each prompt — whether the previous output
ended exactly at column 0. When it believes it did not, it prints
`PROMPT_EOL_MARK`. On this machine that variable is empty, so zsh falls back to
its default: an inverse-video `%`.

### Root cause

`session_create` carries no terminal geometry. The flow:

1. Client sends `session_create` (name only — no cols/rows).
2. Server forks the PTY at its default **80×24**
   (`SessionManager.createSession(cols: UInt16 = 80, rows: UInt16 = 24)`).
3. zsh starts, lays out its first prompt and the "Last login…" banner
   assuming **80 columns**.
4. The client's real (narrower, phone-width) size arrives only later, as a
   separate `resize` message — *after* zsh has drawn the first prompt.
5. The width mismatch throws off zsh's cursor-column accounting, so its
   `PROMPT_SP` heuristic emits the `%`.

This is platform-agnostic because all three clients send a size-less
`session_create` and rely on a post-create `resize`.

## Approach

Add **optional** `cols`/`rows` to `session_create`. Clients send their
**best-known terminal size**, omitting the fields when no size is known yet.
The server falls back to its existing 80×24 default when the fields are absent.

This is fully backward-compatible: an old client (or a cold-start client with
no measured size) sends no size and behaves exactly as today. A client that
already knows its size — the common case when creating a second session while
another is already on screen — forks the PTY at the correct width and avoids
the first-paint mismatch entirely.

Rejected alternatives:
- *Required fields* — cleanest protocol but breaks older clients and forces
  every caller to have a measured size before creating.
- *Compute size from screen metrics upfront* — duplicates the terminal view's
  sizing math outside the view.
- *Defer create until first layout* — most accurate but adds latency and a
  wait-state to session creation.

## Changes by layer

### 1. Protocol — Swift (`Sources/ClaudeRelayKit/Protocol/ClientMessage.swift`)

- `case sessionCreate(name: String? = nil)`
  → `case sessionCreate(name: String? = nil, cols: UInt16? = nil, rows: UInt16? = nil)`.
- Encode `cols`/`rows` only when non-nil. The `cols`/`rows` `CodingKeys` already
  exist (used by `resize`).
- Decode with `decodeIfPresent`.

### 2. Protocol — Kotlin (`core-protocol/.../ClientMessage.kt`)

- `data class SessionCreate(val name: String? = null, val cols: UShort? = null, val rows: UShort? = null)`.
- Serialize `cols`/`rows` only when present, matching the Swift wire shape.

### 3. Server (`session_create` handler + `SessionManager.createSession`)

- Decode optional cols/rows in the `session_create` handler.
- Pass them through to `createSession(cols:rows:)`. The method already defaults
  to 80×24, so when the handler passes nil the behavior is unchanged. No change
  to PTY spawn logic.

### 4. Swift clients (iOS + macOS — shared via ClaudeRelayClient)

- `SessionController.createSession(name:)`
  → `createSession(name:cols:rows:)`, forwarding into `.sessionCreate(...)`.
- `SharedSessionCoordinator` gains `lastKnownTerminalSize: (cols: UInt16, rows: UInt16)?`,
  updated whenever any `TerminalViewModel.sendResize(cols:rows:)` fires.
- At create time the coordinator passes `lastKnownTerminalSize` if known, else
  omits it. This is the "best-known size" source — no new timing dependency and
  no deferred create.

### 5. Android client

- `WorkspaceViewModel` already routes resizes (`sendResize(cols:rows:)`). Cache
  the last-known cols/rows there and pass them into
  `SessionController.createSession(...)`.

## Why this is safe

- **Backward-compatible**: absent fields → 80×24, exactly today's behavior.
  Old client ↔ new server and new client ↔ old server both interoperate
  (`minProtocolVersion` stays 0).
- **No new race**: the existing post-create `resize` still fires on the first
  layout pass, so correctness never depends on the create-time size. The change
  only removes the *first-paint* mismatch when a size is already known.
- **Self-correcting cold start**: the very first session created before any
  terminal has ever been measured still omits size and relies on resize —
  acceptable and rare.

## Testing

- **Swift protocol**: round-trip `sessionCreate` with and without cols/rows
  through `MessageEnvelope`.
- **Swift coordinator**: `createSession` passes cached `lastKnownTerminalSize`;
  passes nil when none cached.
- **Kotlin protocol**: `MessageEnvelopeTest` round-trip for `SessionCreate`
  with and without size.
- **Server**: `createSession` honors a passed size; falls back to 80×24 when
  nil.
- **Manual**: create a session on each of iOS, macOS, Android; confirm no `%`
  and no first-prompt reflow when a prior session was already sized.
