package relay.app

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key

/**
 * Application accelerators, ported from the macOS client's command menu
 * (`ClaudeRelayMac/Helpers/AppCommands.swift`) with Ctrl replacing Cmd.
 *
 * ### The hard constraint
 *
 * **Every accelerator uses Ctrl+Shift or Ctrl+Alt.** A bare `Ctrl+<key>` is
 * terminal input, not an app command: `Ctrl+C` interrupts the agent, `Ctrl+D`
 * sends EOF, `Ctrl+W` deletes a word, `Ctrl+R` searches history. macOS has no
 * such problem because Cmd is a separate modifier the terminal never sees;
 * Linux has no Cmd, so the separation has to be deliberate.
 *
 * Binding `Ctrl+C` to "copy" here would make the agent uninterruptible — the
 * single most damaging thing a terminal app can get wrong.
 */
enum class AppShortcut {
    NEW_SESSION,
    DETACH_CURRENT,
    TERMINATE_CURRENT,
    NEXT_SESSION,
    PREVIOUS_SESSION,
    TOGGLE_SIDEBAR,
    ;

    companion object {

        /**
         * Resolves a key event to a command, or null when the terminal should
         * have it.
         *
         * Session switching uses Ctrl+Alt+<n> rather than Ctrl+<n>, because
         * Ctrl+<digit> is meaningful to some programs and Alt+<digit> is used by
         * others; the three-key combination collides with neither.
         */
        fun resolve(event: KeyEvent): AppShortcut? =
            resolve(event.key, event.isCtrlPressed, event.isShiftPressed, event.isAltPressed)

        /**
         * Pure resolver. The `KeyEvent` overload delegates here.
         *
         * Split out because Compose Desktop's `KeyEvent` is a value class over a
         * skiko-internal type that cannot be constructed in a unit test — and
         * because shortcut resolution is decision logic that has no business
         * depending on a platform event type in the first place. Everything
         * interesting is testable through this entry point.
         */
        fun resolve(key: Key, ctrl: Boolean, shift: Boolean, alt: Boolean): AppShortcut? {
            if (!ctrl) return null

            if (shift && !alt) {
                return when (key) {
                    Key.T -> NEW_SESSION
                    Key.W -> DETACH_CURRENT
                    Key.Q -> TERMINATE_CURRENT
                    Key.RightBracket -> NEXT_SESSION
                    Key.LeftBracket -> PREVIOUS_SESSION
                    // Ctrl+SHIFT+B, not Ctrl+B: bare Ctrl+B is tmux's prefix
                    // key, and stealing it would break tmux inside every
                    // session. It also could not have worked — the terminal
                    // view only forwards events that pass
                    // `KeyMapping.isApplicationShortcut`, which requires Shift
                    // or Alt alongside Ctrl.
                    Key.B -> TOGGLE_SIDEBAR
                    else -> null
                }
            }

            return null
        }

        /** Ctrl+Alt+1..9 → zero-based session index, or null. */
        fun sessionIndex(event: KeyEvent): Int? =
            sessionIndex(event.key, event.isCtrlPressed, event.isAltPressed)

        /** Pure form of [sessionIndex]; see [resolve]. */
        fun sessionIndex(key: Key, ctrl: Boolean, alt: Boolean): Int? {
            if (!ctrl || !alt) return null
            return when (key) {
                Key.One -> 0
                Key.Two -> 1
                Key.Three -> 2
                Key.Four -> 3
                Key.Five -> 4
                Key.Six -> 5
                Key.Seven -> 6
                Key.Eight -> 7
                Key.Nine -> 8
                else -> null
            }
        }
    }
}
