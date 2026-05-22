import Foundation

struct DroidSession: Codable, Identifiable, Equatable {
    let id: String              // Factory session_id (canonical)
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
    /// the "task" subtitle so a row at a glance says what the droid was
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
}
