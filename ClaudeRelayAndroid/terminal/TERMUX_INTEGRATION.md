# Terminal engine binding — ConnectBot `termlib`

> **History:** this file originally documented a *deferred* Termux
> (`terminal-view` / `terminal-emulator`) binding. That path was **abandoned** —
> Termux only resolved via on-demand JitPack builds (not hermetic/CI-safe) and
> its `TerminalSession` API assumes an owned *local* child PTY, which is the
> wrong shape for a remote relay. The shipped terminal instead uses **ConnectBot
> `termlib`** (`org.connectbot:termlib`), a libvterm-backed emulator with a
> Jetpack Compose renderer. This document now describes that real binding.

## The pluggable engine contract (`:terminal`, pure-Kotlin)

The `:terminal` module owns the engine-agnostic wiring, fully unit-tested with
no VT engine or device:

- `TerminalEngine` — the minimal interface `RelayTerminalController` needs from
  any engine (`feedOutput`, `resize`, `cols`/`rows`, `onInput`).
- `RelayTerminalController` — wires a `TerminalEngine` to a `TerminalSessionVm`
  and the relay I/O callbacks. Fully covered by `RelayTerminalControllerTest`
  against a `FakeTerminalEngine`.
- `TerminalPalette` — the 16-color ANSI palette, installed into the engine.

## The concrete engine (`:feature-workspace`, `termlib`)

`TermlibTerminalEngine` (in `:feature-workspace`) implements `TerminalEngine` on
top of termlib's `TerminalEmulator`, and `TerminalHost` renders termlib's
`Terminal()` composable. The byte path runs:

```
relay → TerminalSessionVm.onTerminalOutput → RelayTerminalController
      → TermlibTerminalEngine.feedOutput → TerminalEmulator.writeInput   (output)
termlib soft keyboard / hardware keys → emulator.onKeyboardInput
      → engine.onInput → RelayTerminalController.onInput → connection.sendBinary  (input)
```

| `TerminalEngine` member            | termlib mapping                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------- |
| `feedOutput(bytes: ByteArray)`     | `TerminalEmulator.writeInput(bytes)` — **byte-fidelity**, no `String` decode.   |
| `resize(cols, rows)`               | Record-only. termlib's `Terminal` composable owns sizing: it measures its own pixel geometry, calls `emulator.resize()`, and posts the factory `onResize`, which the host bridges to `RelayTerminalController.reportSize`. |
| `cols` / `rows`                    | Last grid reported by termlib's `onResize`.                                     |
| `onInput: ((ByteArray) -> Unit)?`  | termlib's factory `onKeyboardInput` (typed chars + generated escape sequences), forwarded to the relay binary-send. The `KeyboardAccessory` special-key bar feeds the same `onInput` directly. |

## Behavioral contract the controller relies on

(See `TerminalEngine` KDoc and iOS `RelayTerminalView.swift` / `IOSTerminalCoordinator`.)

- **Byte fidelity:** output bytes flow relay → `TerminalSessionVm.onTerminalOutput`
  → `TerminalEngine.feedOutput` verbatim. No `String` decoding — UTF-8 runes and
  escape sequences split across WebSocket frames must survive.
- **Ready-on-size:** termlib reports its laid-out geometry once measured; the
  controller turns the FIRST report into a single `vm.terminalReady()` (drains
  buffered scrollback). `TermlibTerminalEngine` starts the emulator at a `1×1`
  sentinel grid so the first real layout always differs and `onResize` always
  fires (see its KDoc).
- **Resize:** every size change calls `reportSize`, which records the engine grid
  and sends the new window size upstream so the server PTY matches.
- **Palette:** `TerminalPalette.colors` (+ `background`/`foreground`) is installed
  via `TerminalEmulator.applyColorScheme` at engine construction.

## Device-gated concerns (verified manually, not in unit tests)

termlib rendering, IME/`InputConnection` focus, hardware-key handling, and resize
are render-sensitive and validated on a device, not in the JVM suite. Two such
issues were found and fixed on-device: the soft keyboard dying on session switch
(termlib's `ImeInputView` is rebuilt per session via `key(vm)` in `TerminalHost`)
and the terminal not repainting on app foreground (`restoreActiveOnForeground`).
The engine-agnostic wiring in `:terminal` remains covered by
`RelayTerminalControllerTest` + `FakeTerminalEngine`.
