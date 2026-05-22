import Foundation
import AppKit

enum ITermInventory {
    /// Map of every alive iTerm session's `unique id` to its current `name`
    /// (the tab/session title shown to the user). iTerm auto-updates `name`
    /// from `\e]2;…\a` escapes the shell emits, so for most users it reflects
    /// the running command without any manual labelling.
    static func fetchAliveTabs() -> [String: String] {
        // `tell application "iTerm"` against a non-running iTerm would
        // auto-launch it. Skip the AppleScript when it isn't running so the
        // 5s inventory poll stays passive for users who don't have iTerm open.
        guard isItermRunning() else { return [:] }

        // Each line in the result is `<unique id>\t<name>`. Two namespace
        // collisions to be aware of:
        //   - `tab` inside `tell application "iTerm"` resolves to the iTerm
        //     `tab` class, not the U+0009 character constant, so we bind
        //     U+0009 to a uniquely-named variable (`SEP`) *outside* the tell
        //     block. AppleScript identifiers are case-insensitive, so
        //     anything resembling an iTerm class name (`tab`, `window`,
        //     `session`) would also be shadowed.
        //   - `lines` would collide with iTerm's `lines` selector and
        //     trigger "-10006: Can't set every line to {}".
        let script = """
        set SEP to ASCII character 9
        tell application "iTerm"
            set acc to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sid to (unique id of s) as string
                        set snm to ""
                        try
                            set snm to (name of s) as string
                        end try
                        set end of acc to sid & SEP & snm
                    end repeat
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return acc as text
        end tell
        """
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            NSLog("AgentMenuBar.ITermInventory: NSAppleScript init failed")
            return [:]
        }
        let result = apple.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.ITermInventory: AppleScript error: %@", msg)
            return [:]
        }
        let dict = parseIdTitleLines(result.stringValue ?? "")
        NSLog("AgentMenuBar.ITermInventory: fetched \(dict.count) alive tabs")
        return dict
    }

    static func isItermRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }
    }

    /// Shared parser for `<id>\t<title>\n` AppleScript outputs. Returns the
    /// last-write-wins mapping; duplicate ids are not expected from either
    /// terminal but won't crash if they happen.
    static func parseIdTitleLines(_ raw: String) -> [String: String] {
        var dict: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let id = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let title = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            dict[id] = title
        }
        return dict
    }
}
