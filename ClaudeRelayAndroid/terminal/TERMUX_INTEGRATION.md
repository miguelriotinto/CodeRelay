# Termux engine binding — DEFERRED (device-gated)

The `:terminal` module ships a **pluggable engine contract** so the wiring logic
is real and unit-tested without a VT engine:

- `TerminalEngine` — the minimal interface `RelayTerminalController` needs from
  any engine (`feedOutput`, `resize`, `cols`/`rows`, `onInput`).
- `RelayTerminalController` — wires a `TerminalEngine` to a `TerminalSessionVm`
  and the relay I/O callbacks. Fully covered by `RelayTerminalControllerTest`
  against a `FakeTerminalEngine`.
- `TerminalPalette` — the 16-color ANSI palette, ready to install into an engine.

The **concrete Termux `TerminalView` binding (`RelayTermuxView`) is deferred**,
the same way the instrumented UI tests are deferred — it cannot be verified in
this environment (no emulator) and the dependency situation is fragile (below).

## Why deferred

1. **No device / emulator.** A terminal view is render-, IME-, key-handling-,
   and resize-sensitive. None of that can be runtime-verified here. The M1 plan
   marks this seam as manual-verify-only.

2. **Dependency resolution is fragile.** Termux is **not on Maven Central**
   (404). It is **not** published under `com.github.termux:terminal-view`
   either (JitPack returns `401 Unauthorized` for that coordinate). It *does*
   resolve via the **canonical JitPack coordinate built on-demand from the
   `termux-app` mono-repo**:

   ```kotlin
   // settings.gradle.kts → dependencyResolutionManagement.repositories
   maven { url = uri("https://jitpack.io") }

   // terminal/build.gradle.kts
   implementation("com.github.termux.termux-app:terminal-view:v0.118.0")
   implementation("com.github.termux.termux-app:terminal-emulator:v0.118.0")
   ```

   This was verified to resolve (JitPack builds both AARs on first request).
   But an on-demand JitPack build is **not a hermetic, CI-safe dependency**: the
   first fetch can `401` until the build completes, artifacts can be evicted,
   and it pins us to a transitive `androidx.annotation` build. Vendoring the
   Termux sources (or mirroring the AARs) is the intended production approach,
   per Task 17 ("vendors the Termux engine").

3. **Termux's API assumes an OWNED local PTY.** `TerminalSession` *spawns and
   manages a child process* (its constructor takes `String[] args, String[] env`
   and `write(byte[])` writes to that subprocess's stdin). Output is pumped from
   the subprocess into the emulator on an internal reader thread. For a *remote*
   relay PTY we do not want Termux to spawn anything — we drive the emulator
   directly. That is a real integration, not a thin shim, and is exactly what
   needs a device to validate.

## Contract a Termux adapter must implement

A `RelayTermuxView` (or a `TermuxTerminalEngine : TerminalEngine`) must satisfy
the `TerminalEngine` contract, mapping onto the Termux API surface observed in
`v0.118.0`:

| `TerminalEngine` member            | Termux mapping                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------ |
| `feedOutput(bytes: ByteArray)`     | `TerminalEmulator.append(bytes, bytes.size)` then `TerminalView.onScreenUpdated()`. **Byte-fidelity** — pass `byte[]` straight through, never via `String`. |
| `resize(cols, rows)`               | `TerminalEmulator.resize(cols, rows)` / `TerminalSession.updateSize(cols, rows)` and `TerminalView.updateSize()`. |
| `cols` / `rows`                    | `TerminalEmulator.mColumns` / `TerminalEmulator.mRows`.                        |
| `onInput: ((ByteArray) -> Unit)?`  | Capture via a custom `TerminalOutput` (the abstract `write(byte[], int, int)` sink) wired through `TerminalView` key/IME input, instead of letting `TerminalSession` write to a child process. |

Behavioral contract the controller relies on (see `TerminalEngine` KDoc and
iOS `RelayTerminalView.swift` / `IOSTerminalCoordinator`):

- **Byte fidelity:** output bytes flow relay → `TerminalSessionVm.onTerminalOutput`
  → `TerminalEngine.feedOutput` verbatim. No `String` decoding — UTF-8 runes and
  escape sequences split across WebSocket frames must survive.
- **Ready-on-size:** the view reports its laid-out geometry once known; the
  controller turns the FIRST report into a single `vm.terminalReady()` (drains
  buffered scrollback). Termux reports size from `updateSize()` / its layout
  pass — forward that into `RelayTerminalController.reportSize(cols, rows)`.
- **Resize:** every size change calls `reportSize`, which resizes the engine and
  sends the new window size upstream so the server PTY matches.
- **Palette:** install `TerminalPalette.colors` (+ `background`/`foreground`)
  into the emulator's color table.

## Gating

Writing `RelayTermuxView` is gated on:

1. Vendoring the Termux `terminal-emulator` + `terminal-view` sources (or
   mirroring the AARs) so the build is hermetic — not relying on on-demand
   JitPack.
2. A physical device / emulator to manually verify rendering, IME, hardware-key
   handling, copy/paste, and resize.

Until then the engine integration is exercised through `RelayTerminalController`
+ `FakeTerminalEngine` unit tests, which validate every edge of the wiring
contract that does not require a real VT renderer.
