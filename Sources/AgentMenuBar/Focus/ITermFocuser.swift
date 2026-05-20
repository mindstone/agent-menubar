import Foundation
import AppKit

enum ITermFocusResult: Equatable {
    case ok
    case notFound(uuidTried: String)
    case appleScriptFailed(String)
}

enum ITermFocuser {
    /// `ITERM_SESSION_ID` env var format is `w<window>t<tab>p<pane>:<UUID>`
    /// (e.g. `w0t1p0:E7F6CDC5-...`). iTerm's AppleScript `unique id of session`
    /// returns only the bare UUID. Strip the prefix so the comparison matches.
    static func uuidFromRaw(_ raw: String) -> String {
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }

    /// Activate iTerm and select the window/tab/session whose unique id matches
    /// the prefix-stripped UUID. Tries the original raw string as a fallback.
    @discardableResult
    static func focus(itermSessionId rawId: String) -> ITermFocusResult {
        let uuid = uuidFromRaw(rawId)
        let escaped = uuid.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRaw = rawId.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sid to (unique id of s) as string
                        if sid is equal to "\(escaped)" or sid is equal to "\(escapedRaw)" then
                            select w
                            select t
                            select s
                            try
                                set index of w to 1
                            end try
                            activate
                            try
                                tell application "System Events"
                                    tell process "iTerm2"
                                        set frontmost to true
                                        perform action "AXRaise" of window 1
                                    end tell
                                end tell
                            end try
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
            NSLog("AgentMenuBar.ITermFocuser: NSAppleScript init failed")
            return .appleScriptFailed("NSAppleScript init failed")
        }
        let result = apple.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.ITermFocuser: AppleScript error: \(msg)  raw=\(rawId)  uuid=\(uuid)")
            return .appleScriptFailed(msg)
        }
        let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("AgentMenuBar.ITermFocuser: result=\(value)  raw=\(rawId)  uuid=\(uuid)")
        if value == "ok" { return .ok }
        return .notFound(uuidTried: uuid)
    }
}
