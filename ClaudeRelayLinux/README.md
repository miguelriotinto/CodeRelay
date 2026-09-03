# ClaudeRelay — Linux client

A native desktop CodeRelay client for Arch Linux / Omarchy (Hyprland, Wayland),
connecting to a CodeRelay server on a Mac.

Full specification and implementation plan: **[`docs/linux-client-spec.md`](../docs/linux-client-spec.md)**.

> **Status: complete for the parity scope.** 702 tests pass on the desktop JVM,
> including the Android client's own suite compiled from the same sources, and
> the terminal is driven end to end against real libvterm. See
> [Current state](#current-state) for what the client does.

## Why this exists as a fork of the Android client

`core-protocol`, `core-net`, `core-session` and `terminal` — 6,660 lines
including the session coordinator, recovery state machine, and activity
coordination — import **no Android API at all**. This project compiles those
*same source files*, from their existing location under `ClaudeRelayAndroid/`.
There is exactly one copy of each on disk.

That means the Android client's own test suite (~6,800 lines, 34 files) runs
here unmodified. It is the primary correctness gate: if it passes on the desktop
JVM, the shared modules really are platform-free.

Nothing under `ClaudeRelayAndroid/` is modified by this build.

## Install

```bash
omarchy pkg aur add coderelay-bin
```

Or download `coderelay-<version>-linux-x86_64.tar.gz` from
[Releases](https://github.com/miguelriotinto/CodeRelay/releases) and run
`coderelay/bin/coderelay`.

The package bundles a trimmed JRE, so it needs no system Java. It does need
`libsecret` (token storage — there is no plaintext fallback) and `libnotify`
(agent notifications); both are declared as package dependencies.

## Requirements

Build:

```bash
sudo pacman -S --needed jdk21-openjdk cmake
```

Gradle comes from the wrapper. The native terminal also needs a C++17 compiler
(`base-devel`).

Runtime (present on a stock Omarchy install):

| Tool | Package | Used for |
|---|---|---|
| `secret-tool` | `libsecret` | Relay + Bedrock tokens in the keyring |
| `notify-send` | `libnotify` | Agent-finished / needs-input notifications |
| `wl-copy` / `wl-paste` | `wl-clipboard` | Clipboard and PRIMARY selection (AWT fallback on X11) |

## Build

```bash
./gradlew :shared-protocol:test :shared-net:test :shared-session:test :shared-terminal:test
./gradlew :linux-storage:test :linux-platform:test
./gradlew :linux-terminal:buildNativeTerminal   # clones termlib at a pinned commit, runs CMake
./gradlew assemble
```

## Architecture

```
shared-protocol ─┐
shared-net       ├─ compiled from ClaudeRelayAndroid/, unmodified
shared-session   │
shared-terminal ─┘

linux-storage    ─ XDG files + Secret Service, same API as :core-storage
linux-platform   ─ Omarchy theme, D-Bus notifications, link-state connectivity
linux-terminal   ─ libvterm via termlib's JNI bridge, built for x86_64-linux
app              ─ Compose Desktop window, tray, shortcuts
```

### Terminal

Android renders with ConnectBot `termlib` (libvterm behind JNI plus a Compose
renderer), published as an Android AAR. The artifact does not work off-Android;
the source does, and **upstream already supports a desktop build** — its
`CMakeLists.txt` has a `find_package(JNI)` branch and `Terminal.cpp` guards its
logging behind `#ifdef __ANDROID__`. JNI is a standard JVM feature, so
`TerminalNative.kt`'s 12 `external fun` declarations load unchanged.

termlib is pinned by commit, not tag: it publishes no desktop artifact, so we
track source, and an unpinned `main` would let an upstream change alter our
terminal without review.

### No push notifications, by design

Push exists because mobile OSes suspend the app. A desktop client holds its
WebSocket open, and the server already streams `session_activity` to every
connected client — the same signal `PushDispatcher` watches server-side. We
notify from the stream we already receive, over `org.freedesktop.Notifications`.

No Firebase, no `google-services.json`, no new secrets on the Mac, **no server
change**, and notifications work even with the server's `pushEnabled=false`
(the default).

### Secrets

Relay tokens and the Bedrock key go to the Secret Service via `secret-tool`,
passed on **stdin** — never argv, which is world-readable through
`/proc/<pid>/cmdline`. If the keyring is unavailable, writes fail loudly; there
is deliberately no plaintext fallback. A relay token grants full session access
to the user's machine.

## Omarchy integration

Reads the live theme from `~/.local/state/omarchy/current/theme/colors.toml` and
maps it onto the terminal's 16-colour ANSI palette, so CodeRelay themes with the
desktop the way Alacritty and Foot do. Verified against all 22 stock themes.

Entirely optional — on a plain Arch box or another distro the paths simply do not
exist and the built-in palette is used.

To add a launch keybinding, first check the chord is free
(`omarchy menu keybindings --print`), then in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + C", "CodeRelay", { launch = "coderelay" })
```

Hyprland window rules are deliberately **not** shipped — that syntax changes
between versions and should be written against the current wiki.

## Current state

Verified working (702 tests, 0 failures, on JDK 21):

| Module | Tests | Notes |
|---|---|---|
| `shared-protocol` | 87 | Android's own suite, unmodified |
| `shared-net` | 42 | Android's own suite, unmodified |
| `shared-terminal` | 50 | Android's own suite, unmodified |
| `shared-session` | 135 | Android's own suite, plus `detachActiveSession` |
| `linux-storage` | 60 | XDG paths, stores, Secret Service |
| `linux-platform` | 69 | Omarchy theme + watcher, notifier, clipboard, connectivity |
| `feature-settings` | 15 | + shared `SettingsScreen` compiles on CMP |
| `feature-servers` | 16 | + shared `ServersScreen`, pairing-link paste |
| `linux-terminal` | 113 | **real libvterm** via the JNI bridge: wheel, paste, scrollback, cursor |
| `feature-workspace` | 63 | shared `WorkspaceScreen`/`SessionSidebar` on CMP |
| `app` | 52 | shortcuts, deep links, single instance, tray model |

**The shared tests passing is the proof of the whole approach**: those files
live under `ClaudeRelayAndroid/` and are compiled here unchanged.

Verified against a live relay (`LiveServerIntegrationTest`, `LivePtyIntegrationTest`,
`LiveConnectFlowTest`, `LivePaneTransitionsTest`, `LiveTerminalRenderTest` — skipped
unless `CODERELAY_TEST_HOST`/`PORT`/`TOKEN` are set):

- connect over a real WebSocket, authenticate with a real token
- `session_list` RPC round-trip decoding into shared types
- application ping/pong RTT measurement
- create a session, attach, send `echo`, read the shell's output back over the
  binary frame channel, then terminate cleanly
- the pane transitions that had each shipped blank: second session, switch back,
  name-tap reload

### What the desktop client does

- **Terminal.** libvterm through termlib's JNI bridge, with two small patches
  (`patches/`): mouse dispatch and bracketed paste. Wheel reports reach a program
  that asked for them (an agent transcript scrolls); a plain shell gets local
  scrollback instead (`terminalScrollbackLines`, Shift+PageUp/PageDown). Mouse
  clicks and drags are reported while a program tracks the mouse; Shift+drag
  always selects locally. Selection copies to PRIMARY on release and to the
  clipboard on Ctrl+Shift+C; middle click pastes PRIMARY; Ctrl+Shift+V pastes
  the clipboard — bracketed when the program enabled DECSET 2004 — or sends an
  image on the clipboard to the host as `paste_image`. OSC 52 writes land on
  the device clipboard; OSC titles reach the window title; DECSCUSR cursor
  shapes and blink are honoured, with a hollow cursor when unfocused.
- **Keyboard.** Every accelerator is Ctrl+Shift or Ctrl+Alt so bare Ctrl chords
  reach the terminal: new session, detach, terminate, next/previous, session
  1–9, sidebar, settings, zoom (Ctrl+Shift+= / - / 0), copy, paste. Handled at
  the window, so they work with the sidebar focused too.
- **Desktop shell.** Close-to-tray with a per-session rollup (state glyphs,
  attention count, quick switch, new/attach/servers/settings/quit). One instance
  per user session: a second `coderelay://` click or the "New Session" desktop
  action is forwarded over a socket in `$XDG_RUNTIME_DIR`. Notifications on
  agent finished / needs input via `notify-send`, with click-to-focus through
  `--action`, suppressed for the session on screen. Auto-connect to the last
  server, and a session link with nothing connected opens that server. Pairing
  from a `coderelay://pair` link, or by pasting the line `claude-relay setup`
  prints. Window size is remembered.
- **Omarchy.** The palette is followed live (a two-second stat of
  `colors.toml`), and the terminal font, size and padding come from the user's
  Foot or Alacritty config unless a size is chosen in Settings.

Not built, by design (spec §1.1, §9): speech, camera QR scanning, push
notifications, Flatpak.

### Building without a system JDK

No root needed:

```bash
mkdir -p ~/.local/jdk
curl -sSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" \
  | tar -xz -C ~/.local/jdk --strip-components=1
export JAVA_HOME=~/.local/jdk PATH=~/.local/jdk/bin:$PATH
./gradlew :shared-session:test
```

`cmake` likewise needs no root:

```bash
curl -sSL "https://github.com/Kitware/CMake/releases/download/v4.4.3/cmake-4.4.3-linux-x86_64.tar.gz" \
  | tar -xz -C ~/.local/cmake --strip-components=1
export PATH=~/.local/cmake/bin:$PATH
./gradlew :linux-terminal:test
```
