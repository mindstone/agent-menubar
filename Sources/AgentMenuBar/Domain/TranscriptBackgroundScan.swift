import Foundation

/// Counts a Claude Code session's still-running background tasks by reading its
/// transcript. Used to defer a session's "completed" state until native
/// background work — `run_in_background` Bash shells and the `Monitor` watcher —
/// has actually finished, not just the foreground turn.
///
/// Two surfaces in the JSONL transcript are matched by a shared task id:
///   • A launch line whose `toolUseResult` object is either
///     `{ "status": "async_launched", "agentId": "a…" }` (a backgrounded
///     sub-agent) or `{ "backgroundTaskId": "b…" }` (a native background shell).
///   • A completion, delivered later as text containing a
///     `<task-notification>…</task-notification>` wrapper with a
///     `<task-id>…</task-id>` and a `<status>…</status>`. A task-notification is
///     only emitted at a terminal state (completed/failed/killed observed in the
///     wild), so *any* status inside the wrapper marks that id done.
///
/// Outstanding = launched ids − terminated ids. We match the wrapper plus the
/// task id rather than bare "completed" text, which would massively overcount
/// (TaskUpdate status echoes, prose, etc.).
///
/// Best-effort and fail-open: any read, decode, or format-drift failure yields
/// zero outstanding so a session is never pinned "running" forever on a parsing
/// problem. `SessionStore`'s staleness sweep is the additional backstop.
enum TranscriptBackgroundScan {

    struct Result: Equatable {
        var launched: Set<String> = []
        var terminated: Set<String> = []
        var outstanding: Int { launched.subtracting(terminated).count }
    }

    /// Number of background tasks launched but not yet terminally notified.
    /// `0` on any failure.
    static func outstanding(_ url: URL) -> Int {
        scan(url).outstanding
    }

    /// Parse the tail of the transcript. `maxBytes` is generous (default 2 MB)
    /// because a launch and its completion notification can be many turns apart;
    /// the file only ever appends, so reading the tail keeps each launch paired
    /// with its later notification. An orphan notification whose launch scrolled
    /// out of the window is a harmless no-op subtract.
    static func scan(_ url: URL, maxBytes: Int = 2 * 1024 * 1024) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Result() }
        defer { try? handle.close() }

        let endOffset: UInt64
        do { endOffset = try handle.seekToEnd() } catch { return Result() }
        let startOffset = endOffset > UInt64(maxBytes) ? endOffset - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: startOffset) } catch { return Result() }

        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let str = String(data: data, encoding: .utf8) else { return Result() }

        return scanText(str)
    }

    /// Pure core, exposed for testing on fixture strings.
    static func scanText(_ text: String) -> Result {
        var result = Result()
        for rawLine in text.split(whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Launches come from structured `toolUseResult`; parse JSON when the
            // line looks like an object that mentions one of the launch keys.
            if line.first == "{",
               (line.contains("async_launched") || line.contains("backgroundTaskId")),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                collectLaunch(from: obj, into: &result)
            }

            // Completions are text, not necessarily their own JSONL line — the
            // `<task-notification>` block is embedded in a content string. Scan
            // the raw line text for every wrapper it contains.
            if line.contains("<task-notification>") {
                collectTerminations(from: line, into: &result)
            }
        }
        return result
    }

    // MARK: - Launches

    private static func collectLaunch(from obj: [String: Any], into result: inout Result) {
        guard let tur = obj["toolUseResult"] as? [String: Any] else { return }
        if let status = tur["status"] as? String, status == "async_launched",
           let id = (tur["agentId"] as? String)?.nilIfEmpty {
            result.launched.insert(id)
        }
        if let id = (tur["backgroundTaskId"] as? String)?.nilIfEmpty {
            result.launched.insert(id)
        }
    }

    // MARK: - Terminations

    /// Extract the task id from each `<task-notification>` wrapper that also
    /// carries a `<status>` (a notification is only emitted at a terminal state).
    /// The id comes from `<task-id>` when present, else the `<output-file>`
    /// basename (`…/tasks/<id>.output`) — real transcripts carry both, and the
    /// fallback keeps matching working if either tag drifts. The wrapper text is
    /// JSON-escaped inside a string, but the tag literals survive escaping
    /// verbatim, so plain substring extraction is robust.
    private static func collectTerminations(from line: String, into result: inout Result) {
        var searchRange = line.startIndex..<line.endIndex
        while let open = line.range(of: "<task-notification>", range: searchRange) {
            let close = line.range(of: "</task-notification>", range: open.upperBound..<line.endIndex)
            let blockEnd = close?.lowerBound ?? line.endIndex
            let block = line[open.upperBound..<blockEnd]
            if block.contains("<status>"),
               let id = taggedValue("task-id", in: block) ?? outputFileId(in: block) {
                result.terminated.insert(id)
            }
            searchRange = (close?.upperBound ?? line.endIndex)..<line.endIndex
        }
    }

    /// The task id encoded in a `<output-file>…/tasks/<id>.output</output-file>`
    /// path, if present.
    private static func outputFileId(in block: Substring) -> String? {
        guard let path = taggedValue("output-file", in: block) else { return nil }
        let base = (path as NSString).lastPathComponent
        let id = base.hasSuffix(".output") ? String(base.dropLast(".output".count)) : base
        return id.isEmpty ? nil : id
    }

    private static func taggedValue(_ tag: String, in block: Substring) -> String? {
        guard let open = block.range(of: "<\(tag)>"),
              let close = block.range(of: "</\(tag)>", range: open.upperBound..<block.endIndex)
        else { return nil }
        let value = block[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
