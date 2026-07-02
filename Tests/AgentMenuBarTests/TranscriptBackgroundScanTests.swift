import XCTest
@testable import AgentMenuBar

/// Tests for the transcript background-task accounting that keeps a Claude
/// session "running" until its native `run_in_background` shells / `Monitor`
/// watchers actually finish. Fixtures mirror the real JSONL shapes verified
/// against `~/.claude/projects` transcripts.
final class TranscriptBackgroundScanTests: XCTestCase {

    // A backgrounded sub-agent launch line.
    private func asyncLaunch(_ id: String) -> String {
        #"{"type":"user","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"\#(id)","outputFile":"/x/tasks/\#(id).output"}}"#
    }

    // A native `run_in_background` Bash launch line.
    private func bashLaunch(_ id: String) -> String {
        #"{"type":"user","toolUseResult":{"backgroundTaskId":"\#(id)","stdout":"","stderr":""}}"#
    }

    // A completion notification embedded in an assistant/user content string.
    private func notification(_ id: String, status: String = "completed") -> String {
        #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>\#(id)</task-id>\n<output-file>/x/tasks/\#(id).output</output-file>\n<status>\#(status)</status>\n<summary>done</summary>\n</task-notification>"}}"#
    }

    // A notification with no <task-id>, only <output-file> — exercises the
    // basename fallback.
    private func notificationByOutputFileOnly(_ id: String, status: String = "completed") -> String {
        #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<output-file>/x/tasks/\#(id).output</output-file>\n<status>\#(status)</status>\n</task-notification>"}}"#
    }

    private func scan(_ lines: [String]) -> TranscriptBackgroundScan.Result {
        TranscriptBackgroundScan.scanText(lines.joined(separator: "\n"))
    }

    func testLaunchWithMatchingCompletionIsZero() {
        let r = scan([asyncLaunch("a111"), notification("a111")])
        XCTAssertEqual(r.launched, ["a111"])
        XCTAssertEqual(r.terminated, ["a111"])
        XCTAssertEqual(r.outstanding, 0)
    }

    func testLaunchWithoutCompletionIsOutstanding() {
        let r = scan([asyncLaunch("a111")])
        XCTAssertEqual(r.outstanding, 1)
    }

    func testNativeBashBackgroundTaskCounted() {
        let r = scan([bashLaunch("bxyz")])
        XCTAssertEqual(r.launched, ["bxyz"])
        XCTAssertEqual(r.outstanding, 1)

        let done = scan([bashLaunch("bxyz"), notification("bxyz", status: "killed")])
        XCTAssertEqual(done.outstanding, 0, "killed is a terminal status")
    }

    func testFailedStatusIsTerminal() {
        let r = scan([asyncLaunch("a1"), notification("a1", status: "failed")])
        XCTAssertEqual(r.outstanding, 0)
    }

    func testBareCompletedTextIsNotCounted() {
        // A line that says "completed" but is NOT a <task-notification> wrapper
        // (e.g. a TaskUpdate status echo) must not terminate anything.
        let echo = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#
        let r = scan([asyncLaunch("a1"), echo])
        XCTAssertEqual(r.outstanding, 1, "bare 'completed' must not clear an outstanding launch")
    }

    func testMultipleTasksMixedState() {
        let r = scan([
            asyncLaunch("a1"),
            bashLaunch("b1"),
            asyncLaunch("a2"),
            notification("a1"),
            notification("b1", status: "failed"),
            // a2 never completes
        ])
        XCTAssertEqual(r.launched, ["a1", "b1", "a2"])
        XCTAssertEqual(r.terminated, ["a1", "b1"])
        XCTAssertEqual(r.outstanding, 1)
    }

    func testCompletionMatchedByOutputFileWhenNoTaskId() {
        let r = scan([asyncLaunch("a9"), notificationByOutputFileOnly("a9")])
        XCTAssertEqual(r.terminated, ["a9"])
        XCTAssertEqual(r.outstanding, 0)
    }

    func testOrphanNotificationIsHarmless() {
        // A completion whose launch scrolled out of the window: subtracting an
        // absent id is a no-op, never negative.
        let r = scan([notification("gone")])
        XCTAssertEqual(r.launched, [])
        XCTAssertEqual(r.outstanding, 0)
    }

    func testEmptyAndGarbageLinesIgnored() {
        let r = scan(["", "   ", "not json", "{bad json", asyncLaunch("a1")])
        XCTAssertEqual(r.outstanding, 1)
    }

    func testMissingFileFailsOpen() {
        let url = URL(fileURLWithPath: "/no/such/transcript-\(UUID().uuidString).jsonl")
        XCTAssertEqual(TranscriptBackgroundScan.outstanding(url), 0)
    }
}
