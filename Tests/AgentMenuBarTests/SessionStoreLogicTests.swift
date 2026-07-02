import XCTest
@testable import AgentMenuBar

/// Tests for the pure decision functions behind per-tab collapsing and the
/// staleness sweep — the two pieces that keep state correct when a single
/// terminal tab hosts a Claude driver plus the sub-agent CLIs it spawns, and
/// when a session's terminating hook never arrives.
final class SessionStoreLogicTests: XCTestCase {

    private func session(
        id: String,
        status: SessionStatus,
        lastEventAt: Date,
        iterm: String? = "iterm-1",
        ghosttySurface: String? = nil,
        ghosttyTerminal: String? = nil
    ) -> DroidSession {
        DroidSession(
            id: id,
            agentKind: .claudeCode,
            cwd: URL(fileURLWithPath: "/tmp"),
            repoName: nil,
            itermSessionId: iterm,
            ghosttySurfaceId: ghosttySurface,
            ghosttyTerminalId: ghosttyTerminal,
            status: status,
            lastEvent: "x",
            lastEventAt: lastEventAt,
            startedAt: lastEventAt,
            finishedAt: status == .finished ? lastEventAt : nil,
            transcriptPath: nil,
            attentionRaisedAt: nil
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    // MARK: - tabRepresentative (nested-agent collapsing)

    /// The core driver-vs-sub-agent case: a sub-agent finished more recently than
    /// the driver last emitted, but the driver is still running. The running
    /// driver must remain the tab's representative, not the finished sub-agent.
    func testRunningDriverBeatsMoreRecentFinishedSubAgent() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0)
        let subAgent = session(id: "sub", status: .finished, lastEventAt: t1)
        XCTAssertEqual(SessionStore.tabRepresentative(driver, subAgent).id, "driver")
        XCTAssertEqual(SessionStore.tabRepresentative(subAgent, driver).id, "driver")
    }

    /// A sub-agent blocked on a permission gate must surface over a running
    /// driver so the attention state isn't lost.
    func testWaitingSubAgentSurfacesOverRunningDriver() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0)
        let subAgent = session(id: "sub", status: .waitingForInput, lastEventAt: t1)
        XCTAssertEqual(SessionStore.tabRepresentative(driver, subAgent).id, "sub")
    }

    /// Same status falls back to recency.
    func testSameStatusPicksMostRecent() {
        let older = session(id: "old", status: .running, lastEventAt: t0)
        let newer = session(id: "new", status: .running, lastEventAt: t1)
        XCTAssertEqual(SessionStore.tabRepresentative(older, newer).id, "new")
    }

    /// A stale session never represents a tab over a live one, even if the stale
    /// one's last event was more recent.
    func testStaleNeverBeatsActive() {
        let active = session(id: "active", status: .running, lastEventAt: t0)
        let stale = session(id: "stale", status: .stale, lastEventAt: t1)
        XCTAssertEqual(SessionStore.tabRepresentative(active, stale).id, "active")
    }

    // MARK: - shouldStale (continuous aging)

    private let idleTTL: TimeInterval = 60 * 60

    func testSilentBoundSessionWithDeadTabIsAged() {
        let s = session(id: "s", status: .running, lastEventAt: t0)
        let now = t0.addingTimeInterval(idleTTL + 1)
        XCTAssertTrue(SessionStore.shouldStale(s, tabAlive: false, hasBinding: true, idleTTL: idleTTL, now: now))
    }

    func testSilentBoundSessionWithLiveTabIsKept() {
        // A long-running turn with no intervening hooks but an open tab — leave it.
        let s = session(id: "s", status: .running, lastEventAt: t0)
        let now = t0.addingTimeInterval(idleTTL + 1)
        XCTAssertFalse(SessionStore.shouldStale(s, tabAlive: true, hasBinding: true, idleTTL: idleTTL, now: now))
    }

    func testSilentOrphanIsAged() {
        let s = session(id: "s", status: .waitingForInput, lastEventAt: t0, iterm: nil)
        let now = t0.addingTimeInterval(idleTTL + 1)
        XCTAssertTrue(SessionStore.shouldStale(s, tabAlive: false, hasBinding: false, idleTTL: idleTTL, now: now))
    }

    func testRecentSessionIsNotAged() {
        let s = session(id: "s", status: .running, lastEventAt: t0, iterm: nil)
        let now = t0.addingTimeInterval(idleTTL - 1)
        XCTAssertFalse(SessionStore.shouldStale(s, tabAlive: false, hasBinding: false, idleTTL: idleTTL, now: now))
    }

    func testFinishedSessionIsNeverAged() {
        let s = session(id: "s", status: .finished, lastEventAt: t0, iterm: nil)
        let now = t0.addingTimeInterval(idleTTL * 10)
        XCTAssertFalse(SessionStore.shouldStale(s, tabAlive: false, hasBinding: false, idleTTL: idleTTL, now: now))
    }

    // MARK: - hasLiveRelatedSubAgent (defer-finish gate, sub-agent half)

    /// A driver that just ended its turn must not be considered done while a
    /// sub-agent in the SAME tab is still running.
    func testLiveSubAgentInSameTabBlocksFinish() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0, iterm: "iterm-1")
        let sub = session(id: "sub", status: .running, lastEventAt: t1, iterm: "iterm-1")
        XCTAssertTrue(SessionStore.hasLiveRelatedSubAgent(driver, in: [driver, sub]))
    }

    /// A waiting sub-agent (blocked on a permission gate) also blocks.
    func testWaitingSubAgentBlocksFinish() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0, iterm: "iterm-1")
        let sub = session(id: "sub", status: .waitingForInput, lastEventAt: t1, iterm: "iterm-1")
        XCTAssertTrue(SessionStore.hasLiveRelatedSubAgent(driver, in: [driver, sub]))
    }

    /// Once the sub-agent is no longer live, the driver is free to finish.
    func testFinishedSubAgentDoesNotBlock() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0, iterm: "iterm-1")
        let sub = session(id: "sub", status: .finished, lastEventAt: t1, iterm: "iterm-1")
        XCTAssertFalse(SessionStore.hasLiveRelatedSubAgent(driver, in: [driver, sub]))
    }

    /// A live agent in a DIFFERENT tab is unrelated — no cross-coupling.
    func testLiveAgentInOtherTabDoesNotBlock() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0, iterm: "iterm-1")
        let other = session(id: "other", status: .running, lastEventAt: t1, iterm: "iterm-2")
        XCTAssertFalse(SessionStore.hasLiveRelatedSubAgent(driver, in: [driver, other]))
    }

    /// A driver with no terminal binding relates to nothing (falls back to the
    /// transcript signal + stale sweep, not handled here).
    func testUnboundDriverHasNoRelations() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0, iterm: nil)
        let sub = session(id: "sub", status: .running, lastEventAt: t1, iterm: nil)
        XCTAssertFalse(SessionStore.hasLiveRelatedSubAgent(driver, in: [driver, sub]))
    }

    /// The session never counts itself as its own blocker.
    func testSessionDoesNotBlockItself() {
        let driver = session(id: "driver", status: .running, lastEventAt: t0, iterm: "iterm-1")
        XCTAssertFalse(SessionStore.hasLiveRelatedSubAgent(driver, in: [driver]))
    }

    // MARK: - tabKey

    func testTabKeyPrefersResolvedGhosttyTerminal() {
        let s = session(id: "s", status: .running, lastEventAt: t0,
                        iterm: "iterm-1", ghosttySurface: "surf-9", ghosttyTerminal: "term-9")
        XCTAssertEqual(SessionStore.tabKey(for: s), "ghostty:term-9")
    }

    func testTabKeyNilWhenUnbound() {
        let s = session(id: "s", status: .running, lastEventAt: t0, iterm: nil)
        XCTAssertNil(SessionStore.tabKey(for: s))
    }

    // MARK: - resumableClosed (the collapsed "Closed" recovery list)

    private func closed(
        id: String,
        agent: AgentKind = .claudeCode,
        cwd: String = "/repo",
        status: SessionStatus = .finished,
        at: Date
    ) -> DroidSession {
        DroidSession(
            id: id,
            agentKind: agent,
            cwd: URL(fileURLWithPath: cwd),
            repoName: nil,
            itermSessionId: nil,
            ghosttySurfaceId: nil,
            status: status,
            lastEvent: "x",
            lastEventAt: at,
            startedAt: at,
            finishedAt: (status == .finished || status == .stale) ? at : nil,
            transcriptPath: URL(fileURLWithPath: "/t/\(id).jsonl"),
            attentionRaisedAt: nil
        )
    }

    private let always: (DroidSession) -> Bool = { _ in true }

    func testResumableClosedDedupesNewestPerAgentAndCwd() {
        let old = closed(id: "old", cwd: "/repo", at: t0)
        let new = closed(id: "new", cwd: "/repo", at: t1)
        let result = SessionStore.resumableClosed(from: [old, new], transcriptExists: always, cap: 10)
        XCTAssertEqual(result.map(\.id), ["new"])
    }

    func testResumableClosedKeepsDistinctReposAndAgents() {
        let a = closed(id: "a", agent: .claudeCode, cwd: "/repo1", at: t0)
        let b = closed(id: "b", agent: .codex, cwd: "/repo1", at: t1)
        let c = closed(id: "c", agent: .claudeCode, cwd: "/repo2", at: t0)
        let result = SessionStore.resumableClosed(from: [a, b, c], transcriptExists: always, cap: 10)
        XCTAssertEqual(Set(result.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(result.first?.id, "b") // newest first
    }

    func testResumableClosedExcludesActiveAndUnknownAgent() {
        let running = closed(id: "run", status: .running, at: t1)
        let unknown = closed(id: "unk", agent: .unknown, at: t1)
        let result = SessionStore.resumableClosed(from: [running, unknown], transcriptExists: always, cap: 10)
        XCTAssertTrue(result.isEmpty)
    }

    func testResumableClosedDropsMissingTranscripts() {
        let s = closed(id: "gone", at: t1)
        let result = SessionStore.resumableClosed(from: [s], transcriptExists: { _ in false }, cap: 10)
        XCTAssertTrue(result.isEmpty)
    }

    func testResumableClosedRespectsCapNewestFirst() {
        let sessions = (0..<5).map {
            closed(id: "s\($0)", cwd: "/repo\($0)", at: Date(timeIntervalSince1970: Double(1_000 + $0)))
        }
        let result = SessionStore.resumableClosed(from: sessions, transcriptExists: always, cap: 3)
        XCTAssertEqual(result.map(\.id), ["s4", "s3", "s2"])
    }
}
