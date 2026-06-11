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
}
