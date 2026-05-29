import Foundation

protocol AgentEventAdapter {
    func apply(_ event: HookEvent, to session: inout DroidSession, now: Date)
}

enum AgentEventAdapters {
    static func adapter(for kind: AgentKind) -> AgentEventAdapter {
        switch kind {
        case .factoryDroid: return FactoryDroidEventAdapter()
        case .codex:        return CodexEventAdapter()
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
}
