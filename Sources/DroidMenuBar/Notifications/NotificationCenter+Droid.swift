import Foundation

/// Lightweight wrapper around `osascript -e 'display notification ...'`.
/// We use osascript on purpose: a SwiftPM-built executable has no Info.plist
/// or signed bundle id, so UNUserNotificationCenter can refuse to deliver.
/// osascript-driven notifications work without entitlements; they are routed
/// via the system 'Script Editor' notification source. Good enough for v1.
enum DroidNotifier {
    static func notify(title: String, body: String, urgent: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let safeTitle = escape(title)
        let safeBody  = escape(body)
        var script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        if urgent {
            script += " sound name \"Glass\""
        }
        task.arguments = ["-e", script]
        do { try task.run() } catch {
            NSLog("DroidNotifier: osascript failed: \(error)")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
