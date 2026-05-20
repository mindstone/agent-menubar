# AgentMenuBar

A macOS menu-bar app that tracks running AI-agent sessions across your iTerm windows and tabs, surfaces the ones waiting for your input, and one-click-focuses the exact tab. The first supported agent is Factory Droid; the architecture is generic so other CLI agents can plug in via their own hook bridges.

## Why this exists

Factory's CLI plays a sound when it needs your attention but doesn't tell you *which* of your iTerm tabs to look at. This app fixes that by:

1. Listening to Factory's documented hook events (`Notification`, `Stop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`).
2. Capturing each session's `ITERM_SESSION_ID` at start.
3. Showing one row per active droid in a popover, with click-to-focus that selects the exact iTerm window + tab.

No accessibility automation, no terminal scraping. Hooks + iTerm's own session UUID + AppleScript only.

## Status

**v1.** End-to-end pipeline is implemented and smoke-tested (build → run → fake events → click-to-focus path). Build is clean.

## Architecture

```
 Factory hook  ──stdin JSON──▶  hooks/factory-event-bridge.sh
                                         │
                                         │ augments with $ITERM_SESSION_ID,
                                         │ $TERM_PROGRAM, $PPID
                                         ▼
            Unix domain socket: ~/Library/Application Support/AgentMenuBar/sock
                                         │
                                         ▼
                                 AgentMenuBar.app (Swift / SwiftUI)
                                         │
                                  AppleScript│
                                         ▼
                                       iTerm2
```

- **Canonical session id**: Factory `session_id` (UUID).
- **Focus key**: `ITERM_SESSION_ID` captured once at `SessionStart`.
- **Storage**: `~/Library/Application Support/AgentMenuBar/sessions.json` (atomic rename).
- **Debug log**: `~/Library/Logs/AgentMenuBar/events.log` (raw augmented payloads even when the app is offline).

## Quick start

```bash
make build           # swift build (debug)
make install-hooks   # additive merge into ~/.factory/settings.json (timestamped backup)
make run             # launches the menu bar app (no Dock icon)
```

Open a new iTerm tab and run `droid`. You should see a row appear in the menu bar popover. When droid asks you something it'll fire a desktop notification; clicking the row jumps your foreground iTerm tab to that exact session.

To remove the hooks: `make uninstall-hooks` (your other hooks are preserved).

## Manual test (no real droid required)

```bash
make run
# in another terminal, inside iTerm:
make test-event   # runs scripts/send-test-event.sh: SessionStart, UserPromptSubmit, Notification, Stop
```

You'll see four notifications and one row in the popover, ending in "Finished task".

## Status states

| State | Colour | When |
|---|---|---|
| running | blue | After `SessionStart` or `UserPromptSubmit` |
| waitingForInput | orange | On `Notification` (the urgent one) |
| finished | green | After `Stop` or `SessionEnd` |
| stale | grey | A previously-running session whose process disappeared |

The menu bar icon is grey when nothing's tracked, shows a count when sessions are active, and turns orange with an alert glyph when at least one session is `waitingForInput`.

## Known limits (by design in v1)

- macOS only (built for macOS 13+; tested on 26).
- iTerm only — sessions started outside iTerm appear in the list but can't be focused.
- Factory Droid only.
- No accessibility / screen-scraping.
- Notifications are emitted via `osascript display notification` (so they appear under "Script Editor" in the system notification source). This is deliberate — it avoids needing a signed bundle for `UNUserNotificationCenter`.

## Requirements

- macOS 13+ (Ventura) — tested on 26 (Tahoe)
- Xcode CLT / Swift 5.9+
- iTerm2
- `jq`, `nc`, `osascript` (all preinstalled on macOS)

## Layout

```
hooks/
  factory-event-bridge.sh             shell that Factory invokes
  settings-hooks-block.json           reference snippet of what install-hooks adds
scripts/
  send-test-event.sh                  fake-event harness for development
Sources/AgentMenuBar/
  App/AgentMenuBarApp.swift           @main, MenuBarExtra, accessory policy, server boot
  Domain/                             DroidSession, HookEvent, SessionStatus,
                                      RepoInfo, TranscriptReader
  Store/                              SessionStore (state machine) + JSON persistence
  IPC/                                BSD UDS server + JSON decoder
  Focus/ITermFocuser.swift            AppleScript focus by iTerm session UUID
  UI/                                 MenuBarLabel, popover list, row
  Notifications/                      osascript-based notifier
```

## Make targets

| Target | What it does |
|---|---|
| `make build` | swift build (debug) |
| `make release` | swift build -c release |
| `make run` | build + launch (debug) |
| `make run-release` | build + launch (release) |
| `make stop` | kill any running AgentMenuBar |
| `make install-hooks` | additive jq merge into `~/.factory/settings.json`, backup first |
| `make uninstall-hooks` | inverse, prunes empty groups, backup first |
| `make test-event` | send the demo event sequence to the running app |
| `make tail-events` | tail `~/Library/Logs/AgentMenuBar/events.log` |
| `make clean` | swift package clean |

## Roadmap (post-v1)

- Proper `.app` bundle for Login Items and signed `UNUserNotificationCenter` notifications.
- "Snooze attention" / per-session mute.
- Other terminals: Terminal.app, Warp, Ghostty (via per-terminal focuser adapters).
- Generic agent providers (Claude Code, Cursor CLI) once their hook surfaces stabilise.

## License

TBD.
