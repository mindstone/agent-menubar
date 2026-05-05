import Foundation
import SwiftUI

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [DroidSession] = []

    private let pruneTTL: TimeInterval = 24 * 60 * 60      // forget finished sessions after 24h
    private let staleAfterIdle: TimeInterval = 60 * 60     // mark loaded running session stale if > 1h silent
    private let saveDebounce = DispatchQueue(label: "DroidMenuBar.SessionStore.save")

    init() {
        let loaded = SessionStorePersistence.load()
        self.sessions = reconcile(loaded)
        save()
    }

    // MARK: - Derived UI state

    var menuBarState: MenuBarState {
        let active = sessions.filter { $0.status == .running || $0.status == .waitingForInput }
        let waiting = active.filter { $0.status == .waitingForInput }.count
        if active.isEmpty { return .idle }
        if waiting > 0 { return .attention(count: active.count, waiting: waiting) }
        return .tracking(count: active.count)
    }

    // MARK: - Event ingestion

    @MainActor
    func apply(_ event: HookEvent) {
        let now = Date()
        let cwdString = event.cwd ?? FileManager.default.currentDirectoryPath
        let cwdURL = URL(fileURLWithPath: cwdString)
        let transcriptURL = event.transcriptPath.map { URL(fileURLWithPath: $0) }

        var idx = sessions.firstIndex { $0.id == event.sessionId }
        if idx == nil {
            let new = DroidSession(
                id: event.sessionId,
                cwd: cwdURL,
                repoName: RepoInfo.repoName(forCwd: cwdURL),
                itermSessionId: event.itermSessionId?.nilIfEmpty,
                status: .running,
                lastEvent: "Starting…",
                lastEventAt: now,
                startedAt: now,
                finishedAt: nil,
                transcriptPath: transcriptURL,
                attentionRaisedAt: nil
            )
            sessions.insert(new, at: 0)
            idx = 0
        }
        var s = sessions[idx!]

        // Late-binding: keep first non-empty values.
        if (s.itermSessionId ?? "").isEmpty, let bound = event.itermSessionId?.nilIfEmpty {
            s.itermSessionId = bound
        }
        if s.transcriptPath == nil { s.transcriptPath = transcriptURL }
        s.lastEventAt = now

        switch event.hookEventName {
        case "SessionStart":
            s.status = .running
            s.startedAt = now
            s.lastEvent = "Session started"
            s.attentionRaisedAt = nil

        case "Notification":
            s.status = .waitingForInput
            s.attentionRaisedAt = now
            let msg = event.message?.nilIfEmpty ?? "Waiting for input"
            s.lastEvent = msg
            DroidNotifier.notify(
                title: "? Droid is asking — \(s.repoName ?? cwdURL.lastPathComponent)",
                body: msg,
                urgent: true
            )

        case "UserPromptSubmit":
            s.status = .running
            s.attentionRaisedAt = nil
            s.lastEvent = event.prompt?.firstMeaningfulLine() ?? "Working…"

        case "Stop":
            s.status = .finished
            s.attentionRaisedAt = nil
            let preview: String
            if let t = s.transcriptPath, let tail = TranscriptReader.tailPreview(t) {
                preview = tail
            } else {
                preview = "Finished task"
            }
            s.lastEvent = preview
            DroidNotifier.notify(
                title: "Droid finished — \(s.repoName ?? cwdURL.lastPathComponent)",
                body: preview,
                urgent: false
            )

        case "SessionEnd":
            s.status = .finished
            s.finishedAt = now
            s.attentionRaisedAt = nil
            // Don't overwrite a useful lastEvent from Stop with "Session ended".
            if s.lastEvent.isEmpty || s.lastEvent == "Starting…" {
                s.lastEvent = "Session ended"
            }

        case "PreToolUse", "PostToolUse", "SubagentStop", "PreCompact":
            // Bump activity but don't change visible state.
            break

        default:
            // Unknown event types: swallow but keep activity timestamp.
            break
        }

        sessions[idx!] = s
        sortSessions()
        save()
    }

    // MARK: - Actions

    @MainActor
    func focus(_ session: DroidSession) {
        guard let raw = session.itermSessionId, !raw.isEmpty else {
            DroidNotifier.notify(
                title: "No iTerm tab bound",
                body: "This droid wasn't started inside iTerm, or ITERM_SESSION_ID was missing.",
                urgent: false
            )
            return
        }
        Task.detached {
            let result = ITermFocuser.focus(itermSessionId: raw)
            await MainActor.run {
                switch result {
                case .ok:
                    break
                case .notFound(let uuid):
                    DroidNotifier.notify(
                        title: "Couldn't find that iTerm tab",
                        body: "Session \(uuid.prefix(8))… isn't open in iTerm anymore. The tab was probably closed.",
                        urgent: false
                    )
                case .appleScriptFailed(let msg):
                    DroidNotifier.notify(
                        title: "Couldn't focus iTerm",
                        body: "AppleScript automation may need to be allowed in System Settings → Privacy & Security → Automation. (\(msg.prefix(120)))",
                        urgent: false
                    )
                }
            }
        }
    }

    @MainActor
    func clearFinished() {
        sessions.removeAll { $0.status == .finished || $0.status == .stale }
        save()
    }

    @MainActor
    func remove(_ session: DroidSession) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    // MARK: - Reconciliation & persistence

    private func reconcile(_ loaded: [DroidSession]) -> [DroidSession] {
        let now = Date()
        return loaded.compactMap { (s: DroidSession) -> DroidSession? in
            // Drop ancient finished sessions.
            if s.status == .finished || s.status == .stale {
                let endTime = s.finishedAt ?? s.lastEventAt
                if now.timeIntervalSince(endTime) > pruneTTL { return nil }
            }
            // Mark anything that was "running"/"waitingForInput" pre-restart but has been
            // silent for too long as stale — process is likely gone.
            var copy = s
            if s.status == .running || s.status == .waitingForInput {
                if now.timeIntervalSince(s.lastEventAt) > staleAfterIdle {
                    copy.status = .stale
                }
            }
            return copy
        }
    }

    private func sortSessions() {
        sessions.sort { a, b in
            // Waiting first, then running, then finished/stale.
            func rank(_ st: SessionStatus) -> Int {
                switch st {
                case .waitingForInput: return 0
                case .running:         return 1
                case .finished:        return 2
                case .stale:           return 3
                }
            }
            let ra = rank(a.status), rb = rank(b.status)
            if ra != rb { return ra < rb }
            return a.lastEventAt > b.lastEventAt
        }
    }

    private func save() {
        let snapshot = sessions
        saveDebounce.async {
            SessionStorePersistence.save(snapshot)
        }
    }
}
