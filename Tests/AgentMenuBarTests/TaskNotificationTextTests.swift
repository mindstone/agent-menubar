import XCTest
@testable import AgentMenuBar

final class TaskNotificationTextTests: XCTestCase {
    func testNonWrapperTextReturnsNil() {
        XCTAssertNil(TaskNotificationText.friendlySummary(in: "Fix the bug"))
    }

    func testStatusAndSummaryBothPresent() {
        let raw = """
        <task-notification>
        <task-id>a5281bbc0d7a45c0d</task-id>
        <status>failed</status>
        <summary>Agent stalled: no progress for 600s</summary>
        </task-notification>
        """
        XCTAssertEqual(TaskNotificationText.friendlySummary(in: raw),
                        "Background task failed: Agent stalled: no progress for 600s")
    }

    func testSummaryOnly() {
        let raw = "<task-notification><summary>All done</summary></task-notification>"
        XCTAssertEqual(TaskNotificationText.friendlySummary(in: raw), "All done")
    }

    func testStatusOnly() {
        let raw = "<task-notification><status>completed</status></task-notification>"
        XCTAssertEqual(TaskNotificationText.friendlySummary(in: raw), "Background task completed")
    }

    func testNeitherTagPresentFallsBackToGenericLabel() {
        let raw = "<task-notification><task-id>x</task-id></task-notification>"
        XCTAssertEqual(TaskNotificationText.friendlySummary(in: raw), "Background task update")
    }

    func testResultDoesNotLeakIntoSummaryWhenSummaryTagAbsent() {
        // A wrapper carrying only <result> (no <summary>) must not surface the
        // raw <result> text as if it were a human-readable summary.
        let raw = "<task-notification><status>completed</status><result>raw internal text</result></task-notification>"
        XCTAssertEqual(TaskNotificationText.friendlySummary(in: raw), "Background task completed")
    }

    /// Callers (e.g. `applyPrompt`) show this result inline in a one-line status
    /// field without any further clipping/collapsing of their own — unlike
    /// `TranscriptReader`, which routes everything through `clip`. A `<summary>`
    /// an agent wrote across multiple lines (or with irregular spacing) must
    /// come out as clean single-line text here, not leak the same kind of
    /// multi-line markup this type exists to fix.
    func testMultiLineSummaryIsCollapsedToOneLine() {
        let raw = """
        <task-notification>
        <status>failed</status>
        <summary>Agent stalled:
        no progress for   600s</summary>
        </task-notification>
        """
        let result = TaskNotificationText.friendlySummary(in: raw)
        XCTAssertEqual(result, "Background task failed: Agent stalled: no progress for 600s")
        XCTAssertFalse(result?.contains("\n") ?? true)
    }
}
