package relay.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import relay.protocol.SessionNamingTheme

/**
 * Settings screen, ported section-for-section from `SettingsView.swift`.
 *
 * Reads/writes through [AppSettings] (DataStore). Each toggle/picker collects its
 * backing [kotlinx.coroutines.flow.StateFlow] and calls the matching `set…`
 * mutator. The sections are the ones iOS has minus **Notifications** (Android
 * hardcodes those prefs in `PushSync`):
 *  1. **General** — Haptic Feedback, Session-Names theme, Terminal Font Size
 *     stepper (8–16), Scrollback picker.
 *  2. **About** — version/build.
 *
 * @param appVersion app version name (host passes `BuildConfig.VERSION_NAME`)
 * @param buildNumber app version code (host passes `BuildConfig.VERSION_CODE`)
 * @param visibleSections which sections to render. Defaults to all of them.
 * @param hapticFeedbackAvailable whether to show the Haptic Feedback toggle; a
 *   desktop has no vibrator.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: AppSettings,
    appVersion: String,
    buildNumber: String,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    visibleSections: Set<SettingsSection> = SettingsSection.entries.toSet(),
    hapticFeedbackAvailable: Boolean = true,
) {
    val haptics by settings.hapticFeedbackEnabled.collectAsStateWithLifecycle()
    val theme by settings.sessionNamingTheme.collectAsStateWithLifecycle()
    val fontSize by settings.terminalFontSize.collectAsStateWithLifecycle()
    val scrollback by settings.terminalScrollbackLines.collectAsStateWithLifecycle()

    // No validation gate any more: the Bedrock "Bearer Key is Required" alert went
    // with the speech stack. Done simply dismisses.
    fun handleDone() = onDone()

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = ::handleDone) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Done")
                    }
                },
                actions = {
                    TextButton(onClick = ::handleDone) { Text("Done") }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .padding(innerPadding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // 1) General
            if (SettingsSection.GENERAL in visibleSections) {
                SectionHeader("General")
                if (hapticFeedbackAvailable) {
                    ToggleRow("Haptic Feedback", haptics, settings::setHapticFeedbackEnabled)
                }
                ThemePickerRow(theme, settings::setSessionNamingTheme)
                FontSizeStepperRow(fontSize, settings::setTerminalFontSize)
                ScrollbackPickerRow(scrollback, settings::setTerminalScrollbackLines)
            }

            // 2) About
            if (SettingsSection.ABOUT in visibleSections) {
                SectionHeader("About")
                ValueRow(label = "Version", value = appVersion)
                ValueRow(label = "Build", value = buildNumber)
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

/**
 * The sections of [SettingsScreen], so a host can hide the ones it has no
 * backing capability for.
 */
/**
 * The screen's sections. There is no Connection section: every enabled server
 * is live in the multi-server workspace, so "auto-connect to the last server"
 * has nothing left to mean (spec §8.4).
 */
enum class SettingsSection { GENERAL, ABOUT }

// MARK: - Section building blocks

@Composable
private fun SectionHeader(title: String) {
    Spacer(Modifier.height(16.dp))
    Text(
        text = title.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary,
    )
    HorizontalDivider()
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * A label + static value row (the About section's version/build lines).
 */
@Composable
private fun ValueRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Text(
            value,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// MARK: - General-section controls

@Composable
private fun ThemePickerRow(theme: SessionNamingTheme, onSelect: (SessionNamingTheme) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Session Names", style = MaterialTheme.typography.bodyLarge)
        Row {
            TextButton(onClick = { expanded = true }) {
                Text(theme.displayName)
                Icon(Icons.Filled.ArrowDropDown, contentDescription = "Pick theme")
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                SessionNamingTheme.entries.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option.displayName) },
                        onClick = {
                            onSelect(option)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun FontSizeStepperRow(fontSize: Double, onChange: (Double) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Terminal Font Size", style = MaterialTheme.typography.bodyLarge)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "${fontSize.toInt()} pt",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            IconButton(
                onClick = { onChange((fontSize - 1).coerceAtLeast(FONT_MIN)) },
                enabled = fontSize > FONT_MIN,
            ) { Icon(Icons.Filled.Remove, contentDescription = "Decrease font size", modifier = Modifier.size(20.dp)) }
            IconButton(
                onClick = { onChange((fontSize + 1).coerceAtMost(FONT_MAX)) },
                enabled = fontSize < FONT_MAX,
            ) { Icon(Icons.Filled.Add, contentDescription = "Increase font size", modifier = Modifier.size(20.dp)) }
        }
    }
}

@Composable
private fun ScrollbackPickerRow(scrollback: Int, onSelect: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Terminal Scrollback", style = MaterialTheme.typography.bodyLarge)
        Row {
            TextButton(onClick = { expanded = true }) {
                Text(scrollbackLabel(scrollback))
                Icon(Icons.Filled.ArrowDropDown, contentDescription = "Pick scrollback")
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                SCROLLBACK_OPTIONS.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(scrollbackLabel(option)) },
                        onClick = {
                            onSelect(option)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

private fun scrollbackLabel(lines: Int): String = "%,d lines".format(lines)

private const val FONT_MIN = 8.0
private const val FONT_MAX = 16.0
private val SCROLLBACK_OPTIONS = listOf(1_000, 5_000, 10_000, 25_000)
