import XCTest
@testable import AgentMenuBar

/// State-machine tests for the Claude Code adapter. Events are built as JSON and
/// run through the real `HookEvent` decoder + `AgentEventAdapter`, so these
/// exercise the same path the socket bridge feeds in production.
final class ClaudeCodeEventAdapterTests: XCTestCase {

    // MARK: - Helpers

    /// Decode a `HookEvent` from a payload dict, the way the IPC layer does.
    private func event(_ fields: [String: Any]) -> HookEvent {
        var payload = fields
        payload["agent_kind"] = "claude-code"
        if payload["session_id"] == nil { payload["session_id"] = "s1" }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(HookEvent.self, from: data)
    }

    /// A fresh session as `SessionStore.apply` would create on first sight.
    private func newSession(status: SessionStatus = .running,
                            lastEvent: String = "Starting…") -> DroidSession {
        let now = Date(timeIntervalSince1970: 1_000)
        return DroidSession(
            id: "s1",
            agentKind: .claudeCode,
            cwd: URL(fileURLWithPath: "/tmp"),
            repoName: nil,
            itermSessionId: "iterm-1",
            ghosttySurfaceId: nil,
            status: status,
            lastEvent: lastEvent,
            lastEventAt: now,
            startedAt: now,
            finishedAt: status == .finished ? now : nil,
            transcriptPath: nil,
            attentionRaisedAt: nil
        )
    }

    private let adapter = ClaudeCodeEventAdapter()
    private let now = Date(timeIntervalSince1970: 2_000)

    @discardableResult
    private func apply(_ fields: [String: Any], to session: inout DroidSession) -> DroidSession {
        adapter.apply(event(fields), to: &session, now: now)
        return session
    }

    // MARK: - Individual transitions

    func testSessionStartGoesRunning() {
        var s = newSession(status: .finished, lastEvent: "Finished turn")
        apply(["hook_event_name": "SessionStart", "source": "startup"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertNil(s.finishedAt)
        XCTAssertNil(s.attentionRaisedAt)
    }

    func testUserPromptSubmitGoesRunningAndCapturesFirstPrompt() {
        var s = newSession()
        apply(["hook_event_name": "UserPromptSubmit", "prompt": "Fix the bug"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.lastEvent, "Fix the bug")
        XCTAssertEqual(s.firstPrompt, "Fix the bug")
        // A later prompt updates lastEvent but not firstPrompt.
        apply(["hook_event_name": "UserPromptSubmit", "prompt": "Now add tests"], to: &s)
        XCTAssertEqual(s.lastEvent, "Now add tests")
        XCTAssertEqual(s.firstPrompt, "Fix the bug")
    }

    func testPermissionRequestGoesWaiting() {
        var s = newSession()
        apply(["hook_event_name": "PermissionRequest", "tool_name": "Bash"], to: &s)
        XCTAssertEqual(s.status, .waitingForInput)
        XCTAssertEqual(s.attentionRaisedAt, now)
        XCTAssertEqual(s.lastEvent, "Claude needs permission to use Bash")
    }

    func testNotificationPermissionPromptGoesWaiting() {
        var s = newSession()
        apply(["hook_event_name": "Notification",
               "notification_type": "permission_prompt",
               "message": "Claude needs your permission"], to: &s)
        XCTAssertEqual(s.status, .waitingForInput)
        XCTAssertEqual(s.attentionRaisedAt, now)
    }

    func testNotificationElicitationGoesWaiting() {
        var s = newSession()
        apply(["hook_event_name": "Notification",
               "notification_type": "elicitation_dialog",
               "message": "Choose an option"], to: &s)
        XCTAssertEqual(s.status, .waitingForInput)
    }

    func testPostToolUseFlipsWaitingBackToRunning() {
        var s = newSession(status: .waitingForInput, lastEvent: "Claude needs your permission")
        s.attentionRaisedAt = Date(timeIntervalSince1970: 1)
        apply(["hook_event_name": "PostToolUse", "tool_name": "Bash"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertNil(s.attentionRaisedAt)
        XCTAssertEqual(s.lastEvent, "Working…")
    }

    func testPostToolUseDoesNotDisturbRunning() {
        var s = newSession(status: .running, lastEvent: "Fix the bug")
        apply(["hook_event_name": "PostToolUse", "tool_name": "Read"], to: &s)
        XCTAssertEqual(s.status, .running)
        // lastEvent left as the in-flight task text, not overwritten.
        XCTAssertEqual(s.lastEvent, "Fix the bug")
    }

    func testStopGoesFinished() {
        var s = newSession(status: .running)
        s.attentionRaisedAt = now
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertEqual(s.status, .finished)
        XCTAssertEqual(s.finishedAt, now)
        XCTAssertNil(s.attentionRaisedAt)
        XCTAssertEqual(s.lastEvent, "Finished turn")
    }

    func testSessionEndGoesFinished() {
        var s = newSession(status: .running, lastEvent: "Working…")
        apply(["hook_event_name": "SessionEnd"], to: &s)
        XCTAssertEqual(s.status, .finished)
        XCTAssertEqual(s.finishedAt, now)
    }

    // MARK: - idle_prompt regression (the reported bug)

    /// The core fix: an `idle_prompt` after a finished turn must NOT repaint the
    /// row as waiting-for-input. Claude Code fires it ~60s after `Stop` when the
    /// user hasn't replied; the turn is already DONE and there's no question.
    func testIdlePromptDoesNotResurrectFinishedSession() {
        var s = newSession(status: .finished, lastEvent: "Finished turn")
        s.finishedAt = Date(timeIntervalSince1970: 1_500)
        let before = s
        apply(["hook_event_name": "Notification",
               "notification_type": "idle_prompt",
               "message": "Claude is waiting for your input"], to: &s)
        XCTAssertEqual(s.status, .finished, "idle_prompt must keep a finished turn DONE")
        XCTAssertNil(s.attentionRaisedAt, "idle_prompt must not raise attention")
        XCTAssertEqual(s.finishedAt, before.finishedAt)
        XCTAssertEqual(s.lastEvent, before.lastEvent, "idle_prompt must not overwrite the resting label")
    }

    /// Even if it somehow lands while running, idle_prompt is not a prompt.
    func testIdlePromptDoesNotDisturbRunningSession() {
        var s = newSession(status: .running, lastEvent: "Working…")
        apply(["hook_event_name": "Notification",
               "notification_type": "idle_prompt",
               "message": "Claude is waiting for your input"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertNil(s.attentionRaisedAt)
    }

    // MARK: - Full lifecycle

    /// The exact shape seen in real logs, including the trailing idle nudge.
    func testFullTurnLifecycleEndsFinished() {
        var s = newSession(status: .running, lastEvent: "Starting…")
        apply(["hook_event_name": "SessionStart", "source": "startup"], to: &s)
        XCTAssertEqual(s.status, .running)

        apply(["hook_event_name": "UserPromptSubmit", "prompt": "Refactor this"], to: &s)
        XCTAssertEqual(s.status, .running)

        apply(["hook_event_name": "PermissionRequest", "tool_name": "Edit"], to: &s)
        XCTAssertEqual(s.status, .waitingForInput)

        apply(["hook_event_name": "PostToolUse", "tool_name": "Edit"], to: &s)
        XCTAssertEqual(s.status, .running)

        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertEqual(s.status, .finished)

        // The nudge that used to break things.
        apply(["hook_event_name": "Notification",
               "notification_type": "idle_prompt",
               "message": "Claude is waiting for your input"], to: &s)
        XCTAssertEqual(s.status, .finished)

        // Next turn re-arms cleanly.
        apply(["hook_event_name": "UserPromptSubmit", "prompt": "One more thing"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.firstPrompt, "Refactor this")
    }

    // MARK: - Decoding

    func testNotificationTypeDecodes() {
        let e = event(["hook_event_name": "Notification", "notification_type": "idle_prompt"])
        XCTAssertEqual(e.notificationType, "idle_prompt")
    }
}
