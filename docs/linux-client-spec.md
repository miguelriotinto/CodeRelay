# ClaudeRelay Linux Client — Specification & Implementation Plan

**Target platform:** Arch Linux / Omarchy (Hyprland, Wayland)
**Parity target:** the Android client (`ClaudeRelayAndroid/`), feature for feature
**Status:** specification — implementation in progress
**Date:** 2026-09-01

---

## 1. Goal and scope

Build a fourth first-class CodeRelay client, `ClaudeRelayLinux/`, that runs as a native
desktop application on Omarchy and connects to a CodeRelay server running on a Mac.

**Parity is defined against the Android client, not iOS.** Android is the existing
non-Apple port and its deferrals (§9) are inherited rather than solved here. Where
Android carries a documented deferral that Linux can trivially clear (mouse reporting,
§6.4), we clear it and say so.

### 1.1 Non-goals

- **On-device speech.** Android's `WhisperTranscriber.transcribe` is a stub that throws
  `ModelNotLoaded`; the Silero/SmartTurn ONNX detectors are built but not wired into
  `makeDefault`. Linux inherits that state. The pure-Kotlin pipeline ports; the
  inference layer stays absent. Tracked as a follow-on, not part of parity.
- **Push notifications.** Deliberately replaced, not ported — see §6.5.
- **Server changes.** The wire protocol, admin API, and pairing flow are untouched.
  This client is additive.
- **Windows/macOS desktop targets.** The Compose Desktop build could produce them; we
  do not claim, test, or ship them. macOS already has a native client.

---

## 2. Architecture decisions

### AD-1 — Base: fork the Android client to Compose Multiplatform (JVM desktop)

Measured against the alternatives (`docs/` review, 2026-09-01):

| Base | Reusable | Verdict |
|---|---|---|
| Android / Kotlin + Compose Multiplatform | 6,660 lines compile as-is; 6,809 test lines run unchanged | **Chosen** |
| Swift `ClaudeRelayClient` | SwiftUI in 10/34 files, plus Combine/UIKit/AppKit/Security/IOKit; `ClaudeRelaySpeech` is AVFoundation + CoreML | Rejected |
| Ground-up (Tauri + xterm.js, GTK4) | 0 — session logic rewritten in a 4th language | Rejected |

`core-session` (3,216 lines: session coordinator, recovery state machine, activity
coordinator, pairing controller) imports **no Android API at all**. Neither do
`core-net`, `core-protocol`, or `terminal`. Across ~6,200 lines of Compose UI there are
three `LocalContext` uses and one `AndroidView`. That is the whole reason this is
economical.

### AD-2 — Share source, do not copy it

`ClaudeRelayLinux/` is a **separate Gradle build** whose modules point `srcDirs` at the
Android project's existing source directories. There is exactly one copy of every shared
file on disk.

Rejected alternatives:
- *Copy the sources.* Guarantees drift; the Android parity audit already shows what
  keeping two clients honest costs.
- *Convert the Android modules to Kotlin Multiplatform in place.* Cleanest long-term,
  but it rewrites the Android build — which cannot be verified in this environment (no
  Android SDK) and risks a shipping client for the benefit of a new one.

The chosen approach touches **zero** existing files under `ClaudeRelayAndroid/`.

Consequence to accept: a change to a shared file must keep both builds green, and only
one of them is buildable on a Linux dev box. CI must build both (§10).

### AD-3 — Terminal: reuse ConnectBot `termlib` source, built for desktop

Android renders via `org.connectbot:termlib` — libvterm behind JNI plus a Compose
renderer, shipped as an **Android AAR** with Android-ABI `.so` files. The artifact does
not work off-Android; the *source* does.

Verified upstream (`github.com/connectbot/termlib`, Apache-2.0, active):

```cmake
if(ANDROID)
    target_link_libraries(jni_cb_term vterm android log)
else()
    find_package(JNI REQUIRED)
    target_include_directories(jni_cb_term PRIVATE ${JNI_INCLUDE_DIRS})
    target_link_libraries(jni_cb_term vterm)
endif()
```

`Terminal.cpp` already guards Android logging behind `#ifdef __ANDROID__`. **A desktop
JNI build path exists upstream.** JNI is a standard JVM feature, not an Android one, so
`TerminalNative.kt`'s 12 `external fun` declarations load unchanged from a
`libjni_cb_term.so` built for `x86_64-linux`.

Rejected: `jediterm-core` (JetBrains). Viable — genuinely headless, only slf4j +
annotations — but its published POM declares **LGPL 3.0** where this repo is MIT, it is
absent from Maven Central (resolves only from
`packages.jetbrains.team/maven/p/ij/intellij-dependencies`), and it would diverge from
Android's emulator. libvterm is MIT and gives byte-level parity with Android.

Rejected: binding libvterm via Panama/FFM. Unnecessary once the upstream desktop JNI
branch is used, and it would mean reimplementing the 49 KB of C++ in `Terminal.cpp`
that does cell-run batching, palette handling, and the callback bridge.

### AD-4 — Notifications: no push provider

The server speaks APNs and FCM. Neither is available to a Linux desktop app, and a
third provider would be real server work.

It is not needed. **Push exists because mobile OSes suspend the app.** A desktop client
holds its WebSocket open, and the server already streams `session_activity` to every
connected client for the token — the same signal `PushDispatcher` watches. The Linux
client raises notifications from the stream it is already receiving, over
`org.freedesktop.Notifications` (D-Bus).

Consequences: zero server changes, no Firebase project, no new secrets on the Mac, and
notifications work even with `pushEnabled=false` (the default).

### AD-5 — Keep `CleartextPolicy`

Linux has no ATS, so plaintext `ws://` to a Tailscale CGNAT address would "work". It
stays blocked anyway. `CleartextPolicy` ports free as part of `core-net`, and the
common Mac-server deployment is exactly the one it protects: reaching the relay over
Tailscale without TLS puts the bearer token on a network the user does not control.

---

## 3. Module structure

```
ClaudeRelayLinux/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle/libs.versions.toml          # desktop catalog (CMP, not Android Compose)
├── gradle/wrapper/                    # copied from ClaudeRelayAndroid (Gradle 8.14.3)
│
├── shared-protocol/                   # srcDirs → ../ClaudeRelayAndroid/core-protocol
├── shared-net/                        # srcDirs → ../ClaudeRelayAndroid/core-net
├── shared-session/                    # srcDirs → ../ClaudeRelayAndroid/core-session
├── shared-terminal/                   # srcDirs → ../ClaudeRelayAndroid/terminal (minus KeyboardAccessory)
│
├── linux-storage/                     # NEW — replaces :core-storage
├── linux-platform/                    # NEW — connectivity, notifications, clipboard, theme
├── linux-terminal/                    # NEW — native build + TerminalNative + Compose renderer
│
├── feature-servers/                   # srcDirs → Android, CMP-retargeted
├── feature-workspace/                 # srcDirs → Android, CMP-retargeted
├── feature-settings/                  # srcDirs → Android, CMP-retargeted
│
└── app/                               # NEW — Compose Desktop window, tray, nav, wiring
```

Shared modules use `alias(libs.plugins.kotlin.jvm)`; the Android project's own build
files are not modified.

---

## 4. Platform seam inventory

Every Android-coupled surface, with its replacement. These are the contracts the Linux
implementations must satisfy exactly — the shared modules call them by these names.

| Android | Lines | Linux replacement | Notes |
|---|---|---|---|
| `SavedConnectionStore(Context)` — DataStore | 102 | JSON at `$XDG_CONFIG_HOME/coderelay/servers.json` | Same `loadAll/saveAll/add/delete` API; same `WireJson` encoding, so the on-disk format matches Android's stored string |
| `TokenStore(Context)` — EncryptedSharedPreferences | 86 | **Secret Service** (D-Bus) via `libsecret`, keyed by connection UUID | Relay tokens and the Bedrock key must never hit disk in plaintext. Fallback: refuse to store, surface an error — never silently downgrade |
| `SessionOwnershipStore` — SharedPreferences | 123 | JSON at `$XDG_STATE_HOME/coderelay/ownership.json` | Non-secret; device-scoped names + agent map |
| `DeviceIdentifier` — ANDROID_ID | 100 | Generated UUID persisted at `$XDG_STATE_HOME/coderelay/device-id` | Matches Android's accepted divergence from `identifierForVendor` |
| `AndroidConnectivitySource` | 84 | `LinuxConnectivitySource` — NetworkManager over D-Bus, polling fallback | Implements the existing `ConnectivitySource` interface; `NetworkObserver` is already pure |
| `RelayFirebaseMessagingService` + `FcmTokenBridge` + `PushSync` | 183 | **Deleted.** `ActivityNotifier` over `org.freedesktop.Notifications` | See AD-4 |
| `Haptics.kt` | 120 | **Deleted.** No-op | No haptics on desktop |
| `QrScannerScreen` (CameraX + ML Kit, `AndroidView`) | 332 | `PairWithHostSheet` — typed 8-char code + paste `clauderelay://pair` URL | `PairingCode.normalize` already accepts hyphens/lowercase. Webcam scanning deferred |
| `MainActivity` / `RelayApplication` / nav graph | ~700 | Compose Desktop `Window`, tray icon, menu bar, `NavHost` (CMP navigation) | |
| `ContinuousListeningService` (FG service) | 176 | **Deleted.** No foreground-service concept | Speech is out of scope (§1.1) |

### 4.1 Not a seam — ports unchanged

`core-protocol` (1,263), `core-net` (1,203), `core-session` (3,216), `terminal` main
logic (978 minus `KeyboardAccessory.kt`). Total **6,660 lines**, plus 6,809 lines of
existing JUnit5 tests that must pass on the desktop JVM unmodified (§10).

---

## 5. Desktop-specific additions

The Android client has no equivalent for these; they come from the macOS client
(`ClaudeRelayMac/`), which is the desktop UX reference.

### 5.1 Keyboard shortcuts

Ported from `ClaudeRelayMac/Helpers/AppCommands.swift`, `Ctrl` replacing `Cmd`:

| Action | macOS | Linux |
|---|---|---|
| New session | ⌘T | `Ctrl+Shift+T` |
| Detach current | ⌘W | `Ctrl+Shift+W` |
| Terminate current | ⌘⇧W | `Ctrl+Shift+Q` |
| Next / previous session | ⌘⇧] / ⌘⇧[ | `Ctrl+Shift+]` / `Ctrl+Shift+[` |
| Session *n* | ⌘1–9 | `Ctrl+Alt+1`–`9` |
| Toggle sidebar | ⌘0 | `Ctrl+Shift+B` |

All shortcuts use `Ctrl+Shift` or `Ctrl+Alt` because a bare `Ctrl+<key>` **must reach
the terminal** — `Ctrl+C`, `Ctrl+D`, `Ctrl+W` are shell/agent input, not app commands.
This is a hard constraint, not a preference. macOS has no such problem because Cmd is a
modifier the terminal never sees; Linux has no Cmd, so the separation must be deliberate.

Note `Ctrl+Shift+B` rather than `Ctrl+B` for the sidebar: bare `Ctrl+B` is tmux's prefix
key. Enforced in code — `KeyMapping.isApplicationShortcut` only forwards events carrying
Ctrl **plus** Shift or Alt, so a bare-Ctrl accelerator could not be delivered even if one
were added by mistake.

### 5.2 Window and tray

- Single window, sidebar + terminal, always in the "expanded" branch of
  `WorkspaceScreen`'s existing 840 dp breakpoint (the compact drawer is dead code here).
- System tray icon with session-state rollup and quick-attach menu.
- Close-to-tray, matching the macOS client's menu-bar persistence.

---

## 6. Terminal engine

### 6.1 Native build

`linux-terminal/native/` vendors nothing. A Gradle task clones/updates
`connectbot/termlib` at a pinned commit into `build/termlib-src/`, then runs CMake with
the upstream `else()` branch:

```
cmake -S <termlib>/lib/src/main/cpp -B build/native \
      -DCMAKE_BUILD_TYPE=Release
cmake --build build/native
→ libjni_cb_term.so   (x86_64)
```

`find_package(JNI)` resolves against the build JDK. The `.so` is packaged into the
distribution and loaded by `System.loadLibrary("jni_cb_term")`.

**Pinned by commit, not tag** — termlib publishes no desktop artifact, so we track
source. Bumping the pin is a deliberate, reviewed change.

### 6.2 Kotlin native boundary

`TerminalNative.kt` is taken from termlib unchanged. Its full surface is 12 functions:

```
nativeInit(callbacks) → Long        nativeGetCellRun(ptr, row, col, run)
nativeDestroy(ptr)                  nativeSetPaletteColors(ptr, colors, count)
nativeWriteInputBuffer(...)         nativeSetDefaultColors(ptr, fg, bg)
nativeWriteInputArray(...)          nativeGetLineContinuation(ptr, row)
nativeResize(ptr, rows, cols)       nativeSetBoldHighbright(ptr, enabled)
nativeDispatchKey(ptr, mods, key)
nativeDispatchCharacter(ptr, mods, ch)
```

### 6.3 What ports and what is rewritten

Measured import-by-import against upstream, not estimated:

| termlib file | Lines | Android imports | Disposition |
|---|---|---|---|
| `TerminalNative` · `TerminalCallbacks` · `CellRun` · `ScrollController` · `UrlDetection` | — | **0** | Sync verbatim |
| `ColorCache` · `TerminalSnapshot` · `TerminalLine` · `SemanticType` · `SelectionManager` · `TerminalScreenState` | — | only `androidx.compose.*` | Sync verbatim — CMP republishes those exact package names for the desktop JVM |
| `TerminalEmulator.kt` | 1,518 | `Handler`/`Looper`, `Choreographer`, `android.icu`, `Log` | **Port** — see below |
| `Terminal.kt` | 2,506 | IME, accessibility, Android key/pointer | **Rewrite** for Compose Desktop |

**Correction to an earlier read of this codebase:** `TerminalEmulator.kt` was
initially assumed portable. It is not. The coupling is narrow and mechanical,
though — four concerns, each with a direct desktop equivalent:

| Android | Desktop replacement |
|---|---|
| `Handler(looper)` — post off the native mutex | Single-threaded coroutine dispatcher |
| `Choreographer` — frame-synced damage coalescing | Compose `withFrameNanos` |
| `android.icu.lang.UCharacter` / `UProperty` | `com.ibm.icu:icu4j` — **Android's `android.icu` IS ICU4J**, so this is an import swap, not a reimplementation |
| `android.util.Log` | Any logger |

So it is a targeted port of a forked file, not 1,518 lines of new logic. Budget it
as such — but budget it, because the first read of this file said otherwise.

The `TerminalEngine` seam (`feedOutput` / `resize` / `cols` / `rows` / `onInput`) is
unchanged, so `RelayTerminalController` and `TerminalSessionVm` drive the desktop engine
exactly as they drive Android's.

### 6.4 Mouse reporting — a deferral Linux clears

`CLAUDE.md` records: *"Android's termlib engine takes input only from the keyboard and
has no mouse path at all."* termlib exposes no mouse function. But libvterm does:

```c
void vterm_mouse_move(VTerm *vt, int row, int col, VTermModifier mod);
void vterm_mouse_button(VTerm *vt, int button, bool pressed, VTermModifier mod);
```

libvterm encodes the wheel report itself, honouring whatever mouse mode the program set.
We add `nativeDispatchMouse` to our `Terminal.cpp` build and wire scroll events to it.

This solves natively what iOS needed `sendWheel(travel:at:)` and a custom pan recognizer
to fake, and what Android still lacks. On a desktop with a real scroll wheel it is not
optional. **Upstream this** rather than carrying a patch (§11).

### 6.5 Notifications

`ActivityNotifier` subscribes to the coordinator's existing activity stream and emits a
desktop notification on the same edges `PushDispatcher` uses server-side: agent
finished, agent needs input. Coalesced per workspace group, matching the server's
`(token, workspace-group)` debounce so behaviour matches the mobile clients.

Suppressed when the relevant session is the focused, visible session — the user is
already looking at it.

---

## 7. Omarchy integration

### 7.1 Theme following

Verified paths on Omarchy:

```
~/.local/state/omarchy/current/theme/colors.toml   # active palette
~/.local/state/omarchy/current/theme.name          # slug, e.g. "tokyo-night"
~/.config/omarchy/hooks/theme-set.d/               # hooks, slug passed as $1
```

`colors.toml` is already ANSI-shaped: `background`, `foreground`, `red`/`yellow`/
`orange`/`green`/`cyan`/`blue`/`magenta`, `bright_*` variants, plus `accent`,
`selection`, `muted`. It maps onto `TerminalPalette`'s 16-colour table nearly key for
key.

`OmarchyTheme` reads it at launch and watches the file for changes. A shipped hook
script (`omarchy hook install theme-set …`) is offered but not required — the file watch
alone is sufficient, and works when the app is running under a non-Omarchy Hyprland.

**Graceful degradation is mandatory:** the paths may not exist (plain Arch, another
distro). Absent or malformed → fall back to the built-in `TerminalPalette` defaults,
log once, never crash.

### 7.2 Desktop integration

- `.desktop` entry in `$XDG_DATA_HOME/applications/`, with a stable
  `StartupWMClass` so Hyprland window rules can match it.
- Registers the `clauderelay://` scheme (`x-scheme-handler/clauderelay`) so
  `session/<uuid>` deep links and pairing URLs resolve. Deep-link parsing already exists
  in shared code (`DeepLinks.kt`).
- Suggested keybinding for `~/.config/hypr/bindings.lua` documented in the README, not
  installed automatically:
  ```lua
  o.bind("SUPER + SHIFT + C", "CodeRelay", { launch = "coderelay" })
  ```
  Users must check `omarchy menu keybindings --print` and `hl.unbind` first if the chord
  is taken. **Window rules are not shipped** — Hyprland's rule syntax changes between
  versions and must be written against the current wiki.

### 7.3 Naming

The user-visible name is **`Code[Relay]`**, brackets included — matching
`CFBundleDisplayName` on iOS/macOS and `app_name` on Android exactly. Linux must not
be the one client showing a different name.

| Facet | Value | Rationale |
|---|---|---|
| Display name | `Code[Relay]` | Identical to the other three clients |
| Binary / command | `coderelay` | Brackets are shell glob characters; a bracketed binary name would need quoting everywhere |
| AUR package | `coderelay-bin` | Arch convention: `-bin` marks a prebuilt |
| Desktop file | `coderelay.desktop` | |
| WM class | `relay-app-CodeRelay` | Measured, pinned by `@file:JvmName("CodeRelay")` |
| URL scheme | `clauderelay://` (unchanged) | Wire compatibility — `claude-relay setup` emits it in QR codes |

The scheme is deliberately **not** renamed. It is part of the wire contract with a
server that may be older than the client, and every existing QR code and pairing URL
carries it.

### 7.4 Distribution

**AUR `coderelay-bin`, consuming a tarball published to GitHub Releases.**

One artifact serves both channels: the release workflow builds and publishes
`coderelay-<tag>-linux-x86_64.tar.gz` (also the manual-download route, matching how
the Android APK is already distributed), and the AUR package downloads and installs
exactly that file. Install is `omarchy pkg aur add coderelay-bin`.

Measured size: 202 MB unpacked, **118 MB compressed**, of which 91 MB is the bundled
JRE. Large, but in the same range as an Electron app, and it buys independence from
whatever Java the user has installed.

Rejected, with reasons:

| Option | Why not |
|---|---|
| **Source-built AUR** (`coderelay`) | The build clones termlib from the network at a pinned commit and patches it. AUR expects every input in `source=()` with a checksum; network access in `build()` breaks reproducibility and offline builds. Viable once the mouse patch is upstreamed — add it then, alongside `-bin`. |
| **Flatpak** | Decisive: the platform layer shells out to `secret-tool` and `notify-send`, host binaries absent from the sandbox. Worse, libsecret inside Flatpak uses **per-app encrypted local storage via the Secret portal, not the host keyring** — tokens would silently land somewhere the user does not expect. Supporting it means rewriting `linux-platform` against D-Bus portals. |
| **AppImage** | No `.desktop` registration by default, so `clauderelay://` deep links and Hyprland `StartupWMClass` rules do not work. Deep links are a shipped feature. |
| **Tarball only** | Fine as the artifact; not as the only channel — no upgrade path and no way to declare the libsecret/libnotify runtime dependencies. |

Automation mirrors the existing Homebrew tap job: on a release tag, `build-linux`
produces and test-gates the tarball, `release` publishes it and computes its SHA256,
and `aur` pushes a bumped `PKGBUILD` + regenerated `.SRCINFO`. Both bump jobs skip
cleanly when their secrets are absent, so a dry-run tag push is harmless.

---

## 8. Parity matrix vs. the Android client

| Android capability | Linux | Notes |
|---|---|---|
| Server list, add/edit/delete, live dot | **Full** | CMP retarget of `ServersScreen` |
| Pairing (QR redeem → per-device token) | **Full**, different input | Typed code + URL paste; camera scan deferred |
| Workspace: sidebar + terminal, tabs | **Full** | Expanded branch only |
| Real VT100/xterm terminal | **Full** | Same libvterm |
| Mouse / wheel reporting | **Exceeds** | §6.4 — Android has none |
| Session create/attach/detach/terminate/rename | **Full** | Shared `core-session` |
| Recovery state machine | **Full** | Shared, byte-identical |
| Connection quality (ping/pong, RTT) | **Full** | Shared `core-net` |
| Activity monitoring, agent detection, tab colours | **Full** | Shared |
| Workspace rollups by git root | **Full** | Shared |
| Deep links `clauderelay://session/<uuid>` | **Full** | Scheme handler |
| Notifications on agent finished / needs input | **Full**, different transport | D-Bus, not FCM (AD-4) |
| Clipboard bridging (OSC 52 host→device) | **Not in Android** | The Kotlin protocol has no `clipboard_update` variant at all — this is an iOS/macOS-only feature. Out of parity scope; see §8.1 |
| Image paste (device→host) | **Not in Android** | `PasteImage`/`PasteImageResult` exist in `core-net`, but nothing in the Android UI calls them. Out of parity scope; see §8.1 |
| Settings: all 14 keys + Bedrock token | **Full** | Secret Service for the token |
| Scrollback / font size / naming theme | **Full** | |
| TLS / cleartext scoping | **Full** | AD-5 |
| Auto-connect | **Full** | |
| Haptics | **N/A** | No desktop equivalent |
| On-device speech / wake word | **Deferred** | Inherited from Android (§1.1) |
| Keyboard shortcuts, tray, close-to-tray | **Exceeds** | §5 — from the macOS client |
| Omarchy theme following | **Exceeds** | §7.1 |

### 8.1 Clipboard — a gap in the shared Kotlin stack, not just in Linux

Verified while writing this spec: the Kotlin `core-protocol` has **no
`clipboard_update` message**, and although `PasteImage`/`PasteImageResult` exist
in `core-net`, no Android UI calls them. Both clipboard directions are
iOS/macOS-only today.

They are therefore **out of parity scope** — Linux cannot be behind Android on a
feature Android does not have. They are called out because a desktop is where
clipboard matters most, and because the fix benefits both non-Apple clients:

1. Add a `ClipboardUpdate` variant to the shared Kotlin `ServerMessage`. This is
   the only change that touches shared protocol code, and it lands for Android
   at the same time.
2. Wire `pasteImage` to a paste keybinding, reading the image with `wl-paste`.
3. Write host→device clipboard payloads with `wl-copy` — active session only,
   matching the server-side rule that a background session's copy must not
   hijack the pasteboard.

Sequenced after parity (post-L6), so it never blocks the milestone chain.

---

## 9. Inherited deferrals

Carried from Android, explicitly **not** solved here:

1. **whisper.cpp / llama.cpp inference** — stubs that degrade gracefully.
2. **Silero VAD / SmartTurn ONNX detectors** — built, not wired into `makeDefault`.
3. **Camera QR scanning** — replaced by typed code + URL paste, which is arguably better
   on a desktop.

---

## 10. Testing strategy

| Layer | Approach |
|---|---|
| Shared modules | The existing **6,809 lines** of JUnit5 tests must pass unmodified on the desktop JVM. This is the primary correctness gate — it proves the shared source really is platform-free |
| Linux seams | New unit tests per seam: storage round-trip, XDG path resolution, theme parsing (including absent/malformed), connectivity edge detection, notification coalescing |
| Terminal | Feed captured session byte streams through the engine and assert grid state — colour, cursor addressing, alt-screen entry/exit (Claude Code runs in the alternate buffer) |
| Integration | Headless connect → authenticate → attach against a real relay server |

CI (`.github/workflows/linux.yml`): `ubuntu-latest`, JDK 21, CMake; builds the native
lib, runs all module tests, assembles the distribution. Must run on changes to
`ClaudeRelayLinux/**` **and** to the shared Android modules — AD-2's shared source means
an Android-side edit can break the Linux build.

---

## 11. Milestones

| # | Milestone | Gate |
|---|---|---|
| **L0** | Toolchain + skeleton: Gradle build, shared-source wiring, catalog | `shared-*` modules compile; shared tests run |
| **L1** | Native terminal spike: CMake desktop build, `TerminalNative` loads, bytes → grid | A captured stream renders correctly in a scratch window |
| **L2** | Platform seams: storage, Secret Service, connectivity, device id | Seam unit tests pass; headless connect+auth against the Mac |
| **L3** | Terminal renderer: Compose Desktop `Terminal.kt` + mouse dispatch | Interactive session, wheel scroll moves the agent transcript |
| **L4** | UI retarget: servers, workspace, settings on CMP | Screen-by-screen parity with Android |
| **L5** | Desktop shell: window, tray, shortcuts, deep links, notifications | §5 + AD-4 complete |
| **L6** | Omarchy: theme following, `.desktop`, PKGBUILD | Installs from AUR, follows a theme switch live |
| **L7** | Upstream: contribute desktop target + mouse dispatch to termlib | PR opened; pin moves to upstream commit |

L1 is deliberately first after the skeleton: it is the only milestone that can fail in a
way that invalidates AD-3, and it fails cheaply.

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| Compose Desktop text rendering on a monospace grid (font metrics, fractional DPI) | L1 gate; `ColorCache`/`CellRun` batching is reused rather than reinvented |
| Wayland clipboard and IME differences under Hyprland | Test on the target compositor, not X11/XWayland |
| Shared-source coupling: an Android edit breaks Linux | CI builds both on shared-module changes (§10) |
| JVM startup and resident memory on a lean Arch box | Accepted: long-running window, not launch-per-session. `jlink` trims the runtime |
| termlib source pin drift | Pinned by commit; upstreaming (L7) converts a fork into a dependency |
| A 4th parity surface to maintain | Linux and Android *share* the session layer rather than mirroring it — the long-term argument for AD-2 |

---

## Appendix A — Verified environment facts

Gathered on the target machine, 2026-09-01:

```
OS                  Omarchy (ID_LIKE=arch), Hyprland, Lua configs
Active theme        tokyo-night
libvterm            0.3.3-2, MIT, /usr/include/vterm.h  (installed)
vte4 / vte3         0.84.1-1                            (available, unused — AD-3)
Toolchain present   gcc, g++, make, pkg-config
Toolchain MISSING   jdk, cmake        → `sudo pacman -S --needed jdk21-openjdk cmake`
Android stack       Kotlin 2.3.21, Gradle 8.14.3, coroutines 1.11.0,
                    serialization 1.11.0, okhttp 4.12.0
termlib upstream    github.com/connectbot/termlib, Apache-2.0, desktop CMake branch present
```
