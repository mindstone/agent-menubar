import XCTest
@testable import AgentMenuBar

final class JobSummaryRunnerTests: XCTestCase {

    func testSanitizeTrimsAndReturnsSingleLine() {
        XCTAssertEqual(JobSummaryRunner.sanitize("  Fixing the failing login test  \n"), "Fixing the failing login test")
    }

    func testSanitizeTakesLastNonEmptyLine() {
        // Some CLIs still emit a short preamble line despite instructions not to.
        let raw = "Sure, here you go:\n\nInvestigating the failing tests\n"
        XCTAssertEqual(JobSummaryRunner.sanitize(raw), "Investigating the failing tests")
    }

    func testSanitizeStripsWrappingQuotes() {
        XCTAssertEqual(JobSummaryRunner.sanitize("\"Refactoring the auth module\""), "Refactoring the auth module")
        XCTAssertEqual(JobSummaryRunner.sanitize("'Refactoring the auth module'"), "Refactoring the auth module")
    }

    func testSanitizeReturnsNilForEmptyOrWhitespaceOnly() {
        XCTAssertNil(JobSummaryRunner.sanitize(""))
        XCTAssertNil(JobSummaryRunner.sanitize("   \n  \n"))
    }

    func testSanitizeTruncatesOverlyLongAnswers() {
        let long = String(repeating: "a", count: 200)
        let result = JobSummaryRunner.sanitize(long, maxLength: 140)
        XCTAssertEqual(result?.count, 141) // 140 chars + ellipsis
        XCTAssertTrue(result?.hasSuffix("…") ?? false)
    }
}
