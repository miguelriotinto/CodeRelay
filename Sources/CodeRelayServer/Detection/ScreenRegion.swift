import Foundation

/// Slices a `ScreenSnapshot` into the named region a manifest rule targets.
/// Ported from herdr's `src/detect/manifest.rs` region slicers. Operates on
/// line arrays (split on "\n", empty subsequences kept) and re-joins with "\n"
/// to mirror the Rust byte-substring behaviour.
enum ScreenRegion {

    static func slice(_ spec: String, snapshot: ScreenSnapshot) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "osc_title":   return snapshot.oscTitle
        case "osc_progress": return snapshot.oscProgress
        default: break
        }

        let content = snapshot.text
        switch trimmed {
        case "whole_recent":
            return content
        case "after_last_prompt_marker":
            return afterLastPromptMarker(content)
        case "prompt_box_body":
            return promptBoxBody(content)
        case "after_last_horizontal_rule":
            return afterLastHorizontalRule(content)
        default:
            if let count = regionCount(trimmed, prefix: "bottom_non_empty_lines") {
                return bottomNonEmptyLines(content, count: count)
            }
            return ""
        }
    }

    // MARK: - Rules

    /// herdr `is_horizontal_rule`: trimmed non-empty, starts with ≥1 U+2500
    /// box-drawing dash, and either the suffix after the leading run is empty
    /// or the leading run is ≥3 chars.
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix { $0 == "\u{2500}" }.count
        guard ruleChars > 0 else { return false }
        let suffix = String(trimmed.dropFirst(ruleChars)).trimmingCharacters(in: .whitespaces)
        return suffix.isEmpty || ruleChars >= 3
    }

    // MARK: - Slicers

    private static func lines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func isNonEmpty(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func regionCount(_ spec: String, prefix: String) -> Int? {
        guard spec.hasPrefix(prefix + "("), spec.hasSuffix(")") else { return nil }
        let inner = spec.dropFirst(prefix.count + 1).dropLast()
        return Int(inner)
    }

    /// From the Nth-from-last non-empty line to the end (inclusive of blanks
    /// in between). Empty string if there are no non-empty lines.
    private static func bottomNonEmptyLines(_ content: String, count: Int) -> String {
        let all = lines(content)
        let nonEmptyIndices = all.indices.filter { isNonEmpty(all[$0]) }
        guard !nonEmptyIndices.isEmpty else { return "" }
        let startIndex = nonEmptyIndices.suffix(count).first ?? nonEmptyIndices[0]
        return all[startIndex...].joined(separator: "\n")
    }

    /// Everything after the last codex prompt line (`›` or `› …`); whole
    /// content if there is none.
    private static func afterLastPromptMarker(_ content: String) -> String {
        let all = lines(content)
        guard let index = all.lastIndex(where: isCodexPromptLine) else { return content }
        return all[(index + 1)...].joined(separator: "\n")
    }

    private static func isCodexPromptLine(_ line: String) -> Bool {
        line == "\u{203A}" || line.hasPrefix("\u{203A} ")
    }

    /// Everything after the last horizontal rule; whole content if none.
    private static func afterLastHorizontalRule(_ content: String) -> String {
        let all = lines(content)
        guard let index = all.lastIndex(where: isHorizontalRule) else { return content }
        return all[(index + 1)...].joined(separator: "\n")
    }

    /// Lines strictly between the 2nd-from-bottom horizontal rule and the next
    /// rule below it (or end). Empty if there are fewer than two rules.
    private static func promptBoxBody(_ content: String) -> String {
        let all = lines(content)
        guard let top = promptBoxTopBorderIndex(all) else { return "" }
        let rest = all[(top + 1)...]
        let endRelative = rest.firstIndex(where: isHorizontalRule) ?? all.endIndex
        return all[(top + 1)..<endRelative].joined(separator: "\n")
    }

    /// Index of the 2nd horizontal rule scanning from the bottom up.
    private static func promptBoxTopBorderIndex(_ all: [String]) -> Int? {
        var borderCount = 0
        for index in stride(from: all.count - 1, through: 0, by: -1) where isHorizontalRule(all[index]) {
            borderCount += 1
            if borderCount == 2 { return index }
        }
        return nil
    }
}
