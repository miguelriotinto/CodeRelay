package relay.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * The app-wide Material 3 theme. ClaudeRelay is a terminal app whose primary
 * surface — the VT grid — is pure black, and the iOS app presents effectively
 * dark throughout (black terminal + system-dark sheets/sidebar). So the Android
 * app is **always dark**: a single [darkColorScheme] wrapped around the whole nav
 * graph.
 *
 * Why a fixed dark scheme (not `isSystemInDarkTheme()` / dynamic color):
 *  - The terminal background is hard-coded black ([relay.terminal.TerminalPalette]);
 *    a light app chrome around a black terminal looked broken (white sidebar/sheets
 *    floating over black — the reported bug).
 *  - Dynamic color would tint the chrome with the user's wallpaper, diverging from
 *    the iOS look and risking low contrast against the black terminal.
 *
 * Surface ramp is chosen so panels are **visibly distinct over the black terminal**:
 * the terminal is `#000000`, while [surface] / [surfaceVariant] are lifted dark
 * greys (Material 3 dark baseline), so the session sidebar and the attach sheet read
 * as panels sitting *above* the terminal rather than blending into it. A divider/
 * border on the sidebar edge reinforces the separation (see WorkspaceScreen).
 */
private val RelayDarkColors = darkColorScheme(
    // Green accent — matches the app's connection/activity dots (QualityGreen) and
    // the iOS tint.
    primary = Color(0xFF4CD964),
    onPrimary = Color(0xFF00210B),
    // Panels lifted off pure black so they're visible over the black terminal.
    background = Color(0xFF000000),
    onBackground = Color(0xFFE6E1E5),
    surface = Color(0xFF1B1B1D),
    onSurface = Color(0xFFE6E1E5),
    surfaceVariant = Color(0xFF2A2A2D),
    onSurfaceVariant = Color(0xFFC7C5CA),
    // Outline used for the sidebar separator / sheet borders.
    outline = Color(0xFF49454F),
    outlineVariant = Color(0xFF35343A),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
)

/** Wraps content in the app's fixed dark Material 3 theme. */
@Composable
fun RelayTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = RelayDarkColors, content = content)
}
