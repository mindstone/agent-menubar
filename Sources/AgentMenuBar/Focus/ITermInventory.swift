import Foundation

enum ITermInventory {
    static func fetchAliveUUIDs() -> Set<String> {
        let script = """
        tell application "iTerm"
            set ids to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set end of ids to ((unique id of s) as string)
                    end repeat
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return ids as text
        end tell
        """
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            NSLog("AgentMenuBar.ITermInventory: NSAppleScript init failed")
            return []
        }
        let result = apple.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.ITermInventory: AppleScript error: %@", msg)
            return []
        }
        let raw = result.stringValue ?? ""
        let set = Set(
            raw.split(separator: "\n")
               .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
               .filter { !$0.isEmpty }
        )
        NSLog("AgentMenuBar.ITermInventory: fetched %d alive uuids", set.count)
        return set
    }
}
