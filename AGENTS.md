# AGENTS.md

Context for AI agents working in this repo. See `README.md` first for the project overview, architecture diagram, hook list, make targets, and layout — this file only captures the non-obvious things you need to know that the README doesn't.

## Scope and portability

This menu bar app currently supports **Factory's Droid CLI**, **OpenAI Codex CLI**, **Cursor's `cursor-agent` CLI**, and **Anthropic's Claude Code** running inside supported macOS terminals. The vendor coupling lives in adapter-level files:

- `hooks/{factory,codex,cursor,claude-code}-event-bridge.sh` + `hooks/agent-event-bridge.sh` — hook source wrappers and shared socket forwarding. The Cursor wrapper also normalises Cursor-specific field names (`conversation_id`→`session_id`, `workspace_roots[0]`→`cwd`, `prompt`/`text`→`prompt`) before the shared bridge runs; the Factory, Codex, and Claude Code wrappers are thin because those CLIs already emit the field names `HookEvent` decodes.
- `Domain/HookEvent.swift` + `Domain/AgentEventAdapter.swift` — the decoded hook payload and per-agent state transitions.
- `Focus/*Focuser.swift` + `Focus/*Inventory.swift` — terminal focus and live-tab inventory.

Everything else (`Store/`, `UI/`, `IPC/`, the rest of `Domain/`) is vendor-neutral. Keep it that way; don't push vendor-specific branches inward.

### Using this on an unsupported stack today

You can't, beyond seeing an empty popover. Rows will be unclickable if no supported terminal id can be captured, and no events will reach the app unless that CLI has a hook wrapper registered.

### Extension sketch for future support (not implemented)

- **Other coding agents** (Cursor, Claude Code, …): add one shell wrapper per agent that invokes `agent-event-bridge.sh <agent-kind>`, add an `AgentKind`, and add one `AgentEventAdapter` implementation for that CLI's event semantics. The state machine (`running` → `waitingForInput` → `finished`) maps cleanly onto any prompt-driven agent loop.
- **Other terminals** (Terminal.app, Warp, …): add terminal-specific inventory/focus adapters under `Sources/AgentMenuBar/Focus/`, then route from `DroidSession.hostApp`. Terminal.app is easiest (AppleScript-controllable); Warp has no stable public scripting interface today.

Keep the abstraction at the **adapter** level — one Swift type per concrete terminal/agent. Don't try to generalise `HookEvent` keys or invent a plugin runtime; the surface is small enough that thin protocols are enough.

## Dev loop

The right iteration command is `make install` (builds release, packages the `.app`, copies to `/Applications`, relaunches). `make run` runs the raw SwiftPM binary, which on macOS 26 has unreliable status-item visibility — only useful for the very first compile check.

After editing Swift code: `make install`. After editing the hook bridge or its registration: also `make install-hooks` (Factory + Codex + Claude Code) and/or `make install-cursor-hooks` (Cursor is a separate target, see below). Factory's `~/.factory/settings.json`, Codex's `~/.codex/hooks.json`, Claude Code's `~/.claude/settings.json`, and Cursor's `~/.cursor/hooks.json` are the hook sources of truth. Existing Droid sessions need restart because Droid snapshots hooks at startup; Codex and Claude Code sessions may also need `/hooks` review after the hook definition changes; Cursor reloads `hooks.json` automatically but in-flight `cursor-agent` sessions should be restarted to pick up new hooks.

## Where state and logs live

- `~/Library/Application Support/AgentMenuBar/sessions.json` — persisted session store (atomic rename)
- `~/Library/Application Support/AgentMenuBar/sock` — Unix domain socket the bridge writes to
- `~/Library/Logs/AgentMenuBar/events.log` — every augmented hook payload, appended even when the app is offline. First place to look when behaviour is wrong.
- `~/.factory/settings.json` — where `install-factory-hooks` registers the Droid bridge
- `~/.codex/hooks.json` — where `install-codex-hooks` registers the Codex bridge

## Status state machine (more nuanced than the README table)

Factory and Codex `Stop` hooks are turn-scoped, not necessarily process/session end. From the user's POV, between turns the agent is idle ⇒ rendered as `DONE`. Concretely:

| Event | Status transition | Notes |
|---|---|---|
| `SessionStart` | → running | |
| `UserPromptSubmit` | → running | user typed a new prompt |
| `Notification` | → waitingForInput | permission prompt or 60s-idle alert |
| `PermissionRequest` | → waitingForInput | Codex approval prompt |
| `PreToolUse` matcher `AskUser` | → waitingForInput | Factory interactive choice picker; sound plays but no `Notification` fires for these |
| `PreToolUse` matcher `request_user_input` | → waitingForInput | Codex Plan-mode/user-input picker; this is not a `PermissionRequest` |
| `PostToolUse` | → running | Factory `AskUser` answered, Codex user-input picker answered, or Codex completed a tool after approval |
| `Stop` | → finished | "current turn done, idle" — **not** session-end |
| `SessionEnd` | → finished | actually done |
| Cursor `sessionStart` / `beforeSubmitPrompt` | → running | camelCase; prompt captured from `prompt` (or `text`) |
| Cursor `beforeShellExecution` / `beforeMCPExecution` | → waitingForInput | approval gate — the only hook-observable "needs you" moment in `cursor-agent` |
| Cursor `afterShellExecution` / `afterMCPExecution` / `afterFileEdit` / `postToolUse` | → running | command/tool ran, agent working again |
| Cursor `stop` | → finished | turn-scoped; `status` ∈ completed/aborted/error drives the row text |
| Cursor `sessionEnd` | → finished | actually done |
| Claude `SessionStart` / `UserPromptSubmit` | → running | PascalCase; payload already matches `HookEvent` fields |
| Claude `Notification(permission_prompt\|elicitation_dialog)` / `PermissionRequest` | → waitingForInput | Notification is scoped to the genuine needs-you types so `auth_success` etc. don't flip the row |
| Claude `Notification(idle_prompt)` | → *(ignored)* | Fires ~60s after `Stop` when the user hasn't replied; the turn is already DONE. Treating it as waiting repaints every finished turn as a "question" — so it's dropped from the matcher **and** no-op'd in the adapter (`notification_type` guard) for safety against stale settings. |
| Claude `PostToolUse` | → running | tool ran after approval — flips waiting back to running |
| Claude `Stop` | → finished | turn-scoped, like Codex |
| Claude `SessionEnd` | → finished | actually done |

The store keeps the literal `.finished` value across `Stop`s; the popover treats `.finished` as `DONE` and the next `UserPromptSubmit` flips it back to `.running`.

`visibleSessions` collapses many historical agent runs sharing the same terminal tab into one row (most recent by `lastEventAt`) and drops sessions whose terminal tab is no longer open. This is driven by terminal inventory polling on a 5-second timer. Don't filter sessions for display anywhere else — use `store.visibleSessions`.

## macOS / Tahoe gotchas (don't regress these)

- The app **must** ship as a proper `.app` with `LSUIElement=YES`. macOS 26 silently drops `NSStatusItem`s registered by un-bundled SwiftPM binaries (the bundle ID comes through as `NULL`). The `make install` path handles this; `make run` does not.
- Use plain emoji text (e.g. `🤖`, `❓`, `🟦`) for the status item label via `NSAttributedString`. SF Symbols render with insufficient prominence on Tahoe. See `AppDelegate.applyTitle(for:flashOn:)`.
- `NSPopover.behavior` is `.applicationDefined` (not `.transient`). In an `LSUIElement` app, transient popovers sometimes never become key, which causes SwiftUI `Button` taps to silently disappear. On show we also call `NSApp.activate(ignoringOtherApps: true)` and `view.window?.makeKey()`. Touching this is how you'll break clicks again.
- Rows use `.onTapGesture` not `Button` for the same key-window reason.
- iTerm focus across separate-Space displays uses `AXRaise` via `System Events` (`ITermFocuser.swift`). Plain `activate` only brings iTerm frontmost on the display where its window already lives. The `AXRaise` call requires **Accessibility** permission (separate from the Automation permission for talking to iTerm). The whole nudge is wrapped in `try` blocks so missing permission degrades gracefully.

## Hook registration

`make install-hooks` uses a jq merge that:
- Removes any prior entry whose `command` matches our bridge path before adding (idempotent)
- Backs up `~/.factory/settings.json`, `~/.codex/hooks.json`, and `~/.claude/settings.json` with timestamped `.bak` files first
- Factory: registers bare-event hooks (`SessionStart`, `SessionEnd`, `Notification`, `Stop`, `UserPromptSubmit`) and matcher hooks (`PreToolUse`/`PostToolUse` with `matcher: "AskUser"`)
- Codex: registers `SessionStart`, `UserPromptSubmit`, `Notification`, `PermissionRequest`, `PreToolUse` with `matcher: "request_user_input"`, `PostToolUse`, and `Stop`
- Claude Code: registers `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop`, `SessionEnd`, and `Notification` with `matcher: "permission_prompt|elicitation_dialog"` (intentionally **not** `idle_prompt` — see the status table). Uses the same nested `{matcher, hooks:[{type,command}]}` shape as Factory/Codex, and only touches the top-level `hooks` key so unrelated settings (model, permissions, …) survive.

`make install-cursor-hooks` is **separate** and intentionally not part of `install-hooks`. `~/.cursor/hooks.json` is shared with the Cursor IDE, so bundling it into the default target would make every IDE agent session spawn an (unfocusable, terminal-less) row. The Cursor merge uses a **different shape** from Factory/Codex: Cursor hook definitions are flat (`{command, timeout}`, no nested `hooks` array), event names are camelCase, and the file carries a top-level `version: 1`. It registers `sessionStart`, `beforeSubmitPrompt`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `afterFileEdit`, `postToolUse`, `stop`, and `sessionEnd`. Note that `cursor-agent` only fires a subset in interactive mode (and `beforeSubmitPrompt`/`stop` don't fire in headless `-p`), but registering the full set is harmless.

If you add a new hook, mirror it in **both** the `install_hook` and `remove_hook` jq call lists for that CLI so uninstall stays clean. Use `install_matcher_hook` (Factory) when the event requires a matcher; Cursor matchers, when needed, are plain strings on the flat definition.

## Things that are not bugs

- `Stop` events outnumber every other event by ~3:1 in `events.log`. Each model turn produces one; treat it as the chat heartbeat, not as "task complete".
- The sessions store can hold dozens of historical entries per tab. `visibleSessions` deals with that — don't try to prune the store automatically. `Clear finished` is the user-facing escape hatch.
- The first `make install` after a `cp -R` invalidates prior TCC grants because ad-hoc re-signing changes the code-signing identity. The user has to re-approve iTerm Automation and (if AXRaise is wanted) Accessibility.
- `osascript display notification` shows up under "Script Editor" in System Settings → Notifications. That's by design — avoids requiring a signed bundle for `UNUserNotificationCenter`.

## Diagnostics quick recipes

- "Did my click reach SwiftUI?" → Add a temporary `NSLog` / file write in `SessionRowView.onTapGesture` and watch `~/Library/Logs/AgentMenuBar/`. Don't trust `log show` for app-level `NSLog`s under newer macOS — they're often redacted as `<private>`.
- "Why doesn't the popover show this session?" → It's almost certainly the iTerm inventory filter. Run the script in `ITermInventory.fetchAliveUUIDs()`'s body manually via `osascript` and compare against `aliveItermUUIDs`.
- "Hook didn't fire" → Tail `events.log` while triggering. If nothing appears the bridge wasn't called → check `~/.factory/settings.json` or `~/.codex/hooks.json` for the registration. For Codex, also open `/hooks` and confirm the hook was trusted. If an event appears but the app didn't react, the socket forwarding failed → check the app is running and `sock` exists.

## Coding conventions

- Swift, no third-party dependencies. Don't add SwiftPM packages without a strong reason.
- All UI lives under `Sources/AgentMenuBar/UI`. Status decisions live in `Store/SessionStore.swift`. Don't move status logic into views.
- AppleScript is consolidated under `Sources/AgentMenuBar/Focus/`. Keep it there.
- Comments only when the why is non-obvious (constraints, macOS quirks, hook semantics). Don't narrate the code.
