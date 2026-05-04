import Foundation

enum SessionStatus: String, Codable, Equatable {
    case running
    case waitingForInput
    case finished
    case stale
}

enum MenuBarState: Equatable {
    case idle
    case tracking(count: Int)
    case attention(count: Int, waiting: Int)
}
