import Foundation

/// Best-effort reader for the tail of an agent transcript file.
/// We do not assume a strict schema. We try a few common shapes, and
/// fall back to "last non-empty text-ish line" if nothing structured matches.
enum TranscriptReader {
    /// Returns a short text preview of the most recent meaningful entry, if any.
    static func tailPreview(_ url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let endOffset: UInt64
        do { endOffset = try handle.seekToEnd() } catch { return nil }
        let startOffset = endOffset > UInt64(maxBytes) ? endOffset - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: startOffset) } catch { return nil }

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        let lines = str.split(whereSeparator: { $0 == "\n" }).suffix(40)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let lineData = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let text = extractText(obj)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return clip(text)
            }
        }
        // Plain-text fallback: last non-empty line, clipped.
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return clip(String(trimmed)) }
        }
        return nil
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        // Direct fields commonly seen in transcript-like JSONL.
        if let s = obj["text"] as? String, !s.isEmpty { return s }
        if let s = obj["content"] as? String, !s.isEmpty { return s }
        if let s = obj["message"] as? String, !s.isEmpty { return s }

        // Anthropic-style content blocks: [{type:"text", text:"..."}]
        if let arr = obj["content"] as? [[String: Any]] {
            let texts = arr.compactMap { $0["text"] as? String }
            if let joined = texts.first(where: { !$0.isEmpty }) { return joined }
        }
        // Nested message wrapper: { message: { content: [...] } }
        if let inner = obj["message"] as? [String: Any] {
            return extractText(inner)
        }
        return nil
    }

    private static func clip(_ s: String, max: Int = 200) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }
}
