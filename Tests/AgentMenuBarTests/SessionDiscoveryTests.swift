import XCTest
@testable import AgentMenuBar

final class SessionDiscoveryTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        try super.tearDownWithError()
    }

    func testParseClaudeHeaderFindsLaterCWDAndPrompt() {
        let sample = """
        {"type":"mode","mode":"normal","sessionId":"claude-1"}
        {"type":"attachment","cwd":"/Users/harry/dev","sessionId":"claude-1"}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Build the thing"}]}}
        """

        let parsed = SessionDiscovery.parseClaudeHeader(sample)
        XCTAssertEqual(parsed.cwd, "/Users/harry/dev")
        XCTAssertEqual(parsed.firstPrompt, "Build the thing")
    }

    func testParseClaudeHeaderReturnsNilCWDWhenAbsent() {
        let sample = """
        {"type":"mode","mode":"normal","sessionId":"claude-1"}
        {"type":"user","message":{"role":"user","content":"Hello"}}
        """

        let parsed = SessionDiscovery.parseClaudeHeader(sample)
        XCTAssertNil(parsed.cwd)
        XCTAssertEqual(parsed.firstPrompt, "Hello")
    }

    func testParseCodexMeta() {
        let line = #"{"timestamp":"2026-06-29T10:00:00Z","type":"session_meta","payload":{"id":"codex-123","cwd":"/Users/harry/dev","originator":"codex-tui"}}"#

        let parsed = SessionDiscovery.parseCodexMeta(firstLine: line)
        XCTAssertEqual(parsed.id, "codex-123")
        XCTAssertEqual(parsed.cwd, "/Users/harry/dev")
    }

    func testDecodeFactoryDirNameIsLossyForHyphenatedRepos() {
        // Factory collapses every non-alphanumeric char to "-", so a naive
        // decode can't tell a hyphenated repo from a path separator. This is the
        // documented lossy fallback; reconstructFactoryPath does better.
        XCTAssertEqual(
            SessionDiscovery.decodeFactoryDirName("-Users-harry-development-droid-menubar"),
            "/Users/harry/development/droid/menubar"
        )
    }

    func testReconstructFactoryPathRecoversHyphenatedRepoFromFilesystem() {
        let existing: Set<String> = [
            "/Users",
            "/Users/harry",
            "/Users/harry/development",
            "/Users/harry/development/droid-menubar",
        ]
        let resolved = SessionDiscovery.reconstructFactoryPath(
            "-Users-harry-development-droid-menubar",
            directoryExists: { existing.contains($0) }
        )
        XCTAssertEqual(resolved, "/Users/harry/development/droid-menubar")
    }

    func testReconstructFactoryPathAppendsNaivelyWhenUnmatched() {
        let existing: Set<String> = ["/Users", "/Users/harry"]
        let resolved = SessionDiscovery.reconstructFactoryPath(
            "-Users-harry-ghost-repo",
            directoryExists: { existing.contains($0) }
        )
        XCTAssertEqual(resolved, "/Users/harry/ghost/repo")
    }

    func testScanFindsClaudeAndCodexNewestFirstAndFiltersOldFiles() throws {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let claudeID = "11111111-1111-4111-8111-111111111111"
        let codexID = "22222222-2222-4222-8222-222222222222"
        let oldID = "33333333-3333-4333-8333-333333333333"

        let claudeURL = tempHome
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-harry-dev-claude", isDirectory: true)
            .appendingPathComponent("\(claudeID).jsonl")
        try write(
            """
            {"type":"mode","mode":"normal","sessionId":"\(claudeID)"}
            {"type":"attachment","cwd":"/Users/harry/dev/claude","sessionId":"\(claudeID)"}
            {"type":"user","message":{"role":"user","content":"Claude prompt"}}
            """,
            to: claudeURL,
            modificationDate: now.addingTimeInterval(-100)
        )

        let codexURL = tempHome
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("29", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-29T10-00-00-\(codexID).jsonl")
        try write(
            #"{"type":"session_meta","payload":{"id":"\#(codexID)","cwd":"/Users/harry/dev/codex"}}"#,
            to: codexURL,
            modificationDate: now.addingTimeInterval(-10)
        )

        let oldURL = tempHome
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-01T10-00-00-\(oldID).jsonl")
        try write(
            #"{"type":"session_meta","payload":{"id":"\#(oldID)","cwd":"/Users/harry/dev/old"}}"#,
            to: oldURL,
            modificationDate: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )

        let results = SessionDiscovery.scan(
            home: tempHome,
            now: now,
            maxAge: 21 * 24 * 60 * 60,
            maxPerAgent: 40
        )

        XCTAssertEqual(results.map(\.id), [codexID, claudeID])
        XCTAssertEqual(results[0].agentKind, .codex)
        XCTAssertEqual(results[0].cwd, URL(fileURLWithPath: "/Users/harry/dev/codex"))
        XCTAssertEqual(results[1].agentKind, .claudeCode)
        XCTAssertEqual(results[1].cwd, URL(fileURLWithPath: "/Users/harry/dev/claude"))
        XCTAssertFalse(results.contains { $0.id == oldID })
    }

    private func write(_ contents: String, to url: URL, modificationDate: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
    }
}
