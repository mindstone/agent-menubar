import Foundation
import AppKit

enum GhosttyInventory {
    /// AppleScript-side UUIDs of every currently-open Ghostty terminal surface.
    static func fetchAliveIDs() -> Set<String> {
        // Issuing `tell application "Ghostty"` against a non-running Ghostty
        // would auto-launch it, which we never want from a 5s-timer poll.
        guard isGhosttyRunning() else { return [] }

        let script = """
        tell application "Ghostty"
            set ids to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in terminals of t
                        set end of ids to ((id of s) as string)
                    end repeat
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return ids as text
        end tell
        """
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            NSLog("AgentMenuBar.GhosttyInventory: NSAppleScript init failed")
            return []
        }
        let result = apple.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.GhosttyInventory: AppleScript error: %@", msg)
            return []
        }
        let raw = result.stringValue ?? ""
        let set = Set(
            raw.split(separator: "\n")
               .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
               .filter { !$0.isEmpty }
        )
        NSLog("AgentMenuBar.GhosttyInventory: fetched %d alive ids", set.count)
        return set
    }

    /// Look up the AppleScript-side UUID for the terminal whose
    /// `working directory` matches the given path. Used at first-sight to bind
    /// a hook event's `$GHOSTTY_SURFACE_ID` (u64) to the AppleScript UUID,
    /// since Ghostty 1.3.2 doesn't expose a mapping between the two.
    /// At session start the agent's cwd and the surface's working directory
    /// are guaranteed to match — this is the only reliable bind point.
    static func resolveTerminalId(forCwd cwd: String) -> String? {
        guard isGhosttyRunning() else { return nil }
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Ghostty"
            try
                set matches to (every terminal whose working directory is "\(escaped)")
                if (count of matches) > 0 then
                    return (id of (item 1 of matches)) as string
                end if
            end try
            return ""
        end tell
        """
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return nil }
        let result = apple.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.GhosttyInventory: resolveTerminalId error: %{public}@  cwd=%{public}@", msg, cwd)
            return nil
        }
        let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func isGhosttyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }
    }
}
