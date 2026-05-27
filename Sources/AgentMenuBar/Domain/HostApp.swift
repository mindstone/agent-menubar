import Foundation

/// The macOS application an agent session was launched from — i.e. the app the
/// menu bar should bring forward when the user clicks the row. Today these
/// are all terminals, but the abstraction is intentionally "host app" so a
/// future row could route to e.g. a web IDE tab or a native editor.
enum HostApp: String, CaseIterable {
    case iTerm
    case ghostty
    case unknown

    var displayName: String {
        switch self {
        case .iTerm:   return "iTerm"
        case .ghostty: return "Ghostty"
        case .unknown: return ""
        }
    }
}
