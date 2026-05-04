import Foundation

struct DroidSession: Codable, Identifiable, Equatable {
    let id: String              // Factory session_id (canonical)
    var cwd: URL
    var repoName: String?
    var itermSessionId: String?
    var status: SessionStatus
    var lastEvent: String
    var lastEventAt: Date
    var startedAt: Date
    var finishedAt: Date?
    var transcriptPath: URL?
    var attentionRaisedAt: Date?
}
