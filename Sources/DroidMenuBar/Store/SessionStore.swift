import Foundation
import SwiftUI

struct TransientBanner: Equatable {
    enum Tone { case info, warning }
    let id = UUID()
    let tone: Tone
    let text: String
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [DroidSession] = []
    @Published private(set) var menuBarState: MenuBarState = .idle
    @Published var banner: TransientBanner?

    private let pruneTTL: TimeInterval = 24 * 60 * 60      // forget finished sessions after 24h
    private let staleAfterIdle: TimeInterval = 60 * 60     // mark loaded running session stale if > 1h silent
    private let bannerTTL: TimeInterval = 4
    private let saveDebounce = DispatchQueue(label: "DroidMenuBar.SessionStore.save")
    private var bannerClearTask: Task<Void, Never>?

    init() {
        let loaded = SessionStorePersistence.load()
        self.sessions = reconcile(loaded)
        self.menuBarState = Self.computeBarState(from: self.sessions)
        save()
    }

    // MARK: - Derived UI state

    private static func computeBarState(from sessions: [DroidSession]) -> MenuBarState {
        let active = sessions.filter { $0.status == .running || $0.status == .waitingForInput }
        let waiting = active.filter { $0.status == .waitingForInput }.count
        if active.isEmpty { return .idle }
        if waiting > 0 { return .attention(count: active.count, waiting: waiting) }
        return .tracking(count: active.count)
    }

    private func recomputeBarState() {
        let next = Self.computeBarState(from: sessions)
        if next != menuBarState { menuBarState = next }
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
            s.lastEvent = event.message?.nilIfEmpty ?? "Waiting for input"

        case "UserPromptSubmit":
            s.status = .running
            s.attentionRaisedAt = nil
            s.lastEvent = event.prompt?.firstMeaningfulLine() ?? "Working…"

        case "Stop":
            s.status = .finished
            s.attentionRaisedAt = nil
            if let t = s.transcriptPath, let tail = TranscriptReader.tailPreview(t) {
                s.lastEvent = tail
            } else {
                s.lastEvent = "Finished task"
            }

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
        recomputeBarState()
        save()
    }

    // MARK: - Actions

    @MainActor
    func focus(_ session: DroidSession) {
        guard let raw = session.itermSessionId, !raw.isEmpty else {
            showBanner(.warning, "No iTerm tab bound — this droid wasn't started inside iTerm.")
            return
        }
        Task.detached {
            let result = ITermFocuser.focus(itermSessionId: raw)
            await MainActor.run {
                switch result {
                case .ok:
                    break
                case .notFound:
                    self.showBanner(.warning, "iTerm tab not found — it was probably closed.")
                case .appleScriptFailed:
                    self.showBanner(.warning, "Couldn't talk to iTerm. Allow automation in System Settings → Privacy & Security → Automation.")
                }
            }
        }
    }

    @MainActor
    private func showBanner(_ tone: TransientBanner.Tone, _ text: String) {
        let b = TransientBanner(tone: tone, text: text)
        banner = b
        bannerClearTask?.cancel()
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.bannerTTL ?? 4) * 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if self.banner?.id == b.id { self.banner = nil }
            }
        }
    }

    @MainActor
    func dismissBanner() {
        bannerClearTask?.cancel()
        banner = nil
    }

    @MainActor
    func clearFinished() {
        sessions.removeAll { $0.status == .finished || $0.status == .stale }
        recomputeBarState()
        save()
    }

    @MainActor
    func remove(_ session: DroidSession) {
        sessions.removeAll { $0.id == session.id }
        recomputeBarState()
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
