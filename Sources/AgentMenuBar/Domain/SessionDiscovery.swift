import Foundation

/// A session found in an agent's native on-disk history.
struct DiscoveredSession: Equatable {
    /// Canonical session id used by the resume CLI.
    let id: String
    /// Agent that owns the session.
    let agentKind: AgentKind
    /// Original working directory. Resume commands must run here.
    let cwd: URL
    /// Newest on-disk activity for the session.
    let lastActivity: Date
    /// Best-effort first user prompt for display.
    let firstPrompt: String?
    /// Native transcript or session file backing the discovery result.
    let transcriptPath: URL?
}

enum SessionDiscovery {
    private struct FileCandidate {
        let url: URL
        let modifiedAt: Date
        let parentName: String?
    }

    private struct FactorySelection {
        let id: String
        let files: [FileCandidate]
        let latest: Date
    }

    /// Scan all supported agents under `home` and return discovered sessions,
    /// newest first. `now`/`maxAge`/`maxPerAgent` bound the work.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     now: Date = Date(),
                     maxAge: TimeInterval = 21 * 24 * 60 * 60,
                     maxPerAgent: Int = 40) -> [DiscoveredSession] {
        guard maxPerAgent > 0 else { return [] }

        let cutoff = now.addingTimeInterval(-maxAge)
        var sessions: [DiscoveredSession] = []
        sessions.append(contentsOf: scanClaude(home: home, cutoff: cutoff, maxPerAgent: maxPerAgent))
        sessions.append(contentsOf: scanCodex(home: home, cutoff: cutoff, maxPerAgent: maxPerAgent))
        sessions.append(contentsOf: scanFactory(home: home, cutoff: cutoff, maxPerAgent: maxPerAgent))
        sessions.append(contentsOf: scanCursor(home: home, cutoff: cutoff, maxPerAgent: maxPerAgent))

        return sessions.sorted {
            if $0.lastActivity != $1.lastActivity {
                return $0.lastActivity > $1.lastActivity
            }
            return $0.id < $1.id
        }
    }

    /// Parse the first Claude JSONL header lines for cwd and first user prompt.
    static func parseClaudeHeader(_ contents: String) -> (cwd: String?, firstPrompt: String?) {
        var cwd: String?
        var firstPrompt: String?

        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) {
            guard let obj = parseJSONObject(String(line)) else { continue }
            if cwd == nil {
                cwd = nonEmpty(obj["cwd"] as? String)
            }
            if firstPrompt == nil {
                firstPrompt = userPrompt(from: obj)
            }
            if cwd != nil && firstPrompt != nil {
                break
            }
        }

        return (cwd, firstPrompt)
    }

    /// Parse Codex's first `session_meta` JSONL line.
    static func parseCodexMeta(firstLine: String) -> (id: String?, cwd: String?) {
        guard let obj = parseJSONObject(firstLine),
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else {
            return (nil, nil)
        }

        return (
            nonEmpty(payload["id"] as? String),
            nonEmpty(payload["cwd"] as? String)
        )
    }

    /// Naive decode of Factory's encoded session-dir name. Lossy: Factory
    /// replaces every non-alphanumeric character with `-`, so a repo such as
    /// `droid-menubar` is indistinguishable from a `droid/menubar` path. Used
    /// only as a last resort; prefer `reconstructFactoryPath` (filesystem
    /// validated) or, better, an explicit `cwd` read from the session file.
    static func decodeFactoryDirName(_ name: String) -> String {
        let trimmed = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }

    /// Reconstruct a real directory path from Factory's lossy encoded dir name
    /// by greedily preferring, at each step, the longest path segment that
    /// actually exists. This recovers hyphenated repo names (e.g.
    /// `-Users-harry-development-droid-menubar` -> `/Users/harry/development/droid-menubar`)
    /// whenever the directory is still present. `directoryExists` is injected so
    /// the logic is testable without touching the filesystem. Once a segment
    /// can't be matched, the remaining tokens are appended with the naive `/`
    /// join.
    static func reconstructFactoryPath(_ encoded: String, directoryExists: (String) -> Bool) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let tokens = trimmed.split(separator: "-").map(String.init)
        guard !tokens.isEmpty else { return "/" }

        var path = ""
        var i = 0
        while i < tokens.count {
            var chosenSeg: String?
            var chosenEnd = i
            var seg = tokens[i]
            var j = i
            while true {
                if directoryExists(path + "/" + seg) {
                    chosenSeg = seg       // keep extending; longest match wins
                    chosenEnd = j
                }
                j += 1
                if j >= tokens.count { break }
                seg += "-" + tokens[j]
            }
            guard let chosen = chosenSeg else {
                path += "/" + tokens[i...].joined(separator: "/")
                return path
            }
            path += "/" + chosen
            i = chosenEnd + 1
        }
        return path
    }

    // MARK: - Agent scans

    private static func scanClaude(home: URL, cutoff: Date, maxPerAgent: Int) -> [DiscoveredSession] {
        let root = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let candidates = twoLevelFiles(root: root) { $0.pathExtension == "jsonl" }
            .filter { $0.modifiedAt >= cutoff }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxPerAgent)

        return candidates.compactMap { candidate in
            let header = readFirstLines(candidate.url, maxLines: 30, maxBytes: 512 * 1024).joined(separator: "\n")
            let parsed = parseClaudeHeader(header)
            guard let cwd = parsed.cwd else { return nil }

            return DiscoveredSession(
                id: candidate.url.deletingPathExtension().lastPathComponent,
                agentKind: .claudeCode,
                cwd: URL(fileURLWithPath: cwd),
                lastActivity: candidate.modifiedAt,
                firstPrompt: parsed.firstPrompt,
                transcriptPath: candidate.url
            )
        }
    }

    private static func scanCodex(home: URL, cutoff: Date, maxPerAgent: Int) -> [DiscoveredSession] {
        let root = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let candidates = recursiveFiles(root: root) { $0.pathExtension == "jsonl" }
            .filter { $0.modifiedAt >= cutoff }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxPerAgent)

        return candidates.compactMap { candidate in
            guard let firstLine = readFirstLines(candidate.url, maxLines: 1, maxBytes: 1024 * 1024).first else {
                return nil
            }
            let parsed = parseCodexMeta(firstLine: firstLine)
            guard let id = parsed.id, let cwd = parsed.cwd else { return nil }

            return DiscoveredSession(
                id: id,
                agentKind: .codex,
                cwd: URL(fileURLWithPath: cwd),
                lastActivity: candidate.modifiedAt,
                firstPrompt: nil,
                transcriptPath: candidate.url
            )
        }
    }

    private static func scanFactory(home: URL, cutoff: Date, maxPerAgent: Int) -> [DiscoveredSession] {
        let root = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let candidates = twoLevelFiles(root: root) { url in
            url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".json")
        }

        var grouped: [String: [FileCandidate]] = [:]
        for candidate in candidates {
            guard let id = factorySessionID(from: candidate.url.lastPathComponent) else { continue }
            grouped[id, default: []].append(candidate)
        }

        let selected = grouped.compactMap { id, files -> FactorySelection? in
            guard let latest = files.map({ $0.modifiedAt }).max(), latest >= cutoff else { return nil }
            return FactorySelection(id: id, files: files, latest: latest)
        }
        .sorted { $0.latest > $1.latest }
        .prefix(maxPerAgent)

        return selected.compactMap { selection in
            let files = selection.files.sorted { $0.modifiedAt > $1.modifiedAt }
            let explicitCWD = factoryCWD(in: files)
            // Factory JSONL usually carries an explicit `cwd`; when it doesn't,
            // recover the path from the lossy encoded parent directory name,
            // validated against the real filesystem so hyphenated repo names
            // resolve correctly.
            let cwdString = explicitCWD ?? reconstructFactoryPath(
                files.first?.parentName ?? "",
                directoryExists: Self.directoryExistsOnDisk
            )
            guard !cwdString.isEmpty, cwdString != "/" else { return nil }

            return DiscoveredSession(
                id: selection.id,
                agentKind: .factoryDroid,
                cwd: URL(fileURLWithPath: cwdString),
                lastActivity: selection.latest,
                firstPrompt: factoryFirstPrompt(in: files),
                transcriptPath: primaryFactoryFile(in: files)
            )
        }
    }

    /// Cursor stores chats in SQLite under `~/.cursor/chats/<chatId>/*/store.db`.
    /// Disk discovery is deferred until there is a SQLite reader here; sessions
    /// observed through hooks are still resumable through the normal store.
    private static func scanCursor(home: URL, cutoff: Date, maxPerAgent: Int) -> [DiscoveredSession] {
        []
    }

    // MARK: - File listing

    private static func twoLevelFiles(root: URL, matching include: (URL) -> Bool) -> [FileCandidate] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [FileCandidate] = []
        for dir in dirs where isDirectory(dir) {
            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where include(child) {
                guard isRegularFile(child), let modifiedAt = modificationDate(child) else { continue }
                files.append(FileCandidate(url: child, modifiedAt: modifiedAt, parentName: dir.lastPathComponent))
            }
        }
        return files
    }

    private static func recursiveFiles(root: URL, matching include: (URL) -> Bool) -> [FileCandidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [FileCandidate] = []
        for case let url as URL in enumerator where include(url) {
            guard isRegularFile(url), let modifiedAt = modificationDate(url) else { continue }
            files.append(FileCandidate(url: url, modifiedAt: modifiedAt, parentName: url.deletingLastPathComponent().lastPathComponent))
        }
        return files
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func directoryExistsOnDisk(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Bounded reads

    private static func readFirstLines(_ url: URL, maxLines: Int, maxBytes: Int) -> [String] {
        guard maxLines > 0, maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        var data = Data()
        let chunkSize = 8 * 1024
        while data.count < maxBytes {
            let remaining = maxBytes - data.count
            guard let chunk = try? handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            if data.filter({ $0 == 10 }).count >= maxLines {
                break
            }
        }

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).map(String.init))
    }

    // MARK: - Factory helpers

    private static func factorySessionID(from fileName: String) -> String? {
        let withoutExtension: String
        if fileName.hasSuffix(".jsonl") {
            withoutExtension = String(fileName.dropLast(".jsonl".count))
        } else if fileName.hasSuffix(".json") {
            withoutExtension = String(fileName.dropLast(".json".count))
        } else {
            return nil
        }

        let id = withoutExtension.split(separator: ".", maxSplits: 1).first.map(String.init) ?? withoutExtension
        return nonEmpty(id)
    }

    private static func factoryCWD(in files: [FileCandidate]) -> String? {
        for file in factoryReadOrder(files) {
            let lines = readFirstLines(file.url, maxLines: 30, maxBytes: 512 * 1024)
            if file.url.pathExtension == "jsonl" {
                for line in lines {
                    guard let obj = parseJSONObject(line), let cwd = explicitCWD(in: obj) else { continue }
                    return cwd
                }
            } else {
                let contents = lines.joined(separator: "\n")
                if let obj = parseJSONObject(contents), let cwd = explicitCWD(in: obj) {
                    return cwd
                }
            }
        }
        return nil
    }

    private static func factoryFirstPrompt(in files: [FileCandidate]) -> String? {
        for file in factoryReadOrder(files) where file.url.pathExtension == "jsonl" {
            let lines = readFirstLines(file.url, maxLines: 60, maxBytes: 512 * 1024)
            for line in lines {
                guard let obj = parseJSONObject(line), let prompt = userPrompt(from: obj) else { continue }
                return prompt
            }
        }
        return nil
    }

    private static func primaryFactoryFile(in files: [FileCandidate]) -> URL? {
        let ordered = factoryReadOrder(files)
        if let jsonl = ordered.first(where: { $0.url.pathExtension == "jsonl" }) {
            return jsonl.url
        }
        if let settings = ordered.first(where: { $0.url.lastPathComponent.hasSuffix(".settings.json") }) {
            return settings.url
        }
        return ordered.first?.url
    }

    private static func factoryReadOrder(_ files: [FileCandidate]) -> [FileCandidate] {
        files.sorted {
            if $0.url.pathExtension == "jsonl" && $1.url.pathExtension != "jsonl" {
                return true
            }
            if $0.url.pathExtension != "jsonl" && $1.url.pathExtension == "jsonl" {
                return false
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private static func explicitCWD(in obj: [String: Any]) -> String? {
        for key in ["cwd", "workspacePath", "directory", "path"] {
            guard let value = nonEmpty(obj[key] as? String), value.hasPrefix("/") else { continue }
            return value
        }
        return nil
    }

    // MARK: - JSON helpers

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
    }

    private static func userPrompt(from obj: [String: Any]) -> String? {
        if obj["type"] as? String != "user",
           !((obj["message"] as? [String: Any])?["role"] as? String == "user") {
            return nil
        }

        guard let message = obj["message"] as? [String: Any] else { return nil }
        return textContent(message["content"])
    }

    private static func textContent(_ content: Any?) -> String? {
        if let text = nonEmpty(content as? String) {
            return text
        }

        guard let blocks = content as? [Any] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let obj = block as? [String: Any] else { return nil }
            if let type = obj["type"] as? String, type != "text" {
                return nil
            }
            return nonEmpty(obj["text"] as? String)
        }
        return nonEmpty(texts.joined(separator: "\n"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
