import Foundation

enum SessionStatus: String, Codable, Equatable {
    case running
    case waitingForInput
    case finished
    case stale
}

enum MenuBarState: Equatable {
    case idle
    case active(running: Int, waiting: Int, finished: Int)

    var hasAttention: Bool {
        if case .active(_, let waiting, _) = self, waiting > 0 { return true }
        return false
    }
}
