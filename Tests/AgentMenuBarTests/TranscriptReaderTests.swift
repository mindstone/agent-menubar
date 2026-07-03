import XCTest
@testable import AgentMenuBar

/// Tests for `TranscriptReader.tailPreview`, the "most recent meaningful
/// entry" summarizer used by all four agent adapters to populate a session
/// row's status text. Fixtures are written to real temp files since the
/// reader operates on a `URL`, mirroring `TranscriptBackgroundScanTests`.
final class TranscriptReaderTests: XCTestCase {

    private func write(_ content: String) -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        try! content.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    func testTaskNotificationTailIsSummarizedNotLeakedRaw() {
        // Shape lifted verbatim from the real transcript that produced the
        // reported bug: a synthetic "user" turn whose `content` is the raw,
        // multi-line task-notification wrapper (not an Anthropic content-block
        // array), tagged by `origin.kind`.
        let transcriptLine = """
        {"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>a5281bbc0d7a45c0d</task-id>\\n<status>failed</status>\\n<summary>Agent stalled: no progress for 600s</summary>\\n</task-notification>"},"origin":{"kind":"task-notification"},"promptSource":"system"}
        """
        let path = write(transcriptLine)
        defer { try? FileManager.default.removeItem(at: path) }

        let preview = TranscriptReader.tailPreview(path)

        XCTAssertEqual(preview, "Background task failed: Agent stalled: no progress for 600s")
        XCTAssertFalse(preview?.contains("<task-notification>") ?? true)
        XCTAssertFalse(preview?.contains("\n") ?? true)
    }

    func testOrdinaryAssistantTextIsUnchanged() {
        // Regression check: the common Anthropic content-block shape must
        // still pass through untouched.
        let transcriptLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All done, tests pass."}]}}"#
        let path = write(transcriptLine)
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertEqual(TranscriptReader.tailPreview(path), "All done, tests pass.")
    }

    func testStructuredJsonWithEmbeddedNewlineIsCollapsed() {
        // A non-task-notification JSON line whose extracted text carries a
        // real newline (encoded as the JSON escape `\n`, which
        // JSONSerialization turns into an actual newline character). This
        // exercises `clip`'s collapsing on the structured-JSON branch,
        // independent of the task-notification fix.
        let transcriptLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Line one\nLine two"}]}}"#
        let path = write(transcriptLine)
        defer { try? FileManager.default.removeItem(at: path) }

        let preview = TranscriptReader.tailPreview(path)
        XCTAssertEqual(preview, "Line one Line two")
        XCTAssertFalse(preview?.contains("\n") ?? true)
    }

    func testPlainTextFallbackCollapsesEmbeddedLineBreaks() {
        // No valid JSON at all, so this exercises the plain-text fallback at
        // the bottom of `tailPreview`. Note: the reader first splits the
        // whole file on literal "\n", so a genuine "\n" can never survive
        // inside a single fallback line by construction — only "\r" can. We
        // use "\r" here (no "\n" in the file at all) to exercise the same
        // whitespace-collapsing behavior in `clip` on this code path.
        let content = "Investigating the failure\rRetrying the operation\rDone for now"
        let path = write(content)
        defer { try? FileManager.default.removeItem(at: path) }

        let preview = TranscriptReader.tailPreview(path)
        XCTAssertEqual(preview, "Investigating the failure Retrying the operation Done for now")
        XCTAssertFalse(preview?.contains("\r") ?? true)
        XCTAssertFalse(preview?.contains("\n") ?? true)
    }

    func testMissingFileReturnsNil() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-transcript-\(UUID().uuidString).jsonl")
        XCTAssertNil(TranscriptReader.tailPreview(path))
    }
}
