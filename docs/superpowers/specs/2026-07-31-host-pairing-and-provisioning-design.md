# Host Pairing & Remote Provisioning (herdr F11, second half)

**Date:** 2026-07-31
**Spec item:** herdr F11 — "host auto-provision" (the deferred half of
`docs/herdr-feature-spec.md` §F11)
**Platforms:** Server + CLI + iOS + macOS + Android
**Status:** Approved for implementation

## Context: this closes the herdr spec

`docs/herdr-feature-spec.md` selected six features. Five and a half have shipped:

| # | Feature | State |
| --- | --- | --- |
| F1 | Push notifications | shipped (`468408b`, Android FCM `397c3cf`) |
| F2 | Workspace status rollups | shipped |
| F5 | Broader agent support | shipped — `copilot.json`, `cursor-agent.json`, `droid.json` |
| F6 | Hook-based state authority | shipped (`b8d9055`, #33) |
| F3 | Session/layout persistence | shipped (`bab1da3`, #34) |
| F11 | Clipboard bridging | shipped (`43d22a7`, #35) — **clipboard half only** |

F11's second half was deliberately deferred as "exploratory within P2". Its
acceptance bar is: *provisioning a fresh host requires materially fewer manual
steps than today.* This spec is that work, and it is the last open item in the
herdr spec.

## The problem, measured

Cold-start today, pairing a phone to a Mac:

1. `brew install miguelriotinto/claude-relay/clauderelay`
2. `brew services start clauderelay`
3. **Find the Mac's LAN IP** — documented nowhere in `README.md` or `docs/`.
4. `claude-relay token create --label iphone`
5. On the phone: Add Server → name, host, port, **hand-type a long random
   token**, TLS toggle.
6. *Optional* F6 hook: `mkdir` / `cp` / `chmod`, then hand-merge four event
   entries into `~/.claude/settings.json`.
7. *Optional* push: several `config set` calls.

Steps 3, 5 and 6 are the real friction. Step 5 is where people give up —
typing a secret on a phone keyboard.

## What we build

Two phases, sequenced. Each gets its own implementation plan.

- **Phase 1 — Pairing.** `claude-relay setup` renders a QR code; the phone
  scans it and is connected. Collapses steps 3–5 into one scan, and step 6
  into one command. Also makes the CLI **service-manager aware**, fixing a
  pre-existing bug where `start`/`stop`/`restart`/`unload` fail outright on a
  Homebrew-managed host.
- **Phase 2 — Remote provisioning.** `claude-relay provision user@host`
  installs and starts the relay on another machine over SSH, optionally ending
  in a pairing QR for that remote host. This is the `--remote <host>` shape
  herdr's thin client offers.

### Explicitly out of scope

- No push configuration automation (`setup` never touches APNs/FCM keys).
- No changes to the existing session-sharing QR (`clauderelay://session/<uuid>`).
- No mDNS/Bonjour *discovery* of relay hosts from the app. `setup` uses the
  Bonjour *hostname* as an address; it does not advertise or browse a service.

---

# Phase 1 — Pairing

## Pairing secret: a one-time code, not the token

The QR carries a **short-lived single-use pairing code**, not the auth token.
The phone exchanges the code over the WebSocket for a freshly minted per-device
token.

Rejected alternative: embedding the live token directly in the QR. That needs
no new wire protocol and no server state, but it renders a long-lived bearer
token into terminal scrollback and into any screenshot or screen-share of that
moment, where it stays valid until manually rotated. The code exchange costs one
new message pair and buys: nothing durable in scrollback, a secret that is
useless after use or expiry, and a typeable fallback for when the camera won't
cooperate.

### `PairingCodeStore` (new server actor)

In-memory only, **never persisted** — a pairing code surviving a server restart
is a liability, and codes live five minutes.

```
mint(label:ttl:) -> (code: String, expiresAt: Date)
redeem(code:)    -> PairingGrant?     // single-use: removed on success
```

- **Code format:** 8 characters of Crockford Base32 = **40 bits**. Crockford's
  alphabet excludes `I`, `L`, `O`, `U`, so there is no `0`/`O` or `1`/`l`
  ambiguity when a user reads the code off a screen and types it. Displayed
  grouped as `K7QP-2M4X`; the hyphen is presentation only and is stripped on
  input.
- **Randomness:** `SystemRandomNumberGenerator` (CSPRNG), rejection-sampled to
  avoid modulo bias across the 32-symbol alphabet.
- **TTL:** 5 minutes, default; `--ttl` overrides.
- **Cap:** 8 pending codes, bounding both memory and the brute-force surface.
  Minting past the cap evicts the oldest. Expired entries are swept on access
  (no timer needed).

**One shared instance, and no defaulted parameter.** `RelayMessageHandler` and
`WebSocketServer` take `pushStore:` with a default value
(`= PushRegistrationStore(directory:)`), which is harmless there because that
store is disk-backed so separate instances converge on the same file.
`PairingCodeStore` is **in-memory**, so a defaulted parameter would give every
WebSocket connection its own empty store and no code minted via the admin route
would ever be redeemable. It must therefore be constructed once in `main.swift`
and injected — with **no default** — into `AdminRoutes.handle`, `WebSocketServer`
and `RelayMessageHandler`, so the compiler refuses any call site that forgets it.

### Minting path

The CLI has no access to server state, so minting goes through the existing
admin surface rather than a side channel:

`CLI` → `POST /pair/create` (localhost-only, 64 KB body cap, same as every other
admin route) → server mints in `PairingCodeStore` → `{code, expiresAt, host,
port, tls}`.

The CLI only *renders*. The server owns the secret. This matches how every other
CLI command already works (`AdminClient`, 10 s timeout, 127.0.0.1 only).

### Wire protocol

Two new messages. Type strings are unique across both `ClientMessage.allTypeStrings`
and `ServerMessage.allTypeStrings`, per the envelope decoder's requirement.

| Direction | Type string | Payload |
| --- | --- | --- |
| client → server | `pair_request` | `code`, `deviceName`, `platform` |
| server → client | `pair_success` | `token`, `tokenId`, `label` |

Failures reuse `ServerMessage.error`:

| Code | Meaning |
| --- | --- |
| 401 | invalid, expired, or already-redeemed code |
| 429 | rate-limited (IP over the failure threshold) |

### The handshake

One socket, strictly sequential. There is **no request-id correlation on the
wire**, so only one RPC may be in flight per connection — this sequence must
never overlap its steps (see #44, which made `connect→auth→list` one
uninterruptible handshake).

```
client ──connect──► server                      (10 s auth timer arms)
       ──► pair_request{code, deviceName, platform}
       ◄── pair_success{token, tokenId, label}     ← TokenStore.create(label:)
       ──► auth_request{token, protocolVersion}    ← isAuthenticated = true,
       ◄── auth_success{tokenId, protocolVersion}     auth timer cancelled
       ──► session_list
       ◄── session_list_result
```

Three properties make this fit the existing server rather than bolt onto it:

1. **The 10 s auth timer is reused as the pairing deadline.** Pairing lives
   entirely pre-auth (`RelayMessageHandler` line ~95 closes any socket where
   `isAuthenticated` is still false at 10 s), so a stalled pairing is reaped by
   machinery that already exists. Two LAN round trips inside 10 s is
   comfortable. The timer is **not** reset by a successful pair — pair *and*
   auth must complete within the one window.
2. **A bad code is a `rateLimiter.recordFailure(ip:)`,** identical to a bad
   token, so brute force inherits the existing cross-connection lockout with
   zero new policy code — **10 attempts / 60 s rolling**, as `main.swift`
   constructs it (`RateLimiter(maxAttempts: 10, windowSeconds: 60)`; the type's
   own default of 5 is not what ships). A per-connection cap mirrors
   `maxAuthAttempts = 3`: three bad codes closes that socket. 40 bits behind a
   10-attempt-per-minute lockout in a 5-minute window is not a realistic target.
3. **`pair_request` is one new `case` in the existing
   `handleUnauthenticatedMessage` switch,** which already has a `default:` →
   401 "Not authenticated" branch. It is not a new pre-auth surface; it is one
   more arm of an existing one.

### Minted token is auditable

The token is created with `TokenStore.create(label:)` using the device name —
`"Miguel's iPhone (paired)"`. It therefore appears in `claude-relay token list`
and is revocable per-device via `claude-relay token delete`. Pairing produces
auditable per-device credentials rather than a shared secret.

### Trust boundary, stated plainly

Over plain `ws://` on a LAN, both the pairing code and the returned token travel
in the clear. This is **exactly** as exposed as today's flow, where the user
types a token into an app that then sends it in cleartext over the same socket.
There is no regression, and TLS (`wss://`) remains the answer for anything
off-LAN. Documented rather than left implicit.

## CLI: `claude-relay setup`

```
$ claude-relay setup
✓ service running (ws 9200, admin 9100)
✓ host: silverwing.local  (Bonjour — survives DHCP, ATS-safe)

  ▄▄▄▄▄▄▄ ▄▄  ▄ ▄▄▄▄▄▄▄
  █ ▄▄▄ █ ▀█▄▀█ █ ▄▄▄ █      scan in CodeRelay
  █ ███ █ █ ▄▄▄ █ ███ █      or enter code:  K7QP-2M4X
  █▄▄▄▄▄█ ▀▄█▀▄ █▄▄▄▄▄█      expires in 4:58

Optional: claude-relay hook install    (authoritative Claude Code state)
```

Flow:

1. Health-check the admin API. If down, start the service **via whichever
   manager already owns it** (see below). An already-running service is never
   touched or restarted.
2. Select the host address (see below).
3. `POST /pair/create`.
4. Render the QR, the grouped code, and the expiry.

### Service-manager awareness (a pre-existing live bug, fixed here)

There are **two independent launchd managers** for this server:

| Manager | Plist / label |
| --- | --- |
| Homebrew services | `homebrew.mxcl.clauderelay` |
| `claude-relay load` | `com.claude.relay` |

Every service command hardcodes `serviceLabel = "com.claude.relay"` and calls
`launchctl` blindly, and `runLaunchctl` throws on a nonzero exit. On a Homebrew
install — **the documented path**, and how this dev machine actually runs
(`launchctl list` shows only `homebrew.mxcl.clauderelay`, pid 82071;
`com.claude.relay` is absent) — that means:

- `claude-relay start` / `stop` / `restart` / `unload` **fail today** with a raw
  `launchctl failed: …` error, because they target a label that was never
  loaded.
- `status` / `health` work, because they talk to the admin HTTP API rather than
  launchctl.

Meanwhile `CLAUDE.md` instructs "always use CLI, never run the server binary
directly or pkill." The documentation points users at commands that are broken on
the documented install path. This is a pre-existing bug, independent of pairing,
and it is fixed as part of this work because `setup` cannot start a service
correctly without solving it.

#### `ServiceManagerDetector` (new, CLI)

One shared read-only detector, used by every service command:

```
enum ServiceOwner {
    case homebrew      // homebrew.mxcl.clauderelay.plist present
    case launchAgent   // com.claude.relay.plist present
    case both          // misconfigured: two managers for one port
    case none          // not installed as a service
}
```

Detection inputs, all read-only (no `launchctl` mutation to probe state):
plist presence for each label, plus — to nudge about the *installer* — whether
the running CLI binary sits under a Homebrew prefix (`/opt/homebrew`,
`/usr/local`) or in a local `.build/`.

#### Behaviour: nudge with the correct command, never silently do the wrong thing

| Command | `.homebrew` | `.launchAgent` | `.both` | `.none` |
| --- | --- | --- | --- | --- |
| `load` | **refuse**, nudge `brew services start clauderelay` (`--force` overrides) | proceed (reinstall plist) | **refuse**, nudge cleanup | proceed |
| `start` / `stop` / `restart` | nudge `brew services <verb> clauderelay`; do **not** call launchctl | proceed | nudge, naming both owners | nudge: not installed → `claude-relay setup` |
| `unload` | nudge `brew services stop clauderelay`; explain `unload` only removes the CLI-installed agent | proceed | proceed on the CLI agent, warn Homebrew's remains | nothing to do |
| `status` / `health` | works; **additionally reports the owning manager** | same | warn: two managers | — |
| `setup` (step 1) | `brew services start clauderelay` | `claude-relay start` | refuse until resolved | `load` |

Two deliberate choices:

1. **Nudge, don't auto-delegate.** `claude-relay stop` on a Homebrew-managed host
   prints the `brew services stop clauderelay` command rather than shelling out
   to brew on the user's behalf. A command that documents itself as driving
   launchctl silently invoking Homebrew is surprising, and the nudge teaches the
   right tool for next time.
2. **`load` refuses rather than warns.** Every other command's mistake is
   recoverable, but `load` on a Homebrew-managed host *creates* the corrupt
   two-manager state. `--force` remains for anyone who genuinely wants both.

`--json` output includes the detected owner so scripts can branch on it, and all
nudges respect `--quiet`.

If the health check still fails after starting, `setup` reports the failure and
points at `claude-relay logs show` rather than emitting a QR for a dead server.

Flags: `--host` (override the selection), `--no-qr` (dumb terminals — prints the
URL and code only), `--json` (machine-readable; required by phase 2), `--ttl`.

`setup` is additive. `load`, `token create` and the documented manual path all
keep working unchanged.

### Host selection policy

`setup` must choose the address that goes into the QR. Ordering, with rationale:

1. **`scutil --get LocalHostName` → `<name>.local`** — preferred. Survives DHCP
   lease changes, and `.local` is inside the apps' `NSAllowsLocalNetworking`
   ATS allowlist, so plain `ws://` works with no TLS.
2. **`ipconfig getifaddr en0`** (RFC1918 literal) — fallback when the Bonjour
   name does not resolve. Works, but goes stale when the lease changes.
3. **`127.0.0.1`** — last resort; only useful for a Mac pairing to itself.

A Tailscale CGNAT address (`100.64/10`) is **never** selected silently: ATS has
no CIDR allowlist, so plaintext `ws://` to it is blocked by Apple at the platform
layer and it requires `wss://`. If the only available address is CGNAT, `setup`
says so and points at TLS configuration rather than emitting a QR that cannot
connect.

### `TerminalQRRenderer`

A pure value type: payload → module matrix → half-block rows. No new dependency
— `CIFilter(name: "CIQRCodeGenerator")` is a system framework and works in a
plain command-line executable (verified: a 70-character pairing URL at
correction level `M` yields a 39×39 module matrix, one pixel per module).

- 39 modules + a 2-module quiet zone = **43 columns × 22 rows** using half-block
  glyphs (`▀` `▄` `█` space), which fits an 80×24 terminal.
- Emits **explicit 24-bit foreground/background SGR** rather than inheriting the
  terminal theme. A dark-theme terminal would otherwise invert the modules, and
  most scanners fail on an inverted QR — this is the most common way terminal QR
  codes break.
- `--no-qr` skips rendering entirely for terminals that cannot show it.

### CLI: `claude-relay hook install`

Separate command, idempotent, replacing the ~8 hand-run commands and the JSON
hand-merge in `Scripts/hooks/README.md`:

1. Copy `claude-relay-state-hook.sh` to `~/.claude-relay/hooks/`, `chmod +x`.
2. Back up `~/.claude/settings.json`.
3. Merge **only the missing** event entries (`UserPromptSubmit`, `PreToolUse`,
   `Notification`, `Stop`) — never clobber or duplicate existing hooks.
4. `--dry-run` prints the diff without writing.

`hook uninstall` reverses it. Push configuration stays manual — `setup` and
`hook` only touch files CodeRelay already owns, plus `~/.claude/settings.json`
under an explicit, backed-up, opt-in command.

## Clients

### `PairingURL` (shared, in `ClaudeRelayKit`)

Parses and validates `clauderelay://pair?host=&port=&tls=&code=`. Pure and
testable: host sanity, port range, code charset and length. Rejecting a
malformed or hostile QR belongs in one tested place, not replicated across three
UI layers.

### `PairingController` (in `ClaudeRelayClient`)

Takes a validated `PairingURL`:

1. Open a `RelayConnection` to the host/port.
2. Send `pair_request`; await `pair_success`.
3. Persist: `SavedConnectionStore.add(config)` +
   `AuthManager.saveToken(token, for: config.id)`.
4. Hand off to the normal connect path.

Steps 3–4 are exactly what `AddEditServerViewModel.save()` already does.
Pairing fills that form from a scan instead of a keyboard; it does not introduce
a second way to persist a server.

Error surfaces: invalid/expired code, rate-limited, host unreachable, and TLS
required (CGNAT/public host without `wss://`) each get a distinct, actionable
message.

### Entry points

| Platform | Entry points |
| --- | --- |
| iOS | Camera scanner on `ServerListView` + "Enter code" sheet |
| Android | CameraX/MLKit scanner + "Enter code" sheet |
| macOS | "Enter code" sheet only |

macOS gets no camera scanner: a Mac is normally the *host*, and the typed-code
path covers the rare Mac-pairing-to-another-Mac case without pulling capture
machinery into the macOS target.

Deep-link routing gains a `pair` route alongside the existing
`session/<uuid>`, reusing `handleDeepLink`.

**Android dependency check:** confirm during implementation whether the Android
app already has a barcode-scanning dependency. If not, prefer CameraX + MLKit
barcode scanning; if that is too heavy, the typed-code path ships first and the
scanner follows.

---

# Phase 2 — `claude-relay provision user@host`

Installs and starts the relay on another machine over SSH.

Driven by the **`ssh` subprocess**, deliberately not a Swift SSH library: the
user's existing `~/.ssh/config`, agent, keys and `ProxyJump` all work for free,
with no new dependency and no new crypto surface.

1. **Preflight:** `ssh -o BatchMode=yes user@host true`. Fails fast with
   guidance if key auth is not set up — never silently prompts for a password.
2. **Detect:** existing `claude-relay` install, Homebrew presence, architecture.
3. **Install:** `brew install miguelriotinto/claude-relay/clauderelay`, or
   upgrade if already present.
4. **Start:** start the service remotely using the same service-manager
   resolution as `setup` (Homebrew-installed hosts get `brew services start`,
   never `load`).
5. **Verify:** remote `claude-relay health`.
6. **`--pair`:** run `setup --json --no-qr` remotely, capture the code, and
   render the QR **locally** with the remote host substituted — so provisioning
   a fresh box ends in a scannable code.

Constraints: idempotent (safe to re-run), never uses `sudo`, and `--dry-run`
prints the exact remote command list. The command list is produced by a **pure
function**, so it is testable without any SSH.

---

## Testing

| Area | Tests |
| --- | --- |
| `PairingCodeStore` | mint; redeem; single-use (second redeem fails); expiry; cap eviction; no modulo bias in the alphabet |
| `PairingURL` | valid parse; missing params; bad port; bad code charset/length; hostile host strings |
| `TerminalQRRenderer` | deterministic module matrix for a known payload; quiet-zone width; explicit-SGR emission; `--no-qr` path |
| `RelayMessageHandler` | pre-auth `pair_request` mints a token; bad code → 401 + `recordFailure`; blocked IP → 429 + close; `pair_request` after auth → 400 |
| `AdminRoutes` | `POST /pair/create` returns a code; rejects non-localhost |
| `hook install` | idempotent re-run; preserves unrelated hooks; backup written; `--dry-run` writes nothing |
| `ServiceManagerDetector` | each of `.homebrew` / `.launchAgent` / `.both` / `.none` from injected plist-presence + binary-path fixtures; installer hint for brew-prefix vs `.build/` |
| Service-command nudges | `load` refuses under `.homebrew` and proceeds under `--force`; `start`/`stop`/`restart` emit the brew command and never invoke launchctl; `--json` carries the owner; `--quiet` suppresses nudges |
| `provision` | `--dry-run` command-list snapshot (pure function, no SSH) |

`ServiceManagerDetector` takes its filesystem probes and binary path as injected
inputs so all four states are unit-testable without touching real
`~/Library/LaunchAgents` or requiring Homebrew.

**Known pre-existing failure:** `swift test` on this repo hangs deterministically
at `GitRootResolver` case 313 and has not passed since 22 Jul; the app-build jobs
are what gate TestFlight. New suites will therefore be verified with
`swift test --filter`, and that limitation reported honestly rather than claiming
a full green run.

## Files touched

**Server:** `Actors/PairingCodeStore.swift` (new), `Network/AdminRoutes.swift`,
`Network/RelayMessageHandler.swift`, `main.swift`.

**Kit:** `ClientMessage.swift`, `ServerMessage.swift`, `PairingURL.swift` (new).

**CLI:** `Commands/SetupCommand.swift` (new), `Commands/HookCommands.swift`
(new), `Commands/ProvisionCommand.swift` (new, phase 2),
`TerminalQRRenderer.swift` (new), `ServiceManagerDetector.swift` (new),
`Commands/ServiceCommands.swift` (nudges in `load`/`unload`/`start`/`stop`/
`restart`/`status`), `AdminClient.swift`, `CLIRoot.swift`.

**Client:** `PairingController.swift` (new), deep-link routing, `ServerListView`
+ scanner/code-entry views (iOS + macOS), Android mirror.

**Docs:** `README.md` Quick Start (lead with `setup`), `Scripts/hooks/README.md`
(point at `hook install`), `CLAUDE.md` (pairing section).

## Acceptance

**Phase 1.** On a fresh Mac: `brew install` then `claude-relay setup` prints a
QR. Scanning it in the iOS app adds the server, authenticates, and lists
sessions with no typing. The same code cannot be redeemed twice. An expired code
is refused with a clear message. Three wrong codes close the socket, and ten from
one IP inside a minute produce a 429 lockout.
`claude-relay token list` shows the paired device by name, and deleting
that token revokes exactly that device. With `--no-qr`, the printed code typed
into "Enter code" produces the same result. `claude-relay hook install` is
safely re-runnable and leaves unrelated hooks in `~/.claude/settings.json`
intact.

**Service-manager awareness.** On this Homebrew-managed machine,
`claude-relay stop` currently fails with a raw `launchctl failed:` error; after
this change it instead prints the `brew services stop clauderelay` command to
use. `claude-relay load` refuses to create a second manager and explains why,
unless `--force` is passed. `claude-relay status` names the owning manager. A
from-source install with no service yet is unaffected — `load` proceeds exactly
as today.

**Phase 2.** `claude-relay provision user@host --pair` on a machine with only
SSH access installs, starts and verifies the relay there, then prints a QR that
pairs a phone directly to that remote host. Re-running it changes nothing.
`--dry-run` prints the remote commands without executing them.

**Overall (the F11 bar).** Provisioning a fresh host drops from seven steps
including a hand-typed secret and a hand-merged JSON file, to: `brew install`,
`claude-relay setup`, scan. This closes the herdr feature spec.
