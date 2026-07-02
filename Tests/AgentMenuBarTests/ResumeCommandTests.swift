import XCTest
@testable import AgentMenuBar

final class ResumeCommandTests: XCTestCase {

    func testArgvForEachSupportedAgent() {
        XCTAssertEqual(ResumeCommand.argv(for: .claudeCode, sessionId: "abc"), ["claude", "--resume", "abc"])
        XCTAssertEqual(ResumeCommand.argv(for: .codex, sessionId: "abc"), ["codex", "resume", "abc"])
        XCTAssertEqual(ResumeCommand.argv(for: .cursor, sessionId: "abc"), ["cursor-agent", "--resume", "abc"])
        XCTAssertEqual(ResumeCommand.argv(for: .factoryDroid, sessionId: "abc"), ["droid", "--resume", "abc"])
    }

    func testArgvForUnknownIsNil() {
        XCTAssertNil(ResumeCommand.argv(for: .unknown, sessionId: "abc"))
    }

    func testSupportsResumePerKind() {
        XCTAssertTrue(ResumeCommand.supportsResume(.factoryDroid))
        XCTAssertTrue(ResumeCommand.supportsResume(.codex))
        XCTAssertTrue(ResumeCommand.supportsResume(.cursor))
        XCTAssertTrue(ResumeCommand.supportsResume(.claudeCode))
        XCTAssertFalse(ResumeCommand.supportsResume(.unknown))
    }

    func testShellLineForClaudeCode() {
        XCTAssertEqual(
            ResumeCommand.shellLine(for: .claudeCode, sessionId: "abc", cwd: "/Users/harry/dev"),
            "cd '/Users/harry/dev' && exec 'claude' '--resume' 'abc'"
        )
    }

    func testShellLineIsNilForUnknown() {
        XCTAssertNil(ResumeCommand.shellLine(for: .unknown, sessionId: "abc", cwd: "/Users/harry/dev"))
    }

    func testShellLineIsNilForEmptySessionId() {
        XCTAssertNil(ResumeCommand.shellLine(for: .claudeCode, sessionId: "", cwd: "/Users/harry/dev"))
        XCTAssertNil(ResumeCommand.shellLine(for: .claudeCode, sessionId: " \n\t", cwd: "/Users/harry/dev"))
    }

    func testPosixQuoteEscapesSingleQuote() {
        XCTAssertEqual(ResumeCommand.posixQuote("/Users/o'brien/x"), "'/Users/o'\\''brien/x'")
    }
}
