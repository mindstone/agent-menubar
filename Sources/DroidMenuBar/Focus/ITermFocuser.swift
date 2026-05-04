import Foundation
import AppKit

enum ITermFocusError: Error {
    case notFound
    case appleScriptFailed(String)
}

enum ITermFocuser {
    /// Activate iTerm and select the window/tab/session whose unique id matches.
    /// Returns true on success.
    @discardableResult
    static func focus(itermSessionId uuid: String) -> Bool {
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique id of s) is "\(uuid)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        let result = apple.executeAndReturnError(&error)
        if error != nil { return false }
        return result.stringValue == "ok"
    }
}
