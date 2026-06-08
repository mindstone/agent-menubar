import Foundation

/// Decoded agent hook payload, augmented by the bridge script with terminal env vars.
struct HookEvent: Decodable {
    let agentKind: AgentKind
    let hookEventName: String
    let sessionId: String
    let cwd: String?
    let transcriptPath: String?
    let message: String?              // Notification.message
    let prompt: String?               // UserPromptSubmit.prompt
    let source: String?               // Codex SessionStart.source
    let toolName: String?             // PreToolUse / PostToolUse
    let lastAssistantMessage: String?  // Codex Stop.last_assistant_message
    let permissionMode: String?        // Codex permission_mode
    let turnId: String?                // Codex turn_id
    let status: String?                // Cursor stop.status: completed | aborted | error
    let itermSessionId: String?       // injected by bridge from $ITERM_SESSION_ID
    let ghosttySurfaceId: String?     // injected by bridge from $GHOSTTY_SURFACE_ID
    let termProgram: String?          // injected by bridge

    enum CodingKeys: String, CodingKey {
        case agentKind        = "agent_kind"
        case hookEventName    = "hook_event_name"
        case sessionId        = "session_id"
        case cwd              = "cwd"
        case transcriptPath   = "transcript_path"
        case message          = "message"
        case prompt           = "prompt"
        case source           = "source"
        case toolName         = "tool_name"
        case lastAssistantMessage = "last_assistant_message"
        case permissionMode   = "permission_mode"
        case turnId           = "turn_id"
        case status           = "status"
        case itermSessionId   = "iterm_session_id"
        case ghosttySurfaceId = "ghostty_surface_id"
        case termProgram      = "term_program"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentKind = AgentKind.fromBridgeValue(try c.decodeIfPresent(String.self, forKey: .agentKind))
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        itermSessionId = try c.decodeIfPresent(String.self, forKey: .itermSessionId)
        ghosttySurfaceId = try c.decodeIfPresent(String.self, forKey: .ghosttySurfaceId)
        termProgram = try c.decodeIfPresent(String.self, forKey: .termProgram)
    }
}
