import Foundation

/// Recognizes Claude Code's `<task-notification>` wrapper — the synthetic
/// "user" turn the CLI uses to redeliver a background task/sub-agent's
/// completion into the conversation (see `TranscriptBackgroundScan`, which
/// parses the same wrapper to count outstanding work). Raw, it's multi-line
/// internal markup (`<task-id>`, `<status>`, `<summary>`, …); callers that
/// surface transcript/prompt text as a one-line status should show
/// `friendlySummary(in:)`'s result instead of the raw wrapper.
enum TaskNotificationText {
    /// `nil` when `text` isn't a task-notification wrapper — callers should
    /// fall back to their normal handling of `text` in that case.
    static func friendlySummary(in text: String) -> String? {
        guard text.contains("<task-notification>") else { return nil }
        let status = taggedValue("status", in: text)
        let summary = taggedValue("summary", in: text)
        switch (status, summary) {
        case let (status?, summary?):
            return "Background task \(status): \(summary)"
        case let (nil, summary?):
            return summary
        case let (status?, nil):
            return "Background task \(status)"
        case (nil, nil):
            return "Background task update"
        }
    }

    private static func taggedValue(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let raw = text[open.upperBound..<close.lowerBound]
        // Callers show this inline in a one-line status field, so collapse any
        // internal newlines/whitespace runs a multi-line tag value might carry
        // (e.g. a `<summary>` an agent wrote across several lines) — otherwise
        // this leaks the same kind of multi-line text this type exists to fix.
        let value = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
