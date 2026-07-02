import Foundation

enum ResumeCommand {
    /// Whether this agent supports resuming a specific recorded session by id from the CLI.
    static func supportsResume(_ kind: AgentKind) -> Bool {
        switch kind {
        case .factoryDroid, .codex, .cursor, .claudeCode:
            return true
        case .unknown:
            return false
        }
    }

    /// The argv to resume `sessionId` for `kind`, or nil if the agent has no by-id resume.
    static func argv(for kind: AgentKind, sessionId: String) -> [String]? {
        switch kind {
        case .claudeCode:
            return ["claude", "--resume", sessionId]
        case .codex:
            return ["codex", "resume", sessionId]
        case .cursor:
            return ["cursor-agent", "--resume", sessionId]
        case .factoryDroid:
            return ["droid", "--resume", sessionId]
        case .unknown:
            return nil
        }
    }

    /// A `/bin/sh -c`-ready line that cd's into `cwd` and then runs the resume argv.
    /// Returns nil when the agent is unsupported or sessionId is empty.
    static func shellLine(for kind: AgentKind, sessionId: String, cwd: String) -> String? {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = argv(for: kind, sessionId: sessionId) else {
            return nil
        }

        let quotedCwd = posixQuote(cwd)
        let quotedArgv = argv.map(posixQuote).joined(separator: " ")
        return "cd \(quotedCwd) && exec \(quotedArgv)"
    }

    /// POSIX single-quote escaping of one argument so it is safe inside a `sh` command.
    static func posixQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
