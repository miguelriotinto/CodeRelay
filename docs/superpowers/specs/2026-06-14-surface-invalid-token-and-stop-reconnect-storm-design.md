# Surface "Invalid token" and stop the reconnect storm

**Date:** 2026-06-14
**Status:** Approved (design)
**Scope:** ClaudeRelayClient (shared), with view bindings in ClaudeRelayApp + ClaudeRelayMac

## Problem

The server already sends `auth_failure(reason: "Invalid token")`
(`RelayMessageHandler.swift:360`) and the client already translates it into
`SessionController.SessionError.authenticationFailed(reason:)`
(`SessionController.swift:90-92`). The failure message exists end-to-end — but
the user never sees it, for two compounding reasons:

1. **The recovery loop masks it as a transient drop.** The *first* failed auth
   returns `auth_failure`. The client retries immediately; by the 5th attempt
   the server's per-IP `RateLimiter` stops sending `auth_failure` and instead
   sends `error 429: Too many failed attempts` then closes the socket. To the
   recovery path that looks like a reconnectable connection drop, so it backs
   off and retries forever (`RecoveryController.swift:176-214`), displaying
   "Reconnecting…" instead of "Invalid token".

2. **The status poller swallows it.** `ServerStatusChecker.probe`
   (`ServerStatusChecker.swift:84-87`) catches *every* error identically and
   returns a blank `ServerStatus()`, so the server-list dot greys out with no
   reason — "server down" and "token rejected" are indistinguishable.

Net effect: a silent, self-inflicted reconnect storm (~1 attempt/second) that
trips the server's rate limiter, with no actionable feedback to the user.

This was diagnosed from live logs showing the loop:
`WebSocket connected → Auth failed — invalid token → ... → rejected: rate-limited`.

## Decisions

- **Keep the socket open, stop retrying** (chosen over full teardown). The
  socket is healthy; only the credential is rejected. Reuses the existing
  application-level-error scaffolding (`isApplicationLevelError` already
  classifies `authenticationFailed` as app-level at `RecoveryController.swift:258`),
  and avoids a disconnect/reconnect cycle when the user fixes the token.
- **Surface the failure in both places** the user looks: the workspace
  (alert/banner with a re-pair action) and the server-list status dot (a
  distinct "Invalid token" indicator).
- **No server changes.** The server-side rate limiter is correct; the storm is
  client-caused and is fixed by halting auto-retry on a known-bad credential.

## Components & Changes

### 1. Halt auto-recovery on auth rejection — `RecoveryController`
`restoreSession` (`RecoveryController.swift:237-274`) already catches
`authenticationFailed` via the app-level-error branch and stops the *current*
pass. The storm comes from `handleForegroundTransition` being re-triggered
repeatedly. Add an immediate, reason-tagged terminal flag (`authRejected`)
that suppresses further auto-recovery — analogous to the existing
`autoRecoverySuspended` breaker, but tripped on the first auth rejection rather
than after N failures. Cleared **only** by a user-initiated re-pair/retry.

### 2. Distinguish token failure in status probe — `ServerStatusChecker`
In `probe` (`ServerStatusChecker.swift:84-87`), catch
`SessionError.authenticationFailed` distinctly and return a status that
encodes it. Introduce a reachability distinction on `ServerStatus`
(e.g. `reachability: .unknown | .live | .invalidToken | .unreachable`, or a
`tokenValid` companion to `isLive`). The server-list view binds to this so the
dot/subtitle can read "Invalid token" instead of generic offline grey.

### 3. Error-message mapping — `SharedSessionCoordinator.friendlyAttachErrorMessage`
Add an `authenticationFailed` case (`:552-568`) returning user-facing copy:
> "Access token rejected. This server's token is no longer valid — edit the
> server to re-pair it."
Wire the workspace banner/alert (`sessionAttachError` / `presentError`) and an
action that opens the Add/Edit server sheet for re-pairing.

## Data Flow

```
auth_failure(reason:"Invalid token")
  → SessionController throws .authenticationFailed
  → RecoveryController.restoreSession catches
      → sets authRejected = true + sessionAttachError (re-pair copy)
      → auto-recovery suspended until user acts
  → UI: workspace banner + re-pair action

(parallel) ServerStatusChecker.probe catches .authenticationFailed
  → ServerStatus(reachability: .invalidToken)
  → server-list dot shows "Invalid token"
```

User-initiated re-pair/retry clears `authRejected` and re-runs auth with the
new token.

## Testing

- `RecoveryController` stops retrying after one `authenticationFailed` (mock
  controller throwing it); `authRejected` is set; a subsequent user-initiated
  retry clears it and re-attempts.
- `ServerStatusChecker.probe` maps `authenticationFailed` → `.invalidToken`
  and other errors → `.unreachable` / blank.
- `friendlyAttachErrorMessage(.authenticationFailed)` returns the re-pair copy.

## Scope Guard (YAGNI)

Out of scope: client-side backoff redesign, token auto-refresh, any server
change, client-side rate limiting. The fix is narrowly: stop auto-retrying on a
known-bad credential, and show why, in the two surfaces the user consults.
