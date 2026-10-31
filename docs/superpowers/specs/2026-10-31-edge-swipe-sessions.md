# Edge swipe to open the session list (approved small change)

Approved by the user on 2026-10-31. Small change: no separate plan.

## What it does

A rightward swipe that starts at the left screen edge does exactly what tapping the
top-left session button does. It never changes how the session list looks.

- iPhone (compact): presents the existing session bottom sheet
  (`CodeRelayApp/Views/WorkspaceView.swift`, the `.sheet` with `.medium`/`.large`
  detents toggled from the top-left button, ~lines 53-66). Same code path as the button.
- iPad (regular): opens the `NavigationSplitView` sidebar (`columnVisibility`), as the
  button does.
- Android phone (compact): opens the `ModalNavigationDrawer`
  (`CodeRelayAndroid/.../WorkspaceScreen.kt` ~line 479), as the button does.
- Android unfolded/tablet (two-pane): opens the side panel. There is already a
  hand-made left-edge drag there (~lines 290-300). Bring it in line with the rules
  below using the same shared decision logic; do not add a second gesture.
- If the list is already open, the swipe does nothing.

## Where it starts

- A strip 20 pt (iOS) / 20 dp (Android) wide along the left edge, everywhere in the
  workspace, including when no session is open.
- Android: the strip is limited to a band 200 dp tall, vertically centred on the left
  edge, and that band is registered with `Modifier.systemGestureExclusion` so the
  system Back gesture keeps the rest of the left edge and the whole right edge.

## What counts as a swipe

- Rightward horizontal travel of at least 40 pt/dp, and clearly more horizontal than
  vertical (|dx| > 2·|dy|, horizontal-dominant).
- Taps, vertical scrolls, and drags that start outside the strip go to the terminal
  untouched. The terminal relies on one-finger swipes (scrollback, agent key swipes —
  see `CodeRelayAppTests/TerminalSwipeScrollTests`), so the recognizer must not claim
  touches outside the strip.

## Out of scope

- No visual change to the list. No swipe-to-close (existing gestures and Done handle it).
- No macOS change. Linux shares Android's Compose screen code: the gesture must respond
  to touch pointers only (`PointerType.Touch`), never mouse drags, so Linux is unaffected.

## Tests and checks

- The "does this drag count" decision is pure logic: one pure function/type per platform
  (Swift in the iOS app or `CodeRelayClient`, Kotlin in the shared feature module),
  unit-tested: start inside/outside strip, below/at threshold, too vertical, leftward,
  list already open, Android start outside the 200 dp band.
- Build: iOS `xcodebuild` for the app scheme; Android
  `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug` plus the module unit tests; Linux
  `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:compileKotlin` (in `CodeRelayLinux`).
- Manual check on the iOS simulator and an Android emulator if available: the swipe opens
  the list; terminal scrolling and agent swipes still behave normally.
