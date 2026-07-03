import Foundation

/// Builds the headless CLI invocation used to turn a session's raw status
/// into a one-line "what is this agent's job right now" summary — one call
/// per supported `AgentKind`, mirroring `ResumeCommand`'s per-agent argv table.
///
/// Each invocation is deliberately read-only/tool-free: the summarizer only
/// ever needs to paraphrase text we already give it, so every kind is pinned
/// to a mode that can't edit files, run shell commands, or spend meaningfully
/// more than a small-model call's worth of tokens.
enum JobSummaryCommand {
    /// Whether `kind` has a known headless "print and exit" mode we can drive.
    static func supportsSummary(_ kind: AgentKind) -> Bool {
        switch kind {
        case .factoryDroid, .codex, .cursor, .claudeCode:
            return true
        case .unknown:
            return false
        }
    }

    /// The argv to run for `kind`, asking it to answer `prompt` in one line.
    /// `nil` when the agent has no headless mode we drive.
    static func argv(for kind: AgentKind, prompt: String) -> [String]? {
        switch kind {
        case .claudeCode:
            // --allowedTools "" denies every tool outright (belt-and-braces —
            // the prompt itself never asks for tool use either).
            return ["claude", "-p", prompt, "--model", "haiku", "--allowedTools", "", "--output-format", "text"]
        case .codex:
            // read-only sandbox + low reasoning effort: the default (xhigh)
            // measured ~20s and 30k+ tokens for a one-line answer in testing.
            return ["codex", "exec", "--sandbox", "read-only", "-c", "model_reasoning_effort=\"low\"", prompt]
        case .cursor:
            // --mode ask is cursor-agent's read-only Q&A mode; plain -p alone
            // has full write/shell tool access. --trust skips the interactive
            // workspace-trust prompt that would otherwise hang a headless call.
            return ["cursor-agent", "-p", prompt, "--mode", "ask", "--model", "gpt-5-mini", "--output-format", "text", "--trust"]
        case .factoryDroid:
            // `droid exec` defaults to read-only autonomy with no flag needed.
            return ["droid", "exec", prompt]
        case .unknown:
            return nil
        }
    }

    /// The instruction sent to the model, given what we already know about
    /// the session. Kept short — this is a paraphrase task, not a chat.
    static func prompt(firstPrompt: String?, lastEvent: String) -> String {
        var context = "Its most recent status update is: \"\(clip(lastEvent))\"."
        if let firstPrompt = firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !firstPrompt.isEmpty {
            context = "It was originally asked to: \"\(clip(firstPrompt))\". " + context
        }
        return """
        A background coding assistant is running unattended. \(context)

        In under 12 words, describe what its job is right now, for a menu bar status list. Plain language, no quotes, no trailing punctuation, no preamble — reply with only that one line.
        """
    }

    /// Defensive length cap before text goes into a prompt/argv — `lastEvent`
    /// and `firstPrompt` are already clipped upstream, this just guards
    /// against that changing out from under us.
    private static func clip(_ s: String, max: Int = 300) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}
