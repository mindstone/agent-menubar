import Foundation

protocol AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date)
}

enum AgentEventAdapters {
    static func adapter(for kind: AgentKind) -> AgentEventAdapter {
        switch kind {
        case .factoryDroid: return FactoryDroidEventAdapter()
        case .codex:        return CodexEventAdapter()
        case .cursor:       return CursorAgentEventAdapter()
        case .claudeCode:   return ClaudeCodeEventAdapter()
        case .unknown:      return GenericAgentEventAdapter()
        }
    }
}

struct FactoryDroidEventAdapter: AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            session.status = .running
            session.startedAt = now
            session.finishedAt = nil
            session.lastEvent = "Session started"
            session.attentionRaisedAt = nil

        case "Notification":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            session.lastEvent = event.message?.nilIfEmpty ?? "Waiting for input"

        case "UserPromptSubmit":
            applyPrompt(event.prompt, to: &session)

        case "Stop":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            if let t = session.transcriptPath, let tail = TranscriptReader.tailPreview(t) {
                session.lastEvent = tail
            } else {
                session.lastEvent = "Finished task"
            }

        case "SessionEnd":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            if session.lastEvent.isEmpty || session.lastEvent == "Starting…" {
                session.lastEvent = "Session ended"
            }

        case "PreToolUse":
            if event.toolName == "AskUser" {
                session.status = .waitingForInput
                session.finishedAt = nil
                session.attentionRaisedAt = now
                session.lastEvent = "Droid is asking you a question"
            }

        case "PostToolUse":
            if event.toolName == "AskUser" && session.status == .waitingForInput {
                session.status = .running
                session.finishedAt = nil
                session.attentionRaisedAt = nil
            }

        default:
            break
        }
    }
}

struct CodexEventAdapter: AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            session.status = .running
            session.startedAt = min(session.startedAt, now)
            session.finishedAt = nil
            session.attentionRaisedAt = nil
            if session.lastEvent.isEmpty || session.lastEvent == "Starting…" {
                session.lastEvent = event.sourceDescription ?? "Session started"
            }

        case "UserPromptSubmit":
            applyPrompt(event.prompt, to: &session)

        case "PermissionRequest":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            if let message = event.message?.nilIfEmpty {
                session.lastEvent = message
            } else if let tool = event.toolName?.nilIfEmpty {
                session.lastEvent = "Codex wants approval for \(tool)"
            } else {
                session.lastEvent = "Codex wants approval"
            }

        case "Notification":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            session.lastEvent = event.message?.nilIfEmpty ?? "Waiting for input"

        case "PreToolUse":
            if event.isUserInputRequest {
                session.status = .waitingForInput
                session.finishedAt = nil
                session.attentionRaisedAt = now
                session.lastEvent = event.message?.nilIfEmpty ?? "Codex is waiting for input"
            }

        case "PostToolUse":
            if session.status == .waitingForInput {
                session.status = .running
                session.finishedAt = nil
                session.attentionRaisedAt = nil
                session.lastEvent = "Working…"
            }

        case "Stop":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            if let summary = event.lastAssistantMessage?.firstMeaningfulLine(maxLength: 200) {
                session.lastEvent = summary
            } else if let t = session.transcriptPath, let tail = TranscriptReader.tailPreview(t) {
                session.lastEvent = tail
            } else {
                session.lastEvent = "Finished turn"
            }

        default:
            break
        }
    }
}

/// Cursor CLI (`cursor-agent`). Event names are camelCase, distinct from the
/// PascalCase set Factory Droid and Codex use. The CLI only fires a subset of
/// Cursor's documented hooks in interactive mode: `sessionStart`,
/// `beforeSubmitPrompt`, `beforeShellExecution`, `afterShellExecution`,
/// `afterFileEdit`, `postToolUse`, `stop`, and `sessionEnd`.
///
/// Cursor has no dedicated notification/permission-request event, and its
/// interactive question picker (`AskQuestion`) does not fire tool hooks, so the
/// only hook-observable "needs you" moment is a command/MCP approval gate
/// (`beforeShellExecution` / `beforeMCPExecution`). We treat those as
/// waiting-for-input and flip back to running once the command runs or any
/// tool completes. When the CLI auto-runs commands this shows as a brief
/// orange flicker rather than a sustained wait.
struct CursorAgentEventAdapter: AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date) {
        switch event.hookEventName {
        case "sessionStart":
            session.status = .running
            session.startedAt = min(session.startedAt, now)
            session.finishedAt = nil
            session.attentionRaisedAt = nil
            if session.lastEvent.isEmpty || session.lastEvent == "Starting…" {
                session.lastEvent = "Session started"
            }

        case "beforeSubmitPrompt":
            applyPrompt(event.prompt, to: &session)

        case "beforeShellExecution":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            if let cmd = event.message?.firstMeaningfulLine(maxLength: 120) {
                session.lastEvent = "Wants to run: \(cmd)"
            } else {
                session.lastEvent = "Cursor wants to run a command"
            }

        case "beforeMCPExecution":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            session.lastEvent = event.message?.nilIfEmpty ?? "Cursor wants to use a tool"

        case "afterShellExecution", "afterMCPExecution":
            session.status = .running
            session.finishedAt = nil
            session.attentionRaisedAt = nil
            session.lastEvent = "Working…"

        case "afterFileEdit":
            session.status = .running
            session.finishedAt = nil
            session.attentionRaisedAt = nil
            session.lastEvent = "Editing files…"

        case "postToolUse":
            if session.status == .waitingForInput {
                session.status = .running
                session.finishedAt = nil
                session.attentionRaisedAt = nil
                session.lastEvent = "Working…"
            }

        case "stop":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            switch event.status {
            case "error":
                session.lastEvent = "Stopped with an error"
            case "aborted":
                session.lastEvent = "Cancelled"
            default:
                if let t = session.transcriptPath, let tail = TranscriptReader.tailPreview(t) {
                    session.lastEvent = tail
                } else {
                    session.lastEvent = "Finished turn"
                }
            }

        case "sessionEnd":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            if session.lastEvent.isEmpty || session.lastEvent == "Starting…" {
                session.lastEvent = "Session ended"
            }

        default:
            break
        }
    }
}

/// Anthropic Claude Code (`claude`). Hook event names are PascalCase and its
/// stdin payload already uses the field names HookEvent decodes
/// (`session_id`, `cwd`, `transcript_path`, `message`, `prompt`, `source`,
/// `tool_name`), so its bridge wrapper needs no normalization.
///
/// Claude Code is the cleanest mapping of the supported CLIs: it exposes both
/// `Notification` (permission prompts) and a dedicated `PermissionRequest`
/// event for the waiting signal, `PostToolUse` for the return to running, and a
/// turn-scoped `Stop`. We register Notification only for the genuine
/// needs-you types (`permission_prompt`/`elicitation_dialog`) so housekeeping
/// notifications like `auth_success` don't flip the row orange.
///
/// `idle_prompt` is deliberately *not* a waiting signal. Claude Code fires it
/// ~60s after `Stop` when the user hasn't replied yet — i.e. the turn is
/// already finished and rendered DONE. Treating "still idle" as fresh
/// waiting-for-input would repaint every completed turn orange (the attention
/// "question" state) with no actual question pending. We guard on
/// `notification_type` here in addition to scoping the registered matcher, so
/// a stale `~/.claude/settings.json` that still lists `idle_prompt` can't
/// reintroduce the false positive.
struct ClaudeCodeEventAdapter: AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            session.status = .running
            session.startedAt = min(session.startedAt, now)
            session.finishedAt = nil
            session.attentionRaisedAt = nil
            if session.lastEvent.isEmpty || session.lastEvent == "Starting…" {
                session.lastEvent = event.sourceDescription ?? "Session started"
            }

        case "UserPromptSubmit":
            applyPrompt(event.prompt, to: &session)

        case "Notification":
            // Idle nudge after a finished turn — not a real prompt. Leave the
            // resting state (DONE/running) untouched; see the type note above.
            if event.notificationType == "idle_prompt" { break }
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            session.lastEvent = event.message?.nilIfEmpty ?? "Waiting for input"

        case "PermissionRequest":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            if let message = event.message?.nilIfEmpty {
                session.lastEvent = message
            } else if let tool = event.toolName?.nilIfEmpty {
                session.lastEvent = "Claude needs permission to use \(tool)"
            } else {
                session.lastEvent = "Claude needs your permission"
            }

        case "PostToolUse":
            if session.status == .waitingForInput {
                session.status = .running
                session.finishedAt = nil
                session.attentionRaisedAt = nil
                session.lastEvent = "Working…"
            }

        case "Stop":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            if let t = session.transcriptPath, let tail = TranscriptReader.tailPreview(t) {
                session.lastEvent = tail
            } else {
                session.lastEvent = "Finished turn"
            }

        case "SessionEnd":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            if session.lastEvent.isEmpty || session.lastEvent == "Starting…" {
                session.lastEvent = "Session ended"
            }

        default:
            break
        }
    }
}

struct GenericAgentEventAdapter: AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            session.status = .running
            session.startedAt = now
            session.finishedAt = nil
            session.attentionRaisedAt = nil
            session.lastEvent = "Session started"
        case "UserPromptSubmit":
            applyPrompt(event.prompt, to: &session)
        case "Notification", "PermissionRequest":
            session.status = .waitingForInput
            session.finishedAt = nil
            session.attentionRaisedAt = now
            session.lastEvent = event.message?.nilIfEmpty ?? "Waiting for input"
        case "Stop", "SessionEnd":
            session.status = .finished
            session.finishedAt = now
            session.attentionRaisedAt = nil
            session.lastEvent = event.lastAssistantMessage?.firstMeaningfulLine(maxLength: 200) ?? "Finished turn"
        default:
            break
        }
    }
}

private func applyPrompt(_ prompt: String?, to session: inout DroidSession) {
    session.status = .running
    session.finishedAt = nil
    session.attentionRaisedAt = nil
    let line = prompt?.firstMeaningfulLine()
    session.lastEvent = line ?? "Working…"
    if (session.firstPrompt ?? "").isEmpty, let firstLine = line, !firstLine.isEmpty {
        session.firstPrompt = firstLine
    }
}

private extension HookEvent {
    var sourceDescription: String? {
        switch source {
        case "resume":  return "Session resumed"
        case "clear":   return "Session cleared"
        case "compact": return "Session compacted"
        case "startup": return "Session started"
        default:        return nil
        }
    }

    var isUserInputRequest: Bool {
        guard let name = toolName?.nilIfEmpty else { return false }
        switch name {
        case "request_user_input", "RequestUserInput":
            return true
        default:
            return false
        }
    }
}
