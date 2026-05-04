import Foundation

enum RepoInfo {
    /// Walk up from cwd looking for a `.git` directory; return its parent's
    /// last path component. Falls back to cwd's last path component.
    static func repoName(forCwd cwd: URL) -> String {
        let fm = FileManager.default
        var current = cwd.standardizedFileURL
        for _ in 0..<32 {
            let dotgit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotgit.path, isDirectory: &isDir), isDir.boolValue {
                return current.lastPathComponent
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return cwd.lastPathComponent
    }
}

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// First non-empty line, trimmed, truncated to N characters.
    func firstMeaningfulLine(maxLength: Int = 160) -> String? {
        for raw in split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                if line.count > maxLength {
                    return String(line.prefix(maxLength)) + "…"
                }
                return line
            }
        }
        return nil
    }
}
