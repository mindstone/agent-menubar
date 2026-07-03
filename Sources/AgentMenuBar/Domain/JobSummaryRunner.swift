import Foundation

/// Runs a `JobSummaryCommand` argv as a headless subprocess and returns its
/// one-line answer, or `nil` on any failure (CLI missing, auth expired,
/// timeout, non-zero exit, empty output). Callers are expected to fall back
/// silently to the raw status text on `nil` — a missing AI gloss is never
/// worse than what was already on screen.
enum JobSummaryRunner {
    /// Generous but bounded: Codex at low reasoning effort and Claude/Cursor
    /// all answered in a few seconds in testing; this only guards against a
    /// hung/misbehaving process.
    static let timeout: TimeInterval = 20

    /// Blocking — call from a background thread (e.g. inside `Task.detached`).
    /// Resolves `argv[0]` via a login shell (`zsh -l`) rather than an absolute
    /// path: a menu-bar app's own PATH doesn't include wherever the user
    /// installed these CLIs (`~/.local/bin`, Homebrew, nvm shims, …), but an
    /// interactive login shell does, the same trick `TerminalLauncher` already
    /// relies on for the "Resume" flow.
    static func run(argv: [String]) -> String? {
        guard !argv.isEmpty else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", argv.map(ResumeCommand.posixQuote).joined(separator: " ")]

        var environment = ProcessInfo.processInfo.environment
        environment["AGENTMENUBAR_SUPPRESS_HOOKS"] = "1"
        process.environment = environment

        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }

        // The answer is one short sentence — comfortably inside the pipe's
        // kernel buffer, so reading only after exit (rather than draining
        // concurrently) can't deadlock here.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return sanitize(raw)
    }

    /// Collapses a CLI's raw stdout into a single display-ready line: takes
    /// the last non-empty line (in case a model still emits a short preamble
    /// despite instructions not to), strips wrapping quotes, and caps length
    /// as a safety net against an instruction the model ignored.
    static func sanitize(_ raw: String, maxLength: Int = 140) -> String? {
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard var line = lines.last(where: { !$0.isEmpty }) else { return nil }

        if line.count >= 2, let first = line.first, let last = line.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            line = String(line.dropFirst().dropLast())
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        return line.count <= maxLength ? line : String(line.prefix(maxLength)) + "…"
    }
}
