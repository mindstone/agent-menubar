import Foundation
import AppKit

enum GhosttyFocusByCwdResult: Equatable {
    case ok(resolvedTerminalId: String?)
    case notFound
    case appleScriptFailed(String)
}

enum GhosttyFocuser {
    /// Focus by AppleScript-side terminal UUID. Reuses the iTerm result enum
    /// for UI uniformity. The dictionary's `focus` command raises the owning
    /// window for free, but `activate` is also called for cross-Space safety.
    @discardableResult
    static func focus(ghosttyTerminalId terminalId: String) -> ITermFocusResult {
        guard GhosttyInventory.isGhosttyRunning() else {
            return .notFound(uuidTried: terminalId)
        }
        let escaped = terminalId.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Ghostty"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in terminals of t
                        if (id of s as string) is equal to "\(escaped)" then
                            focus s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """

        var errorDict: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            NSLog("AgentMenuBar.GhosttyFocuser: NSAppleScript init failed")
            return .appleScriptFailed("NSAppleScript init failed")
        }
        let result = apple.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.GhosttyFocuser: AppleScript error: \(msg)  id=\(terminalId)")
            return .appleScriptFailed(msg)
        }
        let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("AgentMenuBar.GhosttyFocuser: result=\(value)  id=\(terminalId)")
        if value == "ok" { return .ok }
        return .notFound(uuidTried: terminalId)
    }

    /// Fallback path used when we don't yet have an AppleScript UUID for a
    /// session. Asks Ghostty to focus the first terminal whose
    /// `working directory` matches and returns that terminal's UUID so the
    /// caller can cache it on the session.
    static func focusByCwd(_ cwd: String) -> GhosttyFocusByCwdResult {
        guard GhosttyInventory.isGhosttyRunning() else { return .notFound }
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Ghostty"
            activate
            try
                set matches to (every terminal whose working directory is "\(escaped)")
                if (count of matches) > 0 then
                    set tgt to item 1 of matches
                    focus tgt
                    return (id of tgt) as string
                end if
            end try
            return ""
        end tell
        """
        var errorDict: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            return .appleScriptFailed("NSAppleScript init failed")
        }
        let result = apple.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.GhosttyFocuser: cwd focus AppleScript error: \(msg)  cwd=\(cwd)")
            return .appleScriptFailed(msg)
        }
        let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .notFound }
        return .ok(resolvedTerminalId: value)
    }
}
