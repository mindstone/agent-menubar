import Foundation

/// Decoded Factory hook payload, augmented by the bridge script with iTerm env vars.
struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String
    let cwd: String?
    let transcriptPath: String?
    let message: String?            // Notification.message
    let prompt: String?             // UserPromptSubmit.prompt
    let itermSessionId: String?     // injected by bridge from $ITERM_SESSION_ID
    let termProgram: String?        // injected by bridge

    enum CodingKeys: String, CodingKey {
        case hookEventName  = "hook_event_name"
        case sessionId      = "session_id"
        case cwd            = "cwd"
        case transcriptPath = "transcript_path"
        case message        = "message"
        case prompt         = "prompt"
        case itermSessionId = "iterm_session_id"
        case termProgram    = "term_program"
    }
}
