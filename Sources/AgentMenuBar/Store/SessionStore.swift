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
    /// `unique id of session` → current `name of session`. The keys are the
    /// alive-tab set used by `visibleSessions`; the values feed each row's
    /// tab-title meta line.
    @Published private(set) var aliveItermTabs: [String: String] = [:]
    /// `id of terminal` (AppleScript UUID) → current `title of terminal`.
    @Published private(set) var aliveGhosttyTabs: [String: String] = [:]
    @Published var banner: TransientBanner?

    /// Sessions to show in the UI: one entry per currently-open terminal tab,
    /// representing the most recent agent run in that tab. Sessions without a
    /// terminal binding are always passed through.
    var visibleSessions: [DroidSession] {
        var latestPerTab: [String: DroidSession] = [:]
        var orphans: [DroidSession] = []
        for s in sessions {
            if let id = s.ghosttyTerminalId, !id.isEmpty {
                guard aliveGhosttyTabs[id] != nil else { continue }
                let key = "ghostty:\(id)"
                latestPerTab[key] = latestPerTab[key].map { Self.tabRepresentative($0, s) } ?? s
            } else if (s.ghosttySurfaceId ?? "").isEmpty == false {
                // First-sight Ghostty session whose AppleScript UUID hasn't
                // been resolved yet. Show it optimistically so the user
                // doesn't see a flicker on session start; the resolve task
                // kicked off in `apply` will populate ghosttyTerminalId
                // shortly and stable filtering takes over from there.
                orphans.append(s)
            } else if let raw = s.itermSessionId, !raw.isEmpty {
                let uuid = ITermFocuser.uuidFromRaw(raw)
                guard aliveItermTabs[uuid] != nil else { continue }
                let key = "iterm:\(uuid)"
                latestPerTab[key] = latestPerTab[key].map { Self.tabRepresentative($0, s) } ?? s
            } else {
                orphans.append(s)
            }
        }
        let merged = Array(latestPerTab.values) + orphans
        return merged.sorted(by: Self.sessionSort)
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
            async let iterm = ITermInventory.fetchAliveTabs()
            async let ghostty = GhosttyInventory.fetchAliveTabs()
            let (aliveIterm, aliveGhostty) = await (iterm, ghostty)
            await MainActor.run { [weak self] in
                guard let self else { return }
                var setChanged = false
                if aliveIterm != self.aliveItermTabs {
                    self.aliveItermTabs = aliveIterm
                    setChanged = true
                }
                if aliveGhostty != self.aliveGhosttyTabs {
                    self.aliveGhosttyTabs = aliveGhostty
                    setChanged = true
                }
                let titlesChanged = self.syncTabTitlesIntoSessions()
                let aged = self.ageStaleSessions()
                if aged { self.sortSessions() }
                if setChanged || aged { self.recomputeBarState() }
                if titlesChanged || aged { self.save() }
            }
        }
    }

    /// Push current tab-title values from the alive-tabs dicts onto each
    /// `DroidSession.tabTitle`. Returns `true` if any session's title
    /// changed, so the caller can persist. Runs on the main actor only.
    @MainActor
    private func syncTabTitlesIntoSessions() -> Bool {
        var anyChanged = false
        for i in sessions.indices {
            let next: String?
            if let id = sessions[i].ghosttyTerminalId, !id.isEmpty {
                next = aliveGhosttyTabs[id]
            } else if let raw = sessions[i].itermSessionId, !raw.isEmpty {
                let uuid = ITermFocuser.uuidFromRaw(raw)
                next = aliveItermTabs[uuid]
            } else {
                next = nil
            }
            // Only update for terminals we currently know about. An absent
            // mapping means the tab is gone (already filtered out by
            // visibleSessions) or the terminal app is closed — preserve the
            // last-known title in either case so closed rows still read.
            guard let resolved = next else { continue }
            let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String? = trimmed.isEmpty ? nil : trimmed
            if sessions[i].tabTitle != value {
                sessions[i].tabTitle = value
                anyChanged = true
            }
        }
        return anyChanged
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
                agentKind: event.agentKind,
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
        if s.agentKind == .unknown && event.agentKind != .unknown {
            s.agentKind = event.agentKind
        }

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

        AgentEventAdapters.adapter(for: s.agentKind).apply(event, to: &s, now: now)

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
            showBanner(.warning, "No terminal tab bound — this agent wasn't started inside a supported terminal.")
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

    /// Periodic sweep (driven by the inventory timer) that ages out running /
    /// waiting sessions which have gone silent. This is the continuous
    /// counterpart to `reconcile`, which only runs once at launch — without it,
    /// a dropped `Stop`/`SessionEnd` (app offline, socket timeout, missing `jq`,
    /// crashed agent) would leave a session lit forever. Conservative on
    /// purpose: a session whose terminal tab is still open is never aged (it may
    /// be legitimately mid-turn with no intervening hooks — a long build or model
    /// call). Returns `true` if anything changed.
    @MainActor
    private func ageStaleSessions(now: Date = Date()) -> Bool {
        var changed = false
        for i in sessions.indices {
            let s = sessions[i]
            let alive = isTabAlive(s)
            let bound = hasTerminalBinding(s)
            guard Self.shouldStale(s, tabAlive: alive, hasBinding: bound, idleTTL: staleAfterIdle, now: now) else { continue }
            sessions[i].status = .stale
            if sessions[i].finishedAt == nil { sessions[i].finishedAt = now }
            changed = true
        }
        return changed
    }

    @MainActor
    private func hasTerminalBinding(_ s: DroidSession) -> Bool {
        if let id = s.ghosttyTerminalId, !id.isEmpty { return true }
        if (s.ghosttySurfaceId ?? "").isEmpty == false { return true }
        if let raw = s.itermSessionId, !raw.isEmpty { return true }
        return false
    }

    @MainActor
    private func isTabAlive(_ s: DroidSession) -> Bool {
        if let id = s.ghosttyTerminalId, !id.isEmpty { return aliveGhosttyTabs[id] != nil }
        // Unresolved Ghostty surface (AppleScript UUID not bound yet): assume
        // alive so we don't age a brand-new session before its resolve lands.
        if (s.ghosttySurfaceId ?? "").isEmpty == false { return true }
        if let raw = s.itermSessionId, !raw.isEmpty {
            return aliveItermTabs[ITermFocuser.uuidFromRaw(raw)] != nil
        }
        return false
    }

    private func sortSessions() {
        sessions.sort(by: Self.sessionSort)
    }

    /// Pick the session that should represent a terminal tab when several share
    /// it. With the Claude-as-driver harness, a single tab can host the driver
    /// plus the sub-agent CLIs it shells out to (`codex`, `cursor`, nested
    /// `claude`), each a distinct `session_id` on the same `iterm`/`ghostty` id.
    /// Choosing by recency alone lets a just-finished sub-agent's `Stop` mask a
    /// still-running driver (row flips to DONE mid-task) or vice-versa. Picking
    /// by `sessionSort` (status first, then recency) keeps the most important
    /// state visible: a waiting sub-agent surfaces, an active driver is never
    /// hidden by a finished sibling, and `.stale` rows never win over live ones.
    static func tabRepresentative(_ a: DroidSession, _ b: DroidSession) -> DroidSession {
        sessionSort(a, b) ? a : b
    }

    /// Pure decision for `ageStaleSessions`. Ages an active session to `.stale`
    /// only when it has been silent past `idleTTL` *and* its terminal tab is
    /// gone (or it never had a resolvable binding). A live tab is left alone.
    static func shouldStale(_ s: DroidSession, tabAlive: Bool, hasBinding: Bool, idleTTL: TimeInterval, now: Date) -> Bool {
        guard s.status == .running || s.status == .waitingForInput else { return false }
        guard now.timeIntervalSince(s.lastEventAt) > idleTTL else { return false }
        return hasBinding ? !tabAlive : true
    }

    private static func sessionSort(_ a: DroidSession, _ b: DroidSession) -> Bool {
        let ra = statusRank(a.status), rb = statusRank(b.status)
        if ra != rb { return ra < rb }
        return sortDate(for: a) > sortDate(for: b)
    }

    private static func statusRank(_ status: SessionStatus) -> Int {
        switch status {
        case .waitingForInput: return 0
        case .running:         return 1
        case .finished:        return 2
        case .stale:           return 3
        }
    }

    private static func sortDate(for session: DroidSession) -> Date {
        switch session.status {
        case .finished, .stale:
            return session.finishedAt ?? session.lastEventAt
        case .waitingForInput, .running:
            return session.lastEventAt
        }
    }

    private func save() {
        let snapshot = sessions
        saveDebounce.async {
            SessionStorePersistence.save(snapshot)
        }
    }
}
