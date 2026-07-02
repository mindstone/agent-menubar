import Foundation
import AppKit

/// Launching differs by terminal: iTerm exposes `write text` through
/// AppleScript, so we drive it the same way `ITermFocuser` does. Ghostty's
/// AppleScript dictionary can focus terminals but cannot inject text, and it
/// has no IPC to run a command in an already-running instance — `open --args`
/// is only honored on a cold start. So the Ghostty path launches via `open`
/// when Ghostty is installed and not yet running, and otherwise falls back to
/// the always-reliable iTerm launcher rather than silently doing nothing.
enum TerminalLaunchResult: Equatable {
    case ok
    case failed(String)
}

enum TerminalLauncher {
    /// Open a new tab/window in the preferred terminal and run `shellLine`.
    /// `preferred` is the session's host app; fall back sensibly when it's
    /// unknown or its terminal app isn't available.
    @discardableResult
    static func launch(shellLine: String, preferred: HostApp) -> TerminalLaunchResult {
        switch preferred {
        case .iTerm:
            return launchITerm(shellLine: shellLine)
        case .ghostty:
            return launchGhostty(shellLine: shellLine)
        case .unknown:
            return launchITerm(shellLine: shellLine)
        }
    }

    /// Best-effort Ghostty launch. `open -n -a Ghostty --args -e …` reliably
    /// opens a new window running a command on a *cold* start; a running
    /// instance ignores the args, so we fall back to iTerm in that case to
    /// avoid a silent no-op. Untested locally (Ghostty isn't installed on the
    /// dev machine) — kept defensive so any failure routes to the iTerm path.
    private static func launchGhostty(shellLine: String) -> TerminalLaunchResult {
        guard let appURL = ghosttyAppURL() else {
            return launchITermFallback(shellLine: shellLine, reason: "Ghostty isn't installed")
        }
        if GhosttyInventory.isGhosttyRunning() {
            return launchITermFallback(shellLine: shellLine, reason: "Ghostty is already running and can't accept a launch command")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", "-a", appURL.path, "--args", "-e", "/bin/zsh", "-l", "-c", shellLine]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return launchITermFallback(shellLine: shellLine, reason: "Ghostty launch failed: \(error.localizedDescription)")
        }
        if proc.terminationStatus != 0 {
            return launchITermFallback(shellLine: shellLine, reason: "Ghostty launch exited \(proc.terminationStatus)")
        }
        NSLog("AgentMenuBar.TerminalLauncher: Ghostty launch ok")
        return .ok
    }

    private static func ghosttyAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/Ghostty.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private static func launchITermFallback(shellLine: String, reason: String) -> TerminalLaunchResult {
        let result = launchITerm(shellLine: shellLine)
        if result == .ok { return .ok }
        if case let .failed(message) = result {
            return .failed("\(reason); iTerm fallback failed: \(message)")
        }
        return result
    }

    private static func launchITerm(shellLine: String) -> TerminalLaunchResult {
        let escaped = escapeForAppleScriptStringLiteral(shellLine)
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window to write text "\(escaped)"
        end tell
        """

        var errorDict: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            NSLog("AgentMenuBar.TerminalLauncher: NSAppleScript init failed")
            return .failed("NSAppleScript init failed")
        }
        _ = apple.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? String(describing: err)
            NSLog("AgentMenuBar.TerminalLauncher: AppleScript error: \(msg)")
            return .failed(msg)
        }
        NSLog("AgentMenuBar.TerminalLauncher: iTerm launch ok")
        return .ok
    }

    /// Make `s` safe to embed inside an AppleScript double-quoted string.
    /// In AppleScript, only `\\` and `\"` are meaningful escapes inside `"..."`,
    /// so we backslash-escape `\` first and then `"`. Order matters; reversing
    /// would re-escape the backslash we just introduced.
    private static func escapeForAppleScriptStringLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
