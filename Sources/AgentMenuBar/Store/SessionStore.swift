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
                // shortly and stable filtering takes over from there. Only
                // while it's still active — a closed surface with no resolved
                // tab belongs in the resumable list, not the live one.
                if Self.isActive(s) { orphans.append(s) }
            } else if let raw = s.itermSessionId, !raw.isEmpty {
                let uuid = ITermFocuser.uuidFromRaw(raw)
                guard aliveItermTabs[uuid] != nil else { continue }
                let key = "iterm:\(uuid)"
                latestPerTab[key] = latestPerTab[key].map { Self.tabRepresentative($0, s) } ?? s
            } else if Self.isActive(s) {
                // No terminal binding at all. Show only while active (e.g. an
                // agent started outside a supported terminal); once it ends it
                // drops out of the live list and, if resumable, surfaces under
                // `resumableSessions`.
                orphans.append(s)
            }
        }
        let merged = Array(latestPerTab.values) + orphans
        return merged.sorted(by: Self.sessionSort)
    }

    /// Live work for the main list: running or waiting-for-input sessions only.
    /// Finished/closed sessions deliberately drop out of the main list — a
    /// reopened iTerm restores old tabs, which would otherwise resurrect every
    /// finished run as a "DONE" row — and move to `resumableSessions` instead.
    var activeSessions: [DroidSession] {
        visibleSessions.filter(Self.isActive)
    }

    /// Closed sessions offered for recovery in the collapsed "Closed" section:
    /// finished/stale, resumable by their agent, transcript still on disk.
    /// Deduped to the most recent per (agent, working directory) and capped, so
    /// a repo with dozens of past runs collapses to one recoverable row.
    var resumableSessions: [DroidSession] {
        Self.resumableClosed(
            from: sessions,
            transcriptExists: { self.transcriptResumable($0) },
            cap: maxResumableRows
        )
    }

    /// A session is resumable only while its transcript still exists (the agent
    /// CLIs garbage-collect old transcripts). When we have no transcript path —
    /// some agents don't report one over hooks — we can't disprove it, so allow
    /// a best-effort resume attempt.
    private func transcriptResumable(_ s: DroidSession) -> Bool {
        guard let p = s.transcriptPath else { return true }
        return FileManager.default.fileExists(atPath: p.path)
    }

    static func isActive(_ s: DroidSession) -> Bool {
        s.status == .running || s.status == .waitingForInput
    }

    static func isClosed(_ s: DroidSession) -> Bool {
        s.status == .finished || s.status == .stale
    }

    /// Pure dedup/cap for the resumable list: at most one row per (agent, cwd)
    /// — the most recent — across all closed, agent-resumable sessions whose
    /// transcript still exists, then the newest `cap` overall. Static + injected
    /// `transcriptExists` so it's testable without the filesystem.
    static func resumableClosed(from sessions: [DroidSession],
                                transcriptExists: (DroidSession) -> Bool,
                                cap: Int) -> [DroidSession] {
        var byKey: [String: DroidSession] = [:]
        for s in sessions where isClosed(s) && ResumeCommand.supportsResume(s.agentKind) {
            let key = "\(s.agentKind.rawValue)\u{1}\(s.cwd.path)"
            if let existing = byKey[key], resumableSortDate(existing) >= resumableSortDate(s) { continue }
            byKey[key] = s
        }
        return byKey.values
            .filter(transcriptExists)
            .sorted { resumableSortDate($0) > resumableSortDate($1) }
            .prefix(max(0, cap))
            .map { $0 }
    }

    private static func resumableSortDate(_ s: DroidSession) -> Date {
        s.finishedAt ?? s.lastEventAt
    }

    private let pruneTTL: TimeInterval = 24 * 60 * 60      // forget finished sessions after 24h
    private let resumablePruneTTL: TimeInterval = 30 * 24 * 60 * 60 // keep resumable closed sessions ~30d
    private let maxResumableRows = 15                      // cap the resumable list to the most recent
    private let staleAfterIdle: TimeInterval = 60 * 60     // mark loaded running session stale if > 1h silent
    private let bannerTTL: TimeInterval = 4
    private let inventoryRefreshInterval: TimeInterval = 5
    /// When the app launched. Finished sessions that completed before this —
    /// e.g. prior-run rows whose iTerm tab got restored — don't count toward the
    /// menu-bar / notch "done" indicator, so old completions don't resurrect it.
    private let launchedAt = Date()
    private let saveDebounce = DispatchQueue(label: "AgentMenuBar.SessionStore.save")
    private var bannerClearTask: Task<Void, Never>?
    private var inventoryTimer: Timer?
    /// Memoized background-task counts per transcript path, keyed by file size +
    /// mtime so the 5s pending-finish sweep only re-reads a transcript that has
    /// actually grown. Transcripts only ever append, so a matching (size,mtime)
    /// guarantees an unchanged scan result.
    private var bgScanCache: [String: (size: UInt64, mtime: Date, outstanding: Int)] = [:]

    init() {
        let loaded = SessionStorePersistence.load()
        self.sessions = reconcile(loaded)
        self.menuBarState = computeBarState()
        save()
        startInventoryRefresh()
        mergeDiscoveredSessions()
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
                // Drain pending finishes before aging so a session whose native
                // background tasks just completed (no hook fires for that) flips
                // to DONE cleanly instead of being eligible for staling.
                let finished = self.resolvePendingFinishes(now: Date())
                let aged = self.ageStaleSessions()
                if aged || finished { self.sortSessions() }
                if setChanged || aged || finished { self.recomputeBarState() }
                if titlesChanged || aged || finished { self.save() }
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
        // Only count completions from this run, not restored old finished rows.
        let finished = visible.filter {
            $0.status == .finished && ($0.finishedAt ?? .distantPast) >= launchedAt
        }.count
        if running + waiting + finished == 0 { return .idle }
        return .active(running: running, waiting: waiting, finished: finished)
    }

    private func recomputeBarState() {
        let next = computeBarState()
        if next != menuBarState { menuBarState = next }
    }

    // MARK: - Pending finish (defer "completed" until background work drains)

    /// A relation key for the terminal that hosts a session. Unlike the
    /// alive-gated grouping in `visibleSessions`, this is purely structural: two
    /// sessions in the same tab/surface share a key whether or not the tab is in
    /// the current inventory. `nil` when the session has no terminal binding.
    static func tabKey(for s: DroidSession) -> String? {
        if let id = s.ghosttyTerminalId, !id.isEmpty { return "ghostty:\(id)" }
        if let sid = s.ghosttySurfaceId, !sid.isEmpty { return "ghostty-surface:\(sid)" }
        if let raw = s.itermSessionId, !raw.isEmpty { return "iterm:\(ITermFocuser.uuidFromRaw(raw))" }
        return nil
    }

    /// True if another live (`.running`/`.waitingForInput`) session shares this
    /// session's terminal tab — the harness shells out codex/cursor/nested-claude
    /// sub-agents into the driver's own tab, so a finished driver isn't really
    /// done while a sibling is still working. Relation is by tab only, never cwd
    /// (a worktree harness shares a cwd across unrelated agents). Pure: decided
    /// entirely from the passed session set.
    static func hasLiveRelatedSubAgent(_ s: DroidSession, in sessions: [DroidSession]) -> Bool {
        guard let key = tabKey(for: s) else { return false }
        return sessions.contains { other in
            other.id != s.id
                && (other.status == .running || other.status == .waitingForInput)
                && tabKey(for: other) == key
        }
    }

    /// Outstanding native background tasks for a transcript, memoized by file
    /// size + mtime. `0` on any read/parse failure (fail-open).
    @MainActor
    private func transcriptOutstanding(_ url: URL) -> Int {
        let path = url.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        if let cached = bgScanCache[path], cached.size == size, cached.mtime == mtime {
            return cached.outstanding
        }
        let outstanding = TranscriptBackgroundScan.outstanding(url)
        bgScanCache[path] = (size: size, mtime: mtime, outstanding: outstanding)
        return outstanding
    }

    /// Combined gate: a turn-ended session is still busy if a live sibling shares
    /// its tab, or its transcript shows native background tasks still running.
    @MainActor
    private func hasOutstandingBackgroundWork(_ s: DroidSession) -> Bool {
        if Self.hasLiveRelatedSubAgent(s, in: sessions) { return true }
        if let t = s.transcriptPath, transcriptOutstanding(t) > 0 { return true }
        return false
    }

    /// Sweep every pending-finish session (`turnEndedAt != nil`): finish the ones
    /// whose background work has drained, leave the rest pending. Returns true if
    /// anything transitioned. Cheap — the pending set is tiny and transcript
    /// reads are memoized.
    @MainActor
    @discardableResult
    private func resolvePendingFinishes(now: Date) -> Bool {
        var changed = false
        for i in sessions.indices where sessions[i].turnEndedAt != nil {
            guard sessions[i].status == .running else {
                // No longer pending-running (e.g. resumed and re-finished, or
                // ended): clear the marker without firing a completion.
                sessions[i].turnEndedAt = nil
                changed = true
                continue
            }
            if !hasOutstandingBackgroundWork(sessions[i]) {
                sessions[i].status = .finished
                sessions[i].finishedAt = now
                sessions[i].turnEndedAt = nil
                changed = true
            }
        }
        return changed
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
        // Resolve the touched session's just-deferred finish (from a `Stop`) and
        // any same-tab sibling that this event may have released — e.g. a
        // sub-agent's own `Stop` is what unblocks a pending driver.
        resolvePendingFinishes(now: now)
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
        // Clear the closed/recoverable rows. This only tidies the current list:
        // any session whose transcript is still on disk is re-discovered on the
        // next launch, so clearing isn't destructive to recoverability.
        sessions.removeAll { Self.isClosed($0) }
        recomputeBarState()
        save()
    }

    @MainActor
    func remove(_ session: DroidSession) {
        sessions.removeAll { $0.id == session.id }
        recomputeBarState()
        save()
    }

    /// Relaunch a closed session: open a new terminal tab in its original
    /// working directory and run the agent's resume command. When the resumed
    /// process emits its `SessionStart` hook it carries the same session id, so
    /// `apply` re-binds this row as a live session automatically.
    @MainActor
    func resume(_ session: DroidSession) {
        guard let line = ResumeCommand.shellLine(
            for: session.agentKind,
            sessionId: session.id,
            cwd: session.cwd.path
        ) else {
            showBanner(.warning, "\(session.agentKind.displayName) can't be resumed from the menu bar.")
            return
        }
        let host = session.hostApp
        let label = session.repoName ?? session.cwd.lastPathComponent
        Task.detached {
            let result = TerminalLauncher.launch(shellLine: line, preferred: host)
            await MainActor.run {
                switch result {
                case .ok:
                    self.showBanner(.info, "Resuming \(label)…")
                case .failed(let msg):
                    self.showBanner(.warning, "Couldn't open a terminal to resume: \(msg)")
                }
            }
        }
    }

    // MARK: - Reconciliation & persistence

    /// Recover resumable sessions the app never observed over hooks (e.g. ones
    /// started before hooks were installed, or after the persisted store was
    /// lost) by scanning each agent's on-disk transcripts. Runs once at launch,
    /// off the main thread; only adds sessions whose id we don't already track.
    private func mergeDiscoveredSessions() {
        Task.detached { [weak self] in
            let discovered = SessionDiscovery.scan()
            guard !discovered.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let known = Set(self.sessions.map(\.id))
                var added = false
                for d in discovered where !known.contains(d.id) {
                    let s = DroidSession(
                        id: d.id,
                        agentKind: d.agentKind,
                        cwd: d.cwd,
                        repoName: RepoInfo.repoName(forCwd: d.cwd),
                        itermSessionId: nil,
                        ghosttySurfaceId: nil,
                        status: .stale,
                        lastEvent: d.firstPrompt ?? "Closed session",
                        lastEventAt: d.lastActivity,
                        startedAt: d.lastActivity,
                        finishedAt: d.lastActivity,
                        transcriptPath: d.transcriptPath,
                        attentionRaisedAt: nil,
                        firstPrompt: d.firstPrompt
                    )
                    self.sessions.append(s)
                    added = true
                }
                if added {
                    self.sortSessions()
                    self.save()
                }
            }
        }
    }

    private func reconcile(_ loaded: [DroidSession]) -> [DroidSession] {
        let now = Date()
        return loaded.compactMap { (s: DroidSession) -> DroidSession? in
            // Drop ancient finished sessions. Resumable ones (agent supports
            // `--resume` and the transcript is still on disk) are kept far
            // longer so the user can relaunch them after a restart; once the
            // agent garbage-collects the transcript they revert to the short
            // TTL and age out like any other dead row.
            if s.status == .finished || s.status == .stale {
                let endTime = s.finishedAt ?? s.lastEventAt
                let resumable = ResumeCommand.supportsResume(s.agentKind) && transcriptResumable(s)
                let ttl = resumable ? resumablePruneTTL : pruneTTL
                if now.timeIntervalSince(endTime) > ttl { return nil }
            }
            var copy = s
            // A pending-finish row loaded from disk: we can't trust live sibling
            // state across a restart, so re-check the transcript only. If no
            // native background work remains (or the transcript is gone), the
            // work really did finish while we were off — finalize it. Otherwise
            // leave it pending and let the staleness rule below be the backstop.
            // This is the app-quit cleanup path.
            if copy.turnEndedAt != nil && copy.status == .running {
                let outstanding = copy.transcriptPath.map { TranscriptBackgroundScan.outstanding($0) } ?? 0
                if outstanding == 0 {
                    copy.status = .finished
                    copy.finishedAt = copy.finishedAt ?? copy.turnEndedAt ?? copy.lastEventAt
                    copy.turnEndedAt = nil
                }
            }
            // Mark anything that was "running"/"waitingForInput" pre-restart but has been
            // silent for too long as stale — process is likely gone.
            if copy.status == .running || copy.status == .waitingForInput {
                if now.timeIntervalSince(copy.lastEventAt) > staleAfterIdle {
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
