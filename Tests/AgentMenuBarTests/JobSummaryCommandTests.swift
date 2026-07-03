import XCTest
@testable import AgentMenuBar

final class JobSummaryCommandTests: XCTestCase {

    func testSupportsSummaryPerKind() {
        XCTAssertTrue(JobSummaryCommand.supportsSummary(.factoryDroid))
        XCTAssertTrue(JobSummaryCommand.supportsSummary(.codex))
        XCTAssertTrue(JobSummaryCommand.supportsSummary(.cursor))
        XCTAssertTrue(JobSummaryCommand.supportsSummary(.claudeCode))
        XCTAssertFalse(JobSummaryCommand.supportsSummary(.unknown))
    }

    func testArgvForUnknownIsNil() {
        XCTAssertNil(JobSummaryCommand.argv(for: .unknown, prompt: "hi"))
    }

    func testArgvForClaudeCodeDisallowsToolsAndPicksHaiku() {
        let argv = JobSummaryCommand.argv(for: .claudeCode, prompt: "hi")
        XCTAssertEqual(argv, ["claude", "-p", "hi", "--model", "haiku", "--allowedTools", "", "--output-format", "text"])
    }

    func testArgvForCodexIsReadOnlyWithLowReasoningEffort() {
        let argv = JobSummaryCommand.argv(for: .codex, prompt: "hi")
        XCTAssertEqual(argv, ["codex", "exec", "--sandbox", "read-only", "-c", "model_reasoning_effort=\"low\"", "hi"])
    }

    func testArgvForCursorUsesReadOnlyAskModeAndTrustsWorkspace() {
        let argv = JobSummaryCommand.argv(for: .cursor, prompt: "hi")
        XCTAssertEqual(argv, ["cursor-agent", "-p", "hi", "--mode", "ask", "--model", "gpt-5-mini", "--output-format", "text", "--trust"])
    }

    func testArgvForFactoryDroidUsesDefaultReadOnlyExec() {
        let argv = JobSummaryCommand.argv(for: .factoryDroid, prompt: "hi")
        XCTAssertEqual(argv, ["droid", "exec", "hi"])
    }

    func testPromptIncludesFirstPromptAndLastEventWhenBothPresent() {
        let prompt = JobSummaryCommand.prompt(firstPrompt: "Fix the login bug", lastEvent: "Running tests")
        XCTAssertTrue(prompt.contains("Fix the login bug"))
        XCTAssertTrue(prompt.contains("Running tests"))
    }

    func testPromptOmitsFirstPromptWhenNilOrEmpty() {
        let promptNil = JobSummaryCommand.prompt(firstPrompt: nil, lastEvent: "Running tests")
        XCTAssertFalse(promptNil.contains("It was originally asked to"))

        let promptEmpty = JobSummaryCommand.prompt(firstPrompt: "   ", lastEvent: "Running tests")
        XCTAssertFalse(promptEmpty.contains("It was originally asked to"))
    }
}
