# AGENTS.md

Context for AI agents working in this repo. See `README.md` first for the project overview, architecture diagram, hook list, make targets, and layout — this file only captures the non-obvious things you need to know that the README doesn't.

## Scope and portability

This menu bar app is currently built for **Factory's Droid CLI** running inside **iTerm2** on macOS. The vendor coupling lives in exactly two places:

- `hooks/factory-event-bridge.sh` + `Domain/HookEvent.swift` — the event source (Factory's hook payload shape).
- `Focus/ITermFocuser.swift` + `Focus/ITermInventory.swift` — terminal focus and live-tab inventory (iTerm's AppleScript dictionary + the `$ITERM_SESSION_ID` env var captured by the bridge).

Everything else (`Store/`, `UI/`, `IPC/`, the rest of `Domain/`) is vendor-neutral. Keep it that way; don't push vendor-specific branches inward.

### Using this on an unsupported stack today

You can't, beyond seeing an empty popover. Rows will be unclickable (no session id is captured to focus by) and no events will reach the app (the bridge is only registered with Factory's hook system).

### Extension sketch for future support (not implemented)

- **Other coding agents** (Cursor, Claude Code, …): add one shell bridge per agent that normalises that agent's hook payload into the existing `HookEvent` JSON on stdin → socket. Extend `SessionStore.apply` with adapters for any new event names. The state machine (`running` → `waitingForInput` → `finished`) maps cleanly onto any prompt-driven agent loop.
- **Other terminals** (Terminal.app, Warp, Ghostty, …): introduce `TerminalFocuser` and `TerminalInventory` protocols, pick the implementation at hook-receive time using the already-captured `$TERM_PROGRAM`, and rename the persisted field `itermSessionId` → `terminalSessionId` with a sibling `terminalKind`. Terminal.app is easiest (AppleScript-controllable); Warp and Ghostty have no stable public scripting interface today.

Keep the abstraction at the **adapter** level — one Swift type per concrete terminal/agent. Don't try to generalise `HookEvent` keys or invent a plugin runtime; the surface is small enough that thin protocols are enough.

## Dev loop

The right iteration command is `make install` (builds release, packages the `.app`, copies to `/Applications`, relaunches). `make run` runs the raw SwiftPM binary, which on macOS 26 has unreliable status-item visibility — only useful for the very first compile check.

After editing Swift code: `make install`. After editing the hook bridge or its registration: also `make install-hooks` (the user's `~/.factory/settings.json` is the source of truth; **droid CLI snapshots hooks at startup, so existing droid sessions won't see new hooks until they restart**).

## Where state and logs live

- `~/Library/Application Support/AgentMenuBar/sessions.json` — persisted session store (atomic rename)
- `~/Library/Application Support/AgentMenuBar/sock` — Unix domain socket the bridge writes to
- `~/Library/Logs/AgentMenuBar/events.log` — every augmented hook payload, appended even when the app is offline. First place to look when behaviour is wrong.
- `~/.factory/settings.json` — where `install-hooks` registers the bridge

## Status state machine (more nuanced than the README table)

Factory's `Stop` hook fires after **every** model turn, not at session end. From the user's POV, between turns the droid is idle ⇒ rendered as `DONE`. Concretely:

| Event | Status transition | Notes |
|---|---|---|
| `SessionStart` | → running | |
| `UserPromptSubmit` | → running | user typed a new prompt |
| `Notification` | → waitingForInput | permission prompt or 60s-idle alert |
| `PreToolUse` matcher `AskUser` | → waitingForInput | interactive choice picker; sound plays but no `Notification` fires for these |
| `PostToolUse` matcher `AskUser` | → running | user answered the picker |
| `Stop` | → finished | "current turn done, idle" — **not** session-end |
| `SessionEnd` | → finished | actually done |

The store keeps the literal `.finished` value across `Stop`s; the popover treats `.finished` as `DONE` and the next `UserPromptSubmit` flips it back to `.running`.

`visibleSessions` collapses many historical droid runs sharing the same iTerm tab into one row (most recent by `lastEventAt`) and drops sessions whose iTerm tab is no longer open. This is driven by `ITermInventory.fetchAliveUUIDs()` running on a 5-second timer. Don't filter sessions for display anywhere else — use `store.visibleSessions`.

## macOS / Tahoe gotchas (don't regress these)

- The app **must** ship as a proper `.app` with `LSUIElement=YES`. macOS 26 silently drops `NSStatusItem`s registered by un-bundled SwiftPM binaries (the bundle ID comes through as `NULL`). The `make install` path handles this; `make run` does not.
- Use plain emoji text (e.g. `🤖`, `❓`, `🟦`) for the status item label via `NSAttributedString`. SF Symbols render with insufficient prominence on Tahoe. See `AppDelegate.applyTitle(for:flashOn:)`.
- `NSPopover.behavior` is `.applicationDefined` (not `.transient`). In an `LSUIElement` app, transient popovers sometimes never become key, which causes SwiftUI `Button` taps to silently disappear. On show we also call `NSApp.activate(ignoringOtherApps: true)` and `view.window?.makeKey()`. Touching this is how you'll break clicks again.
- Rows use `.onTapGesture` not `Button` for the same key-window reason.
- iTerm focus across separate-Space displays uses `AXRaise` via `System Events` (`ITermFocuser.swift`). Plain `activate` only brings iTerm frontmost on the display where its window already lives. The `AXRaise` call requires **Accessibility** permission (separate from the Automation permission for talking to iTerm). The whole nudge is wrapped in `try` blocks so missing permission degrades gracefully.

## Hook registration

`make install-hooks` uses a jq merge that:
- Removes any prior entry whose `command` matches our bridge path before adding (idempotent)
- Backs up `~/.factory/settings.json` with a timestamped `.bak` first
- Registers two flavours: bare-event hooks (`SessionStart`, `SessionEnd`, `Notification`, `Stop`, `UserPromptSubmit`) and matcher hooks (`PreToolUse`/`PostToolUse` with `matcher: "AskUser"`)

If you add a new hook, mirror it in **both** the `install_hook` and `remove_hook` jq function call lists so uninstall stays clean. Use `install_matcher_hook` when the event requires a matcher.

## Things that are not bugs

- `Stop` events outnumber every other event by ~3:1 in `events.log`. Each model turn produces one; treat it as the chat heartbeat, not as "task complete".
- The sessions store can hold dozens of historical entries per tab. `visibleSessions` deals with that — don't try to prune the store automatically. `Clear finished` is the user-facing escape hatch.
- The first `make install` after a `cp -R` invalidates prior TCC grants because ad-hoc re-signing changes the code-signing identity. The user has to re-approve iTerm Automation and (if AXRaise is wanted) Accessibility.
- `osascript display notification` shows up under "Script Editor" in System Settings → Notifications. That's by design — avoids requiring a signed bundle for `UNUserNotificationCenter`.

## Diagnostics quick recipes

- "Did my click reach SwiftUI?" → Add a temporary `NSLog` / file write in `SessionRowView.onTapGesture` and watch `~/Library/Logs/AgentMenuBar/`. Don't trust `log show` for app-level `NSLog`s under newer macOS — they're often redacted as `<private>`.
- "Why doesn't the popover show this session?" → It's almost certainly the iTerm inventory filter. Run the script in `ITermInventory.fetchAliveUUIDs()`'s body manually via `osascript` and compare against `aliveItermUUIDs`.
- "Hook didn't fire" → Tail `events.log` while triggering. If nothing appears the bridge wasn't called → check `~/.factory/settings.json` for the registration. If it appears but the app didn't react, the socket forwarding failed → check the app is running and `sock` exists.

## Coding conventions

- Swift, no third-party dependencies. Don't add SwiftPM packages without a strong reason.
- All UI lives under `Sources/AgentMenuBar/UI`. Status decisions live in `Store/SessionStore.swift`. Don't move status logic into views.
- AppleScript is consolidated under `Sources/AgentMenuBar/Focus/`. Keep it there.
- Comments only when the why is non-obvious (constraints, macOS quirks, hook semantics). Don't narrate the code.
