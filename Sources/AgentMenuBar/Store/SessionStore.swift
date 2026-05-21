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
    @Published private(set) var aliveItermUUIDs: Set<String> = []
    @Published private(set) var aliveGhosttyIDs: Set<String> = []
    @Published var banner: TransientBanner?

    /// Sessions to show in the UI: one entry per currently-open terminal tab,
    /// representing the most recent droid run in that tab. Sessions without a
    /// terminal binding (e.g. droid invoked outside a recognised terminal) are
    /// always passed through.
    var visibleSessions: [DroidSession] {
        var latestPerTab: [String: DroidSession] = [:]
        var orphans: [DroidSession] = []
        for s in sessions {
            if let id = s.ghosttyTerminalId, !id.isEmpty {
                guard aliveGhosttyIDs.contains(id) else { continue }
                let key = "ghostty:\(id)"
                if let existing = latestPerTab[key], existing.lastEventAt >= s.lastEventAt {
                    continue
                }
                latestPerTab[key] = s
            } else if (s.ghosttySurfaceId ?? "").isEmpty == false {
                // First-sight Ghostty session whose AppleScript UUID hasn't
                // been resolved yet. Show it optimistically so the user
                // doesn't see a flicker on session start; the resolve task
                // kicked off in `apply` will populate ghosttyTerminalId
                // shortly and stable filtering takes over from there.
                orphans.append(s)
            } else if let raw = s.itermSessionId, !raw.isEmpty {
                let uuid = ITermFocuser.uuidFromRaw(raw)
                guard aliveItermUUIDs.contains(uuid) else { continue }
                let key = "iterm:\(uuid)"
                if let existing = latestPerTab[key], existing.lastEventAt >= s.lastEventAt {
                    continue
                }
                latestPerTab[key] = s
            } else {
                orphans.append(s)
            }
        }
        let merged = Array(latestPerTab.values) + orphans
        return merged.sorted { a, b in
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

    private let pruneTTL: TimeInterval = 24 * 60 * 60      // forget finished sessions after 24h
    private let staleAfterIdle: TimeInterval = 60 * 60     // mark loaded running session stale if > 1h silent
    private let bannerTTL: TimeInterval = 4
    private let inventoryRefreshInterval: TimeInterval = 5
    private let saveDebounce = DispatchQueue(label: "AgentMenuBar.SessionStore.save")
    private var bannerClearTask: Task<Void, Never>?
    private var inventoryTimer: Timer?

    init() {
        let loaded = SessionStorePersistence.load()
        self.sessions = reconcile(loaded)
        self.menuBarState = computeBarState()
        save()
        startInventoryRefresh()
    }

    deinit {
        inventoryTimer?.invalidate()
    }

    // MARK: - Terminal inventory

    private func startInventoryRefresh() {
        refreshTerminalInventory()
        inventoryTimer = Timer.scheduledTimer(withTimeInterval: inventoryRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTerminalInventory()
        }
    }

    private func refreshTerminalInventory() {
        Task.detached { [weak self] in
            async let iterm = ITermInventory.fetchAliveUUIDs()
            async let ghostty = GhosttyInventory.fetchAliveIDs()
            let (aliveIterm, aliveGhostty) = await (iterm, ghostty)
            await MainActor.run { [weak self] in
                guard let self else { return }
                var changed = false
                if aliveIterm != self.aliveItermUUIDs {
                    self.aliveItermUUIDs = aliveIterm
                    changed = true
                }
                if aliveGhostty != self.aliveGhosttyIDs {
                    self.aliveGhosttyIDs = aliveGhostty
                    changed = true
                }
                if changed { self.recomputeBarState() }
            }
        }
    }

    /// Bind a session's `ghosttyTerminalId` (the AppleScript-side UUID) by
    /// asking Ghostty for the terminal whose `working directory` matches the
    /// session's cwd. Run off the main actor; results may arrive before or
    /// after subsequent hooks for the same session.
    private func scheduleGhosttyResolve(for sessionId: String, cwd: String) {
        Task.detached { [weak self] in
            let resolved = GhosttyInventory.resolveTerminalId(forCwd: cwd)
            guard let resolved else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let idx = self.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
                if (self.sessions[idx].ghosttyTerminalId ?? "").isEmpty {
                    self.sessions[idx].ghosttyTerminalId = resolved
                    self.recomputeBarState()
                    self.save()
                }
            }
        }
    }

    // MARK: - Derived UI state

    private func computeBarState() -> MenuBarState {
        let visible = visibleSessions
        let running = visible.filter { $0.status == .running }.count
        let waiting = visible.filter { $0.status == .waitingForInput }.count
        let finished = visible.filter { $0.status == .finished }.count
        if running + waiting + finished == 0 { return .idle }
        return .active(running: running, waiting: waiting, finished: finished)
    }

    private func recomputeBarState() {
        let next = computeBarState()
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
        var resolveGhostty = false
        if idx == nil {
            let new = DroidSession(
                id: event.sessionId,
                cwd: cwdURL,
                repoName: RepoInfo.repoName(forCwd: cwdURL),
                itermSessionId: event.itermSessionId?.nilIfEmpty,
                ghosttySurfaceId: event.ghosttySurfaceId?.nilIfEmpty,
                status: .running,
                lastEvent: "Starting…",
                lastEventAt: now,
                startedAt: now,
                finishedAt: nil,
                transcriptPath: transcriptURL,
                attentionRaisedAt: nil
            )
            if (new.ghosttySurfaceId ?? "").isEmpty == false {
                resolveGhostty = true
            }
            sessions.insert(new, at: 0)
            idx = 0
        }
        var s = sessions[idx!]

        // Late-binding: keep first non-empty values.
        if (s.itermSessionId ?? "").isEmpty, let bound = event.itermSessionId?.nilIfEmpty {
            s.itermSessionId = bound
        }
        if (s.ghosttySurfaceId ?? "").isEmpty, let bound = event.ghosttySurfaceId?.nilIfEmpty {
            s.ghosttySurfaceId = bound
            resolveGhostty = true
        }
        // Also resolve any session whose surfaceId is set but whose terminalId
        // isn't (e.g. loaded from disk after a previous run, or one where the
        // first resolve attempt failed because Ghostty wasn't running yet).
        if (s.ghosttySurfaceId ?? "").isEmpty == false && (s.ghosttyTerminalId ?? "").isEmpty {
            resolveGhostty = true
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
            // Stop fires after every model turn. From the user's POV, between
            // turns the droid is idle and effectively "done" with its current
            // task — show it as finished. The next UserPromptSubmit will flip
            // it back to running.
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
            if s.lastEvent.isEmpty || s.lastEvent == "Starting…" {
                s.lastEvent = "Session ended"
            }

        case "PreToolUse":
            // The AskUser tool blocks the model while it waits for the user to
            // pick from an interactive choice list — this is the in-conversation
            // equivalent of a permission Notification. Mirror that as waiting
            // for input so the menu bar flashes ❓.
            if event.toolName == "AskUser" {
                s.status = .waitingForInput
                s.attentionRaisedAt = now
                s.lastEvent = "Droid is asking you a question"
            }

        case "PostToolUse":
            // AskUser just got resolved by the user picking an answer — flip
            // back to running until Stop fires for the final reply.
            if event.toolName == "AskUser" && s.status == .waitingForInput {
                s.status = .running
                s.attentionRaisedAt = nil
            }

        case "SubagentStop", "PreCompact":
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

        if resolveGhostty {
            scheduleGhosttyResolve(for: s.id, cwd: cwdURL.path)
        }
    }

    // MARK: - Actions

    @MainActor
    func focus(_ session: DroidSession) {
        if let id = session.ghosttyTerminalId, !id.isEmpty {
            focusGhostty(sessionId: session.id, terminalId: id, cwdFallback: session.cwd.path)
            return
        }
        if (session.ghosttySurfaceId ?? "").isEmpty == false {
            // Resolve hasn't completed yet — try a one-shot cwd-based focus
            // and resolve in the same trip.
            focusGhostty(sessionId: session.id, terminalId: nil, cwdFallback: session.cwd.path)
            return
        }

        guard let raw = session.itermSessionId, !raw.isEmpty else {
            showBanner(.warning, "No terminal tab bound — this droid wasn't started inside a supported terminal.")
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
    private func focusGhostty(sessionId: String, terminalId: String?, cwdFallback: String) {
        Task.detached {
            // Try the resolved AppleScript UUID first when we have one.
            if let terminalId {
                let result = GhosttyFocuser.focus(ghosttyTerminalId: terminalId)
                if case .ok = result { return }
                // Fall through to cwd-based focus on miss.
            }
            let result = GhosttyFocuser.focusByCwd(cwdFallback)
            await MainActor.run {
                switch result {
                case .ok(let resolvedId):
                    if let resolvedId, let idx = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                        if (self.sessions[idx].ghosttyTerminalId ?? "").isEmpty {
                            self.sessions[idx].ghosttyTerminalId = resolvedId
                            self.save()
                        }
                    }
                case .notFound:
                    self.showBanner(.warning, "Ghostty terminal not found — it was probably closed.")
                case .appleScriptFailed:
                    self.showBanner(.warning, "Couldn't talk to Ghostty. Allow automation in System Settings → Privacy & Security → Automation.")
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
