package relay.feature.workspace

/**
 * Trims a rename-dialog entry to the name that should be stored, or null when the
 * entry holds no usable name.
 *
 * Mirrors the iOS alerts, which do the same two things inline:
 * ```swift
 * let trimmed = editedName.trimmingCharacters(in: .whitespaces)
 * if !trimmed.isEmpty { onRename(trimmed) }
 * ```
 * Kept as a pure function so both rename dialogs share one definition of "blank"
 * with the button-enabled state they drive — a dialog that greys out `Rename` on
 * one rule and stores on another is how a blank name slips through.
 */
fun sanitizedSessionName(raw: String): String? = raw.trim().ifEmpty { null }
