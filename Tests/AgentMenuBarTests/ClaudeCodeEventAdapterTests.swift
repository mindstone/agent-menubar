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

    func testSessionStartGoesIdle() {
        var s = newSession(status: .finished, lastEvent: "Finished turn")
        apply(["hook_event_name": "SessionStart", "source": "startup"], to: &s)
        XCTAssertEqual(s.status, .idle)
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

    /// `Stop` no longer finishes outright — it defers to `SessionStore`, which
    /// decides whether background work is still outstanding. The adapter records
    /// the turn end and moves to `.awaitingBackgroundWork` with `finishedAt` clear.
    func testStopDefersFinish() {
        var s = newSession(status: .running)
        s.attentionRaisedAt = now
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertEqual(s.status, .awaitingBackgroundWork, "Stop must defer to awaitingBackgroundWork until the store finishes it")
        XCTAssertEqual(s.turnEndedAt, now, "Stop must record the turn-end timestamp")
        XCTAssertNil(s.finishedAt)
        XCTAssertNil(s.attentionRaisedAt)
        XCTAssertEqual(s.lastEvent, "Finished turn")
    }

    /// `SessionEnd` means the CLI process is exiting — its native background work
    /// dies with it — so finish immediately rather than deferring.
    func testSessionEndGoesFinished() {
        var s = newSession(status: .running, lastEvent: "Working…")
        apply(["hook_event_name": "SessionEnd"], to: &s)
        XCTAssertEqual(s.status, .finished)
        XCTAssertEqual(s.finishedAt, now)
        XCTAssertNil(s.turnEndedAt)
    }

    /// A `SessionEnd` arriving on a pending-finish session clears the marker.
    func testSessionEndClearsPendingFinish() {
        var s = newSession(status: .running)
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertEqual(s.turnEndedAt, now)
        apply(["hook_event_name": "SessionEnd"], to: &s)
        XCTAssertEqual(s.status, .finished)
        XCTAssertNil(s.turnEndedAt)
    }

    /// `SessionEnd` means the CLI process itself is exiting, not just the turn —
    /// `sessionEnded` must flip so `SessionStore.shouldSettleToIdle` never
    /// resurrects this row as "READY" while the tab happens to stay open.
    func testSessionEndSetsSessionEnded() {
        var s = newSession(status: .running, lastEvent: "Working…")
        apply(["hook_event_name": "SessionEnd"], to: &s)
        XCTAssertTrue(s.sessionEnded)
    }

    /// A resumed session (same session id, fresh `SessionStart`) must clear a
    /// prior `sessionEnded` marker so it becomes eligible to settle to `.idle`
    /// again — see `DroidSession.sessionEnded`.
    func testSessionStartClearsSessionEndedOnResume() {
        var s = newSession(status: .finished, lastEvent: "Session ended")
        s.sessionEnded = true
        apply(["hook_event_name": "SessionStart", "source": "resume"], to: &s)
        XCTAssertFalse(s.sessionEnded)
    }

    // MARK: - Pending finish is cancelled when the turn resumes

    func testNewPromptCancelsPendingFinish() {
        var s = newSession(status: .running)
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertNotNil(s.turnEndedAt)
        apply(["hook_event_name": "UserPromptSubmit", "prompt": "Keep going"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertNil(s.turnEndedAt, "a fresh prompt re-arms the turn and cancels the pending finish")
    }

    func testToolUseCancelsPendingFinish() {
        var s = newSession(status: .running)
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertNotNil(s.turnEndedAt)
        apply(["hook_event_name": "PostToolUse", "tool_name": "Bash"], to: &s)
        XCTAssertNil(s.turnEndedAt, "tool activity means the turn is live again")
        XCTAssertEqual(s.status, .running)
    }

    /// The idle nudge that fires ~60s after Stop must NOT cancel a pending
    /// finish — the turn is still resting on its background work.
    func testIdlePromptKeepsPendingFinish() {
        var s = newSession(status: .running)
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertEqual(s.turnEndedAt, now)
        apply(["hook_event_name": "Notification",
               "notification_type": "idle_prompt",
               "message": "Claude is waiting for your input"], to: &s)
        XCTAssertEqual(s.status, .awaitingBackgroundWork)
        XCTAssertEqual(s.turnEndedAt, now, "idle_prompt must leave a pending finish untouched")
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
        XCTAssertEqual(s.status, .idle)

        apply(["hook_event_name": "UserPromptSubmit", "prompt": "Refactor this"], to: &s)
        XCTAssertEqual(s.status, .running)

        apply(["hook_event_name": "PermissionRequest", "tool_name": "Edit"], to: &s)
        XCTAssertEqual(s.status, .waitingForInput)

        apply(["hook_event_name": "PostToolUse", "tool_name": "Edit"], to: &s)
        XCTAssertEqual(s.status, .running)

        // Stop defers to the store; at the adapter level it moves to
        // awaitingBackgroundWork with the turn-end recorded.
        apply(["hook_event_name": "Stop"], to: &s)
        XCTAssertEqual(s.status, .awaitingBackgroundWork)
        XCTAssertEqual(s.turnEndedAt, now)

        // The nudge that used to break things — leaves the pending finish alone.
        apply(["hook_event_name": "Notification",
               "notification_type": "idle_prompt",
               "message": "Claude is waiting for your input"], to: &s)
        XCTAssertEqual(s.status, .awaitingBackgroundWork)
        XCTAssertEqual(s.turnEndedAt, now)

        // Next turn re-arms cleanly and cancels the pending finish.
        apply(["hook_event_name": "UserPromptSubmit", "prompt": "One more thing"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertNil(s.turnEndedAt)
        XCTAssertEqual(s.firstPrompt, "Refactor this")
    }

    // MARK: - Decoding

    func testNotificationTypeDecodes() {
        let e = event(["hook_event_name": "Notification", "notification_type": "idle_prompt"])
        XCTAssertEqual(e.notificationType, "idle_prompt")
    }

    // MARK: - Reported gaps (popover status audit)

    /// A background task's completion is redelivered into the conversation as a
    /// synthetic user turn (`origin.kind == "task-notification"` in the raw
    /// transcript JSONL, `message.content` a plain multi-line string). When
    /// `Stop` fires right on top of that delivery — before the driver's next
    /// assistant turn produces its own text — `TranscriptReader.tailPreview`
    /// walks backward from EOF and happily extracts that synthetic user turn's
    /// `content` as "the most recent meaningful entry", verbatim markup and all;
    /// it has no concept of message role or of this wrapper format (unlike
    /// `TranscriptBackgroundScan`, which already knows to parse it). Confirmed
    /// against a real transcript (weteachbackend session
    /// fbc9ad14-3270-4d42-ad8b-ff376863d95d, task a5281bbc0d7a45c0d, line 311):
    /// the row showed literal multi-line `<task-notification>` markup as its
    /// status text. `status` itself isn't asserted here — that transcript's
    /// notification was a `<status>failed</status>` terminal one, which is
    /// exactly the kind `TranscriptBackgroundScan` counts as no-longer-outstanding,
    /// so RUNNING there came from the turn being re-armed, not from a live
    /// background task still deferring the finish.
    func testStopPreviewLeaksRawTaskNotificationMarkupFromTranscriptTail() throws {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }

        // Shape lifted verbatim from the real transcript line that produced the
        // screenshot: a synthetic "user" turn whose `content` is the raw,
        // multi-line task-notification wrapper (not an Anthropic content-block
        // array), tagged by `origin.kind`.
        let transcriptLine = """
        {"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>a5281bbc0d7a45c0d</task-id>\\n<status>failed</status>\\n<summary>Agent stalled: no progress for 600s</summary>\\n</task-notification>"},"origin":{"kind":"task-notification"},"promptSource":"system"}
        """
        try transcriptLine.write(to: path, atomically: true, encoding: .utf8)

        var s = newSession(status: .running, lastEvent: "Working…")
        s.transcriptPath = path
        apply(["hook_event_name": "Stop"], to: &s)

        XCTAssertEqual(s.status, .awaitingBackgroundWork, "Stop always defers to awaitingBackgroundWork; this test is only about lastEvent's text")

        XCTAssertFalse(s.lastEvent.contains("<task-notification>"),
                        "lastEvent should not show raw internal markup")
        XCTAssertFalse(s.lastEvent.contains("\n"),
                        "lastEvent renders as a single status line in the row")
    }

    /// `SubagentStop` fires when a Task-tool subagent completes. It's a safe
    /// no-op at the adapter level — `SessionStore.apply` already bumps
    /// `lastEventAt` and re-runs `resolvePendingFinishes` after every event
    /// regardless of adapter handling, so simply registering the hook (see
    /// `hooks/claude-code-hooks-block.json`) is enough to react sooner than
    /// the 5s inventory-timer fallback would.
    func testSubagentStopDoesNotDisturbStatus() {
        let e = event(["hook_event_name": "SubagentStop"])
        XCTAssertEqual(e.hookEventName, "SubagentStop")

        var s = newSession(status: .running, lastEvent: "Working…")
        apply(["hook_event_name": "SubagentStop"], to: &s)
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.lastEvent, "Working…")
    }

    /// A background task's completion can also be redelivered as a synthetic
    /// `UserPromptSubmit` whose `prompt` is the raw `<task-notification>`
    /// wrapper. `applyPrompt` must show `TaskNotificationText.friendlySummary`'s
    /// result instead of the raw markup, and must not capture it as
    /// `firstPrompt` — that field is reserved for the human's real first task.
    func testUserPromptSubmitWithTaskNotificationTextProducesFriendlySummary() {
        let notification = """
        <task-notification>
        <task-id>a5281bbc0d7a45c0d</task-id>
        <status>failed</status>
        <summary>Agent stalled: no progress for 600s</summary>
        </task-notification>
        """
        var s = newSession(status: .running, lastEvent: "Working…")
        XCTAssertNil(s.firstPrompt)

        apply(["hook_event_name": "UserPromptSubmit", "prompt": notification], to: &s)

        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.lastEvent, TaskNotificationText.friendlySummary(in: notification))
        XCTAssertNil(s.firstPrompt, "a redelivered task notification must not be captured as the human's first prompt")
    }
}
