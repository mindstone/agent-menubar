# DroidMenuBar

A macOS menu-bar app that tracks running Factory Droid sessions across your iTerm windows and tabs, surfaces the ones waiting for your input, and one-click-focuses the exact tab.

## Why this exists

Factory's CLI plays a sound when it needs your attention but doesn't tell you *which* of your iTerm tabs to look at. This app fixes that by:

1. Listening to Factory's documented hook events (`Notification`, `Stop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`).
2. Capturing each session's `ITERM_SESSION_ID` at start.
3. Showing one row per active droid in a popover, with click-to-focus that selects the exact iTerm window + tab.

No accessibility automation, no terminal scraping. Hooks + iTerm's own session UUID + AppleScript only.

## Status

**v1 scaffold.** The app builds, the menu bar icon appears, the hook bridge accumulates events to a log file. The state-machine that turns events into rows, the IPC socket, and the iTerm focuser are stubbed and being filled in next.

## Architecture

```
 Factory hook  ──stdin JSON──▶  hooks/factory-event-bridge.sh
                                         │
                                         │  augments with $ITERM_SESSION_ID
                                         ▼
                          Unix socket ($XDG-equivalent application support)
                                         │
                                         ▼
                                DroidMenuBar.app (Swift / SwiftUI)
                                         │
                                  AppleScript │
                                         ▼
                                       iTerm2
```

- **Canonical session id**: Factory `session_id` (UUID).
- **Focus key**: `ITERM_SESSION_ID` captured once at `SessionStart`.
- **Storage**: `~/Library/Application Support/DroidMenuBar/sessions.json` (atomic rename).
- **Debug log**: `~/Library/Logs/DroidMenuBar/events.log`.

## Setup

```bash
make build           # swift build
make install-hooks   # registers the bridge in ~/.factory/settings.json (with backup)
make run             # launches the app
```

Open a new iTerm tab and run `droid`. Trigger a `Notification` event (e.g. ask droid something) and you should see the row appear in the menu bar popover.

To remove the hooks: `make uninstall-hooks`.

## Requirements

- macOS 13+ (Ventura)
- Xcode CLT / Swift 5.9+
- iTerm2 (other terminals not yet supported)
- `jq` and `nc` (preinstalled on macOS)

## Constraints by design (v1)

- macOS only.
- iTerm only.
- Factory Droid only.
- No accessibility / screen scraping.
- No process tree walking.
- Sessions outside iTerm are tracked but not focusable.

## Layout

```
hooks/                                  shell that Factory invokes
Sources/DroidMenuBar/
  App/                                  SwiftUI @main + scenes
  Domain/                               DroidSession, HookEvent, SessionStatus
  Store/                                SessionStore + JSON persistence
  IPC/                                  HookSocketServer + decoder
  Focus/                                iTerm AppleScript focuser
  UI/                                   MenuBarLabel, list and rows
  Notifications/                        UNUserNotificationCenter helpers
```

## License

TBD.
