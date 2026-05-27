import Foundation

struct DroidSession: Codable, Identifiable, Equatable {
    let id: String              // Agent session_id (canonical)
    var agentKind: AgentKind
    var cwd: URL
    var repoName: String?
    var itermSessionId: String?
    /// Ghostty's per-surface u64 hex id captured by the bridge from
    /// `$GHOSTTY_SURFACE_ID`. Note that Ghostty's AppleScript dictionary
    /// exposes a *different* identifier (a UUID per terminal surface), and
    /// there is currently no public mapping between the two, so this field
    /// alone can't be matched against the AppleScript inventory.
    /// `ghosttyTerminalId` below is the resolved AppleScript-side UUID,
    /// looked up once at first sight by working-directory match.
    var ghosttySurfaceId: String?
    var ghosttyTerminalId: String?
    var status: SessionStatus
    var lastEvent: String
    var lastEventAt: Date
    var startedAt: Date
    var finishedAt: Date?
    var transcriptPath: URL?
    var attentionRaisedAt: Date?

    /// The user's first prompt for this session, captured once on the first
    /// `UserPromptSubmit` and never overwritten. Surfaced in the popover as
    /// the "task" subtitle so a row at a glance says what the agent was
    /// asked to do, separate from whatever it's currently chatting about.
    var firstPrompt: String?

    /// The host terminal's tab/session title at last inventory poll. Picked
    /// up from iTerm's `name of session` or Ghostty's `title of terminal`,
    /// refreshed on the same 5s cycle as the alive-id sweep. Optional because
    /// older sessions on disk won't have it until the next poll lands.
    var tabTitle: String?

    /// Which macOS app this session was launched from, derived from whichever
    /// id was captured by the bridge. Used by the UI to show a per-row label
    /// and by `focus(_:)` to dispatch to the right adapter.
    var hostApp: HostApp {
        if (ghosttySurfaceId ?? "").isEmpty == false || (ghosttyTerminalId ?? "").isEmpty == false {
            return .ghostty
        }
        if (itermSessionId ?? "").isEmpty == false {
            return .iTerm
        }
        return .unknown
    }

    init(
        id: String,
        agentKind: AgentKind,
        cwd: URL,
        repoName: String?,
        itermSessionId: String?,
        ghosttySurfaceId: String?,
        ghosttyTerminalId: String? = nil,
        status: SessionStatus,
        lastEvent: String,
        lastEventAt: Date,
        startedAt: Date,
        finishedAt: Date?,
        transcriptPath: URL?,
        attentionRaisedAt: Date?,
        firstPrompt: String? = nil,
        tabTitle: String? = nil
    ) {
        self.id = id
        self.agentKind = agentKind
        self.cwd = cwd
        self.repoName = repoName
        self.itermSessionId = itermSessionId
        self.ghosttySurfaceId = ghosttySurfaceId
        self.ghosttyTerminalId = ghosttyTerminalId
        self.status = status
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.transcriptPath = transcriptPath
        self.attentionRaisedAt = attentionRaisedAt
        self.firstPrompt = firstPrompt
        self.tabTitle = tabTitle
    }

    enum CodingKeys: String, CodingKey {
        case id
        case agentKind
        case cwd
        case repoName
        case itermSessionId
        case ghosttySurfaceId
        case ghosttyTerminalId
        case status
        case lastEvent
        case lastEventAt
        case startedAt
        case finishedAt
        case transcriptPath
        case attentionRaisedAt
        case firstPrompt
        case tabTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentKind = try c.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .factoryDroid
        cwd = try c.decode(URL.self, forKey: .cwd)
        repoName = try c.decodeIfPresent(String.self, forKey: .repoName)
        itermSessionId = try c.decodeIfPresent(String.self, forKey: .itermSessionId)
        ghosttySurfaceId = try c.decodeIfPresent(String.self, forKey: .ghosttySurfaceId)
        ghosttyTerminalId = try c.decodeIfPresent(String.self, forKey: .ghosttyTerminalId)
        status = try c.decode(SessionStatus.self, forKey: .status)
        lastEvent = try c.decode(String.self, forKey: .lastEvent)
        lastEventAt = try c.decode(Date.self, forKey: .lastEventAt)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        transcriptPath = try c.decodeIfPresent(URL.self, forKey: .transcriptPath)
        attentionRaisedAt = try c.decodeIfPresent(Date.self, forKey: .attentionRaisedAt)
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        tabTitle = try c.decodeIfPresent(String.self, forKey: .tabTitle)
    }
}
